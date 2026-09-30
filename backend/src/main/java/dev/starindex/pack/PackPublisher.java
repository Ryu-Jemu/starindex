package dev.starindex.pack;

import dev.starindex.astro.AstroCalculator;
import dev.starindex.etl.EtlRepository;
import dev.starindex.index.IndexService;
import dev.starindex.index.StarIndexCalculator;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.support.TransactionTemplate;
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

    /** {@code live}: the manifest now points at this pack (false for a backfill of an older night or issue). */
    public record Published(String version, String path, String sha256, int bytes, int rawBytes, int regions,
                            int scored, boolean newVersion, boolean live) {}

    /** pg_advisory_xact_lock key for the manifest read-modify-write ("SIPK"); retention reads the manifest under it too. */
    public static final long MANIFEST_LOCK = 0x5349504BL;

    private final PackStore store;
    private final EtlRepository repo;
    private final StringRedisTemplate redis;
    private final JdbcTemplate jdbc;
    private final TransactionTemplate tx;
    private final JsonMapper json = JsonMapper.builder().build();

    public PackPublisher(PackStore store, EtlRepository repo, StringRedisTemplate redis, JdbcTemplate jdbc, TransactionTemplate tx) {
        this.store = store;
        this.repo = repo;
        this.redis = redis;
        this.jdbc = jdbc;
        this.tx = tx;
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

        // Immutable path: if this version already exists, what clients download is the STORED file; describe that one
        // everywhere (a JDK/zlib change could compress the same JSON differently).
        byte[] stored = store.get(path).orElse(null);
        if (stored == null) {
            store.put(path, packed.gzipBytes(), "application/gzip", PackStore.IMMUTABLE);
            stored = packed.gzipBytes();
        }
        String sha = PackWriter.sha256(stored);
        boolean fresh = repo.insertPack("index", version, nightDate, issuedAt, path, sha, stored.length);

        int scored = (int) nights.stream().filter(n -> n.score() != null).count();
        boolean live = promote(version, path, sha, stored.length, nightDate, issuedAt);
        if (live) notifyLive(version);
        log.info("index pack {} → {} ({} B gz, {} regions, {} scored, {}, {})", version, store.describe(path),
                stored.length, regions.size(), scored, fresh ? "new" : "unchanged", live ? "live" : "stored only (older than the live pack)");
        return new Published(version, path, sha, stored.length, packed.rawBytes(), regions.size(), scored, fresh, live);
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

    /**
     * Points the manifest at this pack unless the live pack is for a later night, or the same night from a later
     * issue: a backfill ({@code publish nightDate=<past>}) must not roll every client back. The read-modify-write runs
     * under a PostgreSQL advisory lock, so the scheduler and a CLI run cannot interleave.
     */
    private boolean promote(String version, String path, String sha, int bytes, LocalDate nightDate, Instant issuedAt) {
        Boolean promoted = tx.execute(status -> {
            jdbc.queryForObject("SELECT pg_advisory_xact_lock(?)", Object.class, MANIFEST_LOCK);
            Map<String, Object> manifest = new LinkedHashMap<>();
            store.get(MANIFEST_PATH).ifPresent(b -> {
                try {
                    @SuppressWarnings("unchecked")
                    Map<String, Object> old = json.readValue(b, LinkedHashMap.class);
                    manifest.putAll(old);
                } catch (RuntimeException e) {
                    log.warn("existing manifest unreadable, rewriting: {}", e.toString());
                }
            });
            @SuppressWarnings("unchecked")
            Map<String, Object> packs = manifest.get("packs") instanceof Map<?, ?> p ? new LinkedHashMap<>((Map<String, Object>) p) : new LinkedHashMap<>();
            if (packs.get("index") instanceof Map<?, ?> current && isNewer(current, nightDate, issuedAt)) return false;
            Map<String, Object> entry = new LinkedHashMap<>();
            entry.put("version", version);
            entry.put("path", path);
            entry.put("sha256", sha);
            entry.put("bytes", bytes);
            entry.put("nightDate", nightDate.toString());
            entry.put("issuedAt", issuedAt == null ? null : kst(issuedAt));
            packs.put("index", entry);
            manifest.put("schema", 1);
            manifest.put("generatedAt", kst(Instant.now().truncatedTo(ChronoUnit.SECONDS)));
            manifest.put("packs", packs);
            store.put(MANIFEST_PATH, json.writeValueAsBytes(manifest), "application/json", PackStore.MANIFEST);
            return true;
        });
        return Boolean.TRUE.equals(promoted);
    }

    /** True when the live entry is for a later night, or the same night issued later than {@code issuedAt}. */
    static boolean isNewer(Map<?, ?> current, LocalDate nightDate, Instant issuedAt) {
        try {
            LocalDate liveNight = LocalDate.parse(String.valueOf(current.get("nightDate")));
            if (liveNight.isAfter(nightDate)) return true;
            if (liveNight.isBefore(nightDate)) return false;
            Object liveIssued = current.get("issuedAt");
            if (liveIssued == null || issuedAt == null) return false;
            return OffsetDateTime.parse(liveIssued.toString()).toInstant().isAfter(issuedAt);
        } catch (RuntimeException e) {
            return false;   // unreadable entry: replace it
        }
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
