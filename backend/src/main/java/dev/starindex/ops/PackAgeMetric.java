package dev.starindex.ops;

import dev.starindex.pack.PackPublisher;
import dev.starindex.pack.PackStore;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;

import java.time.Duration;
import java.time.Instant;
import java.time.OffsetDateTime;
import java.util.OptionalDouble;

/**
 * Data freshness for the CloudWatch alarm {@code StarIndex/PackAgeMinutes > 360} (PLAN 3.5 alarm 2): minutes since the
 * forecast issue the live index pack was built from ({@code packs.index.issuedAt}; generatedAt when absent). The
 * 단기예보 is issued every 3 hours and published 15 minutes later, so the healthy value stays under ~200; 360 means two
 * issues in a row did not make it. The alarm treats missing data as breaching: no value also means the server is down.
 */
public final class PackAgeMetric {
    private static final Logger log = LoggerFactory.getLogger(PackAgeMetric.class);
    public static final String NAMESPACE = "StarIndex", NAME = "PackAgeMinutes";

    /** Where values go: CloudWatch on EC2, a list in tests. */
    @FunctionalInterface
    public interface Sink {
        void put(String namespace, String name, double value);
    }

    private final PackStore store;
    private final Sink sink;
    private final JsonMapper json = JsonMapper.builder().build();

    public PackAgeMetric(PackStore store, Sink sink) {
        this.store = store;
        this.sink = sink;
    }

    /** Empty when there is no manifest yet or it cannot be read (nothing is sent; the alarm sees missing data). */
    public OptionalDouble ageMinutes(Instant now) {
        try {
            var bytes = store.get(PackPublisher.MANIFEST_PATH);
            if (bytes.isEmpty()) return OptionalDouble.empty();
            JsonNode m = json.readTree(bytes.get());
            String at = text(m.at("/packs/index/issuedAt"));
            if (at == null) at = text(m.at("/generatedAt"));
            if (at == null) return OptionalDouble.empty();
            Instant t = OffsetDateTime.parse(at).toInstant();
            return OptionalDouble.of(Math.max(0, Duration.between(t, now).toSeconds() / 60.0));
        } catch (RuntimeException e) {
            log.warn("manifest unreadable for {}: {}", NAME, e.toString());
            return OptionalDouble.empty();
        }
    }

    public void publish(Instant now) {
        OptionalDouble age = ageMinutes(now);
        if (age.isEmpty()) return;
        try {
            sink.put(NAMESPACE, NAME, Math.round(age.getAsDouble() * 10) / 10.0);
        } catch (RuntimeException e) {
            log.warn("{} not sent: {}", NAME, e.toString());
        }
    }

    private static String text(JsonNode n) {
        return n == null || n.isMissingNode() || n.isNull() ? null : n.asString();
    }
}
