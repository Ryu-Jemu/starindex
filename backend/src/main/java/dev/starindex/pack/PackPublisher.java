package dev.starindex.pack;

import dev.starindex.astro.AstroCalculator;
import dev.starindex.etl.EtlRepository;
import dev.starindex.index.IndexService;
import dev.starindex.index.StarIndexCalculator;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Service;
import tools.jackson.databind.json.JsonMapper;

import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.time.LocalDate;
import java.time.LocalTime;
import java.time.OffsetDateTime;
import java.time.format.DateTimeFormatter;
import java.time.temporal.ChronoUnit;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;

/**
 * Builds and publishes the nationwide index pack (SERVICE-PLAN 8.3, schema 2) and updates the manifest.
 * The version is {@code yyyyMMdd-HHmm-<content hash>}: publishing identical input again yields the same version and
 * the same bytes (no timestamps inside the pack), so reruns are idempotent. The manifest carries generatedAt.
 */
@Service
public class PackPublisher {
    private static final Logger log = LoggerFactory.getLogger(PackPublisher.class);
    public static final String MANIFEST_PATH = "packs/manifest/latest.json";
    private static final DateTimeFormatter HHMM = DateTimeFormatter.ofPattern("HHmm");
    private static final List<String> ATTRIBUTION = List.of(
            "기상청 단기예보 조회서비스 (공공누리 제1유형, 출처: 기상청)",
            "한국천문연구원 출몰시각·천문현상 정보",
            "Astronomy Engine v2.1.19 (MIT)");

    public record Published(String version, String path, String sha256, int bytes, int rawBytes, int regions,
                            int scored, boolean newVersion) {}

    private final PackStore store;
    private final EtlRepository repo;
    private final StringRedisTemplate redis;
    private final JsonMapper json = JsonMapper.builder().build();

    public PackPublisher(PackStore store, EtlRepository repo, StringRedisTemplate redis) {
        this.store = store;
        this.repo = repo;
        this.redis = redis;
    }

    public Published publishIndex(LocalDate nightDate, List<IndexService.RegionNight> nights, int slots) {
        Instant issuedAt = nights.stream().map(IndexService.RegionNight::baseAt).filter(Objects::nonNull)
                .max(Comparator.naturalOrder()).orElse(null);
        List<Map<String, Object>> regions = new ArrayList<>();
        for (var n : nights) regions.add(region(n, slots));
        byte[] regionBytes = json.writeValueAsBytes(regions);
        String version = nightDate.format(DateTimeFormatter.BASIC_ISO_DATE) + "-"
                + (issuedAt == null ? "0000" : HHMM.format(issuedAt.atZone(AstroCalculator.KST)))
                + "-" + PackWriter.sha256(regionBytes).substring(0, 8);

        Map<String, Object> doc = new LinkedHashMap<>();
        doc.put("schema", 2);
        doc.put("kind", "index");
        doc.put("version", version);
        doc.put("nightDate", nightDate.toString());
        doc.put("issuedAt", issuedAt == null ? null : kst(issuedAt));
        doc.put("hourlyStep", 1);
        doc.put("attribution", ATTRIBUTION);
        doc.put("regions", regions);
        var packed = PackWriter.gzip(json.writeValueAsBytes(doc));
        String path = "packs/index/" + version + "/index.json.gz";

        boolean fresh = repo.insertPack("index", version, nightDate, issuedAt, path, packed.sha256(),
                packed.gzipBytes().length, packed.rawBytes(), regions.size());
        if (fresh || store.get(path).isEmpty()) store.put(path, packed.gzipBytes(), "application/gzip", PackStore.IMMUTABLE);

        int scored = (int) nights.stream().filter(n -> n.score() != null).count();
        writeManifest(version, path, packed, nightDate, issuedAt);
        notifyLive(version);
        log.info("index pack {} → {} ({} B gz, {} regions, {} scored, {})", version, store.describe(path),
                packed.gzipBytes().length, regions.size(), scored, fresh ? "new" : "unchanged");
        return new Published(version, path, packed.sha256(), packed.gzipBytes().length, packed.rawBytes(), regions.size(), scored, fresh);
    }

    private Map<String, Object> region(IndexService.RegionNight n, int slots) {
        var r = n.region();
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("id", Long.toString(r.getId()));
        m.put("name", r.getNameKo());
        m.put("kind", r.getKind().name());
        m.put("grid", List.of(r.getKmaNx(), r.getKmaNy()));
        StarIndexCalculator.NightScore s = n.score();
        m.put("score", s == null ? null : s.score());
        m.put("grade", s == null ? null : s.grade().name());
        m.put("best", s == null ? null : List.of(hhmm(s.bestFrom()), hhmm(s.bestTo())));
        m.put("reasons", s == null ? List.of("NO_FORECAST") : s.reasons());
        m.put("contrib", s == null ? null : s.contributions());
        m.put("twilight", twilight(n));
        Map<String, Object> hourly = new LinkedHashMap<>();
        hourly.put("t0", kst(n.seriesStart()));
        for (String c : IndexService.SERIES) {
            List<Number> values = new ArrayList<>(slots);
            for (int i = 0; i < slots; i++) {
                var v = n.series().get(n.seriesStart().plus(i, ChronoUnit.HOURS));
                Double d = v == null ? null : v.get(c);
                values.add(d == null ? null : (c.equals("TMP") || c.equals("WSD") ? d : (Number) (int) Math.round(d)));
            }
            hourly.put(c.toLowerCase(), values);
        }
        m.put("hourly", hourly);
        return m;
    }

    /** KASI evening times when stored (the app shows them as "(천문연)"), always the computed ones as fallback. */
    private Map<String, Object> twilight(IndexService.RegionNight n) {
        Map<String, Object> t = new LinkedHashMap<>();
        Map<String, LocalTime> k = repo.findKasiEvening(n.region().getId(), n.night().nightDate());
        Map<String, Object> kasi = new LinkedHashMap<>();
        for (String f : List.of("sunset", "civile", "naute", "aste")) {
            LocalTime lt = k.get(f);
            kasi.put(f, lt == null ? null : lt.format(HHMM));
        }
        t.put("kasi", k.isEmpty() ? null : kasi);
        var night = n.night();
        Map<String, Object> computed = new LinkedHashMap<>();
        computed.put("sunset", hhmm(night.sunset()));
        computed.put("civile", hhmm(night.civilDusk()));
        computed.put("naute", hhmm(night.nauticalDusk()));
        computed.put("aste", hhmm(night.astronomicalDusk()));
        computed.put("astm", hhmm(night.astronomicalDawn()));
        computed.put("sunrise", hhmm(night.sunrise()));
        t.put("computed", computed);
        return t;
    }

    private void writeManifest(String version, String path, PackWriter.Packed packed, LocalDate nightDate, Instant issuedAt) {
        Map<String, Object> manifest = new LinkedHashMap<>();
        store.get(MANIFEST_PATH).ifPresent(bytes -> {
            try {
                @SuppressWarnings("unchecked")
                Map<String, Object> old = json.readValue(bytes, LinkedHashMap.class);
                manifest.putAll(old);
            } catch (RuntimeException e) {
                log.warn("existing manifest unreadable, rewriting: {}", e.toString());
            }
        });
        @SuppressWarnings("unchecked")
        Map<String, Object> packs = manifest.get("packs") instanceof Map<?, ?> p ? new LinkedHashMap<>((Map<String, Object>) p) : new LinkedHashMap<>();
        Map<String, Object> entry = new LinkedHashMap<>();
        entry.put("version", version);
        entry.put("path", path);
        entry.put("sha256", packed.sha256());
        entry.put("bytes", packed.gzipBytes().length);
        entry.put("nightDate", nightDate.toString());
        entry.put("issuedAt", issuedAt == null ? null : kst(issuedAt));
        packs.put("index", entry);
        manifest.put("schema", 1);
        manifest.put("generatedAt", kst(Instant.now().truncatedTo(ChronoUnit.SECONDS)));
        manifest.put("packs", packs);
        store.put(MANIFEST_PATH, json.writeValueAsBytes(manifest), "application/json", PackStore.MANIFEST);
    }

    private void notifyLive(String version) {
        try {
            redis.opsForValue().set("pack:manifest", version);
            redis.convertAndSend("ch:live", "{\"type\":\"pack\",\"kind\":\"index\",\"version\":\"" + version + "\"}");
        } catch (RuntimeException e) {
            log.warn("live notify skipped ({})", e.getClass().getSimpleName());
        }
    }

    private static String kst(Instant i) {
        return OffsetDateTime.ofInstant(i, AstroCalculator.KST).toString();
    }

    private static String hhmm(Instant i) {
        return i == null ? null : HHMM.format(i.atZone(AstroCalculator.KST));
    }

    /** For logs and tests: the UTF-8 JSON of a stored pack. */
    public static String gunzipToString(byte[] gz) {
        try (var in = new java.util.zip.GZIPInputStream(new java.io.ByteArrayInputStream(gz))) {
            return new String(in.readAllBytes(), StandardCharsets.UTF_8);
        } catch (java.io.IOException e) {
            throw new java.io.UncheckedIOException(e);
        }
    }
}
