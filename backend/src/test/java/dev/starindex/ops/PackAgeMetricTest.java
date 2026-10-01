package dev.starindex.ops;

import dev.starindex.pack.LocalPackStore;
import dev.starindex.pack.PackPublisher;
import dev.starindex.pack.PackStore;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

class PackAgeMetricTest {
    @TempDir Path dir;

    record Sent(String ns, String name, double value) {}

    @Test
    void ageIsMinutesSinceTheIssueOfTheLivePack() throws Exception {
        var store = new LocalPackStore(dir);
        // The committed contract manifest: index issued 2026-10-12 17:00 KST.
        store.put(PackPublisher.MANIFEST_PATH, Files.readAllBytes(Path.of("../contracts/golden/manifest-v1.json")), "application/json", PackStore.MANIFEST);
        List<Sent> sent = new ArrayList<>();
        var metric = new PackAgeMetric(store, (ns, name, v) -> sent.add(new Sent(ns, name, v)));
        metric.publish(Instant.parse("2026-10-12T10:30:00Z"));   // 19:30 KST
        assertEquals(List.of(new Sent("StarIndex", "PackAgeMinutes", 150.0)), sent);
    }

    @Test
    void fallsBackToGeneratedAtAndSendsNothingWithoutAManifest() {
        var store = new LocalPackStore(dir);
        List<Double> sent = new ArrayList<>();
        var metric = new PackAgeMetric(store, (ns, name, v) -> sent.add(v));
        metric.publish(Instant.now());
        assertTrue(sent.isEmpty(), "no manifest: the alarm sees missing data (breaching)");
        store.put(PackPublisher.MANIFEST_PATH, "{\"generatedAt\":\"2026-10-12T17:21:00+09:00\",\"packs\":{}}".getBytes(StandardCharsets.UTF_8),
                "application/json", PackStore.MANIFEST);
        metric.publish(Instant.parse("2026-10-12T08:31:00Z"));
        assertEquals(List.of(10.0), sent);
        store.put(PackPublisher.MANIFEST_PATH, "not json".getBytes(StandardCharsets.UTF_8), "application/json", PackStore.MANIFEST);
        metric.publish(Instant.now());
        assertEquals(1, sent.size(), "unreadable manifest: nothing sent, no exception");
    }

    @Test
    void aFailingSinkIsLoggedNotThrown() throws Exception {
        var store = new LocalPackStore(dir);
        store.put(PackPublisher.MANIFEST_PATH, Files.readAllBytes(Path.of("../contracts/golden/manifest-v1.json")), "application/json", PackStore.MANIFEST);
        var metric = new PackAgeMetric(store, (ns, name, v) -> { throw new IllegalStateException("throttled"); });
        assertDoesNotThrow(() -> metric.publish(Instant.now()));
    }
}
