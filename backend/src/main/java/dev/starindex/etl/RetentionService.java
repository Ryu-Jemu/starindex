package dev.starindex.etl;

import dev.starindex.astro.AstroCalculator;
import dev.starindex.index.IndexService;
import dev.starindex.pack.PackPublisher;
import dev.starindex.pack.PackStore;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.batch.core.repository.JobRepository;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.support.TransactionTemplate;
import tools.jackson.databind.json.JsonMapper;

import java.sql.Date;
import java.sql.Timestamp;
import java.time.Duration;
import java.time.Instant;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.time.OffsetDateTime;
import java.time.ZoneId;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.function.IntSupplier;

/**
 * Data lifecycle (ADR-018, replacing ADR-014's 2/8 days): collected data lives about 12 hours, history 2 days.
 * <ul>
 *   <li>{@code kma_forecast_hour}: rows whose forecast time is older than {@code data-retention} (12 h). Rows for
 *   coming hours survive an ingestion outage.</li>
 *   <li>Night- or day-keyed data ({@code kasi_riseset}, {@code star_index_nightly}, calendars): once that night or day
 *   has passed (the night turns at 06:00 KST); a monthly feature article (dated the 1st) stays until its month ends.</li>
 *   <li>History ({@code etl_api_call}, {@code astro_crosscheck}, {@code data_pack} + pack files, Spring Batch
 *   metadata): older than {@code history-retention} (2 days); the live, newest-3 and pinned packs always stay.</li>
 * </ul>
 * Runs at the end of every forecast run (every 3 hours) and in the daily job, so nothing outlives its limit by more
 * than one run. Every cutoff derives from one {@code asOf} in Java (never SQL {@code now()}), so tests can pin it.
 * Each item runs on its own: a failure becomes a warning and the others still run.
 */
@Service
public class RetentionService {
    private static final Logger log = LoggerFactory.getLogger(RetentionService.class);
    /** Version directories retention may sweep; the manifest is never touched. */
    static final List<String> PACK_DIRS = List.of("packs/index/", "packs/events/", "packs/spots/");

    public record Result(LinkedHashMap<String, Integer> deleted, List<String> warnings) {}

    private record Candidate(long id, String kind, String version, String path) {}

    private final JdbcTemplate jdbc;
    private final TransactionTemplate tx;
    private final JobRepository jobs;
    private final PackStore store;
    private final EtlProperties.Etl etl;
    private final JsonMapper json = JsonMapper.builder().build();

    public RetentionService(JdbcTemplate jdbc, TransactionTemplate tx, JobRepository jobs, PackStore store, EtlProperties.Etl etl) {
        this.jdbc = jdbc;
        this.tx = tx;
        this.jobs = jobs;
        this.store = store;
        this.etl = etl;
    }

    public Result purge(Instant asOf) {
        var deleted = new LinkedHashMap<String, Integer>();
        var warnings = new ArrayList<String>();
        LocalDate night = IndexService.nightDateOf(asOf.atZone(AstroCalculator.KST));
        Instant dataCut = asOf.minus(etl.dataRetention()), historyCut = asOf.minus(etl.historyRetention());
        LocalDate historyDay = historyCut.atZone(AstroCalculator.KST).toLocalDate();

        item(deleted, warnings, "kma_forecast_hour", () -> jdbc.update("DELETE FROM kma_forecast_hour WHERE fcst_at < ?", ts(dataCut)));
        item(deleted, warnings, "kasi_riseset", () -> jdbc.update("DELETE FROM kasi_riseset WHERE locdate < ?", date(night)));
        item(deleted, warnings, "star_index_nightly", () -> jdbc.update("DELETE FROM star_index_nightly WHERE night_date < ?", date(night)));
        item(deleted, warnings, "astro_crosscheck", () -> jdbc.update("DELETE FROM astro_crosscheck WHERE night_date < ?", date(historyDay)));
        item(deleted, warnings, "etl_api_call", () -> jdbc.update("DELETE FROM etl_api_call WHERE called_at < ?", ts(historyCut)));
        // A monthly feature article is dated the 1st but covers its whole month: it stays until the month is over.
        item(deleted, warnings, "kasi_astro_event", () -> jdbc.update(
                "DELETE FROM kasi_astro_event WHERE locdate < ? AND NOT (month_feature AND locdate >= ?)",
                date(night), date(night.withDayOfMonth(1))));
        item(deleted, warnings, "kasi_special_day", () -> jdbc.update("DELETE FROM kasi_special_day WHERE locdate < ?", date(night)));
        item(deleted, warnings, "kasi_lunar_day", () -> jdbc.update("DELETE FROM kasi_lunar_day WHERE sol_date < ?", date(night)));
        try {
            purgePacks(historyCut, deleted, warnings);
        } catch (RuntimeException e) {
            warnings.add("팩 정리 실패: " + e);
        }
        item(deleted, warnings, "batch_job_instance", () -> purgeBatch(historyCut, warnings));
        if (!warnings.isEmpty()) log.warn("retention warnings: {}", warnings);
        return new Result(deleted, warnings);
    }

    private static void item(Map<String, Integer> deleted, List<String> warnings, String name, IntSupplier work) {
        try {
            deleted.put(name, work.getAsInt());
        } catch (RuntimeException e) {
            warnings.add(name + " 정리 실패: " + e);
        }
    }

    /**
     * Keeps every version the manifest points at, the newest {@code packKeepMin} per kind and pinned ones; deletes the
     * rest once older than the long cutoff, row and file together. Candidates are chosen under the manifest lock
     * (no listing or deletion inside it, so publishing is never blocked by storage calls).
     */
    private void purgePacks(Instant cutoff, Map<String, Integer> deleted, List<String> warnings) {
        Set<String> currentVersions = new HashSet<>(), currentPaths = new HashSet<>();
        List<Candidate> candidates = tx.execute(s -> {
            jdbc.queryForObject("SELECT pg_advisory_xact_lock(?)", Object.class, PackPublisher.MANIFEST_LOCK);
            readManifest(currentVersions, currentPaths);
            return jdbc.query("""
                    SELECT id, kind, version, path FROM (
                      SELECT id, kind, version, path, pinned, published_at,
                             row_number() OVER (PARTITION BY kind ORDER BY published_at DESC, id DESC) AS rn
                      FROM data_pack) p
                    WHERE rn > ? AND NOT pinned AND published_at < ?""",
                    (rs, i) -> new Candidate(rs.getLong("id"), rs.getString("kind"), rs.getString("version"), rs.getString("path")),
                    etl.packKeepMin(), ts(cutoff)).stream()
                    .filter(c -> !currentVersions.contains(c.version()) && !currentPaths.contains(c.path())).toList();
        });
        int rows = 0;
        for (Candidate c : candidates == null ? List.<Candidate>of() : candidates) {
            try {
                // Row first inside the transaction, then the file: a failed file delete rolls the row back (retried
                // tomorrow), and FOR UPDATE makes a concurrent pin wait instead of pinning a pack being deleted.
                Boolean done = tx.execute(s -> {
                    List<Boolean> pinned = jdbc.queryForList("SELECT pinned FROM data_pack WHERE id = ? FOR UPDATE", Boolean.class, c.id());
                    if (pinned.isEmpty() || pinned.getFirst()) return false;
                    jdbc.update("DELETE FROM data_pack WHERE id = ?", c.id());
                    store.delete(c.path());
                    return true;
                });
                if (Boolean.TRUE.equals(done)) rows++;
            } catch (RuntimeException e) {
                warnings.add("팩 " + c.kind() + " " + c.version() + " 삭제 실패(행 유지, 내일 재시도): " + e);
            }
        }
        deleted.put("data_pack", rows);

        // Orphans: files no row describes (a crash between put and insert, or a row deleted by hand). Judged by the
        // file's own age, never by the night date in the version name (a backfill writes an old night today).
        Set<String> keepDirs = new HashSet<>();
        for (String p : jdbc.queryForList("SELECT path FROM data_pack", String.class)) keepDirs.add(dir(p));
        for (String p : currentPaths) keepDirs.add(dir(p));
        int files = 0;
        List<PackStore.Entry> stored = new ArrayList<>();
        for (String prefix : PACK_DIRS) stored.addAll(store.list(prefix));   // never walks packs/manifest/
        for (PackStore.Entry e : stored) {
            if (keepDirs.contains(dir(e.path())) || !e.lastModified().isBefore(cutoff)) continue;
            try {
                store.delete(e.path());
                files++;
            } catch (RuntimeException ex) {
                warnings.add("고아 팩 파일 " + e.path() + " 삭제 실패: " + ex);
            }
        }
        deleted.put("pack_orphan_files", files);
    }

    /** Current versions and paths of every kind in the manifest. An unreadable manifest stops pack deletion. */
    private void readManifest(Set<String> versions, Set<String> paths) {
        byte[] bytes = store.get(PackPublisher.MANIFEST_PATH).orElse(null);
        if (bytes == null) return;
        Map<?, ?> manifest = json.readValue(bytes, Map.class);   // throws → the whole pack item becomes a warning
        if (manifest.get("packs") instanceof Map<?, ?> packs)
            for (Object entry : packs.values())
                if (entry instanceof Map<?, ?> m) {
                    if (m.get("version") != null) versions.add(m.get("version").toString());
                    if (m.get("path") != null) paths.add(m.get("path").toString());
                }
    }

    /**
     * Spring Batch metadata: whole job instances whose newest execution is older than the cutoff and none is running.
     * Deleted through the JobRepository API so Spring Batch keeps its own foreign-key order. BATCH_* timestamps are
     * JVM-local {@code LocalDateTime}s, hence the conversion in the JVM zone.
     */
    private int purgeBatch(Instant cutoff, List<String> warnings) {
        LocalDateTime bCut = LocalDateTime.ofInstant(cutoff, ZoneId.systemDefault());
        List<Long> ids = jdbc.queryForList("""
                SELECT i.JOB_INSTANCE_ID FROM BATCH_JOB_INSTANCE i
                JOIN BATCH_JOB_EXECUTION e ON e.JOB_INSTANCE_ID = i.JOB_INSTANCE_ID
                GROUP BY i.JOB_INSTANCE_ID
                HAVING MAX(e.CREATE_TIME) < ? AND bool_and(e.STATUS NOT IN ('STARTING', 'STARTED', 'STOPPING'))""",
                Long.class, Timestamp.valueOf(bCut));
        int n = 0;
        for (long id : ids) {
            try {
                var instance = jobs.getJobInstance(id);
                if (instance == null) continue;
                jobs.deleteJobInstance(instance);
                n++;
            } catch (RuntimeException e) {
                warnings.add("Batch 인스턴스 " + id + " 삭제 실패: " + e);
            }
        }
        return n;
    }

    private static String dir(String path) {
        int i = path.lastIndexOf('/');
        return i < 0 ? "" : path.substring(0, i + 1);
    }

    private static OffsetDateTime ts(Instant i) { return OffsetDateTime.ofInstant(i, ZoneOffset.UTC); }

    private static Date date(LocalDate d) { return Date.valueOf(d); }
}
