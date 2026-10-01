package dev.starindex.etl;

import dev.starindex.IntegrationTestBase;
import dev.starindex.pack.PackPublisher;
import dev.starindex.pack.PackStore;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.batch.core.job.Job;
import org.springframework.batch.core.job.parameters.JobParametersBuilder;
import org.springframework.batch.core.launch.JobOperator;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.jdbc.core.JdbcTemplate;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.attribute.FileTime;
import java.sql.Timestamp;
import java.time.Duration;
import java.time.Instant;
import java.time.LocalDateTime;
import java.time.OffsetDateTime;
import java.time.ZoneId;
import java.time.ZoneOffset;
import java.time.temporal.ChronoUnit;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

/** ADR-018 lifecycle with a pinned asOf (boundaries ±1 s / ±1 day): 12 h data, past nights, 2-day history, packs, Batch. */
class RetentionServiceTest extends IntegrationTestBase {
    @Autowired RetentionService retention;
    @Autowired JdbcTemplate jdbc;
    @Autowired PackStore store;
    @Autowired EtlProperties.Pack packProps;
    @Autowired JobOperator jobs;
    @Autowired @Qualifier("healthcheckJob") Job healthcheckJob;

    /** 00:30 KST on the 1st: the night in progress is still the last day of the previous month. */
    static final Instant AS_OF = OffsetDateTime.parse("2026-03-01T00:30:00+09:00").toInstant();
    static final long SEOUL = 1100000000L;

    @BeforeEach
    void clean() throws Exception {
        jdbc.execute("TRUNCATE kma_forecast_hour, kasi_riseset, star_index_nightly, astro_crosscheck, etl_api_call, "
                + "kasi_astro_event, kasi_special_day, kasi_lunar_day, data_pack");
        Path root = Path.of(packProps.localDir());
        if (Files.exists(root))
            try (var paths = Files.walk(root)) {
                paths.sorted(java.util.Comparator.reverseOrder()).filter(p -> !p.equals(root)).forEach(p -> p.toFile().delete());
            }
    }

    static OffsetDateTime ts(Instant i) { return OffsetDateTime.ofInstant(i, ZoneOffset.UTC); }

    int count(String sql, Object... args) { return jdbc.queryForObject(sql, Integer.class, args); }

    @Test
    void everyTableKeepsExactlyItsWindow() {
        Instant dataCut = AS_OF.minus(Duration.ofHours(12)), historyCut = AS_OF.minus(Duration.ofDays(2));
        jdbc.update("INSERT INTO kma_forecast_hour (nx, ny, fcst_at, base_at, sky) VALUES (60, 127, ?, ?, 1), (60, 127, ?, ?, 1)",
                ts(dataCut.minusSeconds(1)), ts(dataCut.minusSeconds(1)), ts(dataCut), ts(dataCut));
        // night = 2026-02-28 (00:30 is before 06:00) → night data keeps 02-28 on; history keeps from 02-27 00:30.
        jdbc.update("INSERT INTO kasi_riseset (region_id, locdate) VALUES (?, '2026-02-27'), (?, '2026-02-28')", SEOUL, SEOUL);
        jdbc.update("INSERT INTO star_index_nightly (region_id, night_date, base_at, score, grade) VALUES "
                + "(?, '2026-02-27', now(), 50, 'FAIR'), (?, '2026-02-28', now(), 50, 'FAIR')", SEOUL, SEOUL);
        jdbc.update("INSERT INTO astro_crosscheck (region_id, night_date, field, diff_seconds) VALUES "
                + "(?, '2026-02-26', 'sunset', 1), (?, '2026-02-27', 'sunset', 1)", SEOUL, SEOUL);
        jdbc.update("INSERT INTO etl_api_call (source, operation, request_key, duration_ms, outcome, called_at) VALUES "
                + "('KMA_VILAGE', 'op', 'a', 1, 'OK', ?), ('KMA_VILAGE', 'op', 'b', 1, 'OK', ?)", ts(historyCut.minusSeconds(1)), ts(historyCut.plusSeconds(1)));
        jdbc.update("INSERT INTO kasi_astro_event (locdate, seq, event) VALUES ('2026-02-27', 1, 'x'), ('2026-02-28', 1, 'x')");
        jdbc.update("INSERT INTO kasi_special_day (locdate, date_kind, date_name, is_holiday) VALUES "
                + "('2026-02-27', '01', 'x', false), ('2026-02-28', '01', 'x', true)");
        jdbc.update("INSERT INTO kasi_lunar_day (sol_date, lun_year, lun_month, lun_day, lun_leap) VALUES "
                + "('2026-02-27', 2026, 1, 11, false), ('2026-02-28', 2026, 1, 12, false)");

        var r = retention.purge(AS_OF);

        assertEquals(List.of(), r.warnings());
        for (String t : List.of("kma_forecast_hour", "kasi_riseset", "star_index_nightly", "astro_crosscheck", "etl_api_call",
                "kasi_astro_event", "kasi_special_day", "kasi_lunar_day")) {
            assertEquals(1, r.deleted().get(t), t + " deleted");
            assertEquals(1, count("SELECT COUNT(*) FROM " + t), t + " kept");
        }
        assertEquals(1, count("SELECT COUNT(*) FROM kma_forecast_hour WHERE fcst_at = ?", ts(dataCut)));
        assertEquals(1, count("SELECT COUNT(*) FROM kasi_astro_event WHERE locdate = '2026-02-28'"),
                "at 00:30 on 03-01 the night in progress is 02-28: its data stays until 06:00");
    }

    @Test
    void forecastHoursStillToComeSurviveAnIngestionOutage() {
        // The newest issue is 3 days old (no ingestion since), but its hours ahead of asOf are kept: lifetime counts
        // from the forecast time, not from when the row was collected.
        jdbc.update("INSERT INTO kma_forecast_hour (nx, ny, fcst_at, base_at, sky) VALUES (60, 127, ?, ?, 1)",
                ts(AS_OF.plus(Duration.ofHours(5))), ts(AS_OF.minus(Duration.ofDays(3))));
        retention.purge(AS_OF);
        assertEquals(1, count("SELECT COUNT(*) FROM kma_forecast_hour"));
    }

    @Test
    void theNightTurnsAtSixKst() {
        jdbc.update("INSERT INTO star_index_nightly (region_id, night_date, base_at, score, grade) VALUES (?, '2026-02-27', now(), 50, 'FAIR')", SEOUL);
        retention.purge(OffsetDateTime.parse("2026-02-28T05:59:59+09:00").toInstant());   // night 02-27 still in progress
        assertEquals(1, count("SELECT COUNT(*) FROM star_index_nightly"));
        retention.purge(OffsetDateTime.parse("2026-02-28T06:00:00+09:00").toInstant());   // night 02-28 → 02-27 has passed
        assertEquals(0, count("SELECT COUNT(*) FROM star_index_nightly"));
    }

    // ------------------------------------------------------------------ packs

    Instant now = Instant.now().truncatedTo(ChronoUnit.SECONDS);

    String pack(String kind, String version, int daysAgo, boolean pinned) {
        String path = "packs/" + kind + "/" + version + "/" + kind + ".json.gz";
        store.put(path, version.getBytes(StandardCharsets.UTF_8), "application/gzip", PackStore.IMMUTABLE);
        jdbc.update("INSERT INTO data_pack (kind, version, path, sha256, bytes, published_at, pinned) VALUES (?, ?, ?, ?, 1, ?, ?)",
                kind, version, path, "0".repeat(64), ts(now.minus(Duration.ofDays(daysAgo))), pinned);
        return path;
    }

    Path file(String path) { return Path.of(packProps.localDir()).resolve(path); }

    @Test
    void packsKeepCurrentNewestThreeAndPinnedAndOrphansGoByFileAge() throws Exception {
        String i1 = pack("index", "i1", 14, false);   // current (manifest), oldest
        String i2 = pack("index", "i2", 13, true);    // pinned
        String i3 = pack("index", "i3", 12, false);   // → deleted
        pack("index", "i4", 11, false);               // newest three: i4..i6
        pack("index", "i5", 10, false);
        pack("index", "i6", 9, false);
        String e1 = pack("events", "e1", 20, false);  // only two events packs: both within the newest three
        pack("events", "e2", 19, false);
        String manifest = """
                {"schema":1,"packs":{"index":{"version":"i1","path":"%s"},"events":{"version":"e1","path":"%s"}}}""".formatted(i1, e1);
        store.put(PackPublisher.MANIFEST_PATH, manifest.getBytes(StandardCharsets.UTF_8), "application/json", PackStore.MANIFEST);
        store.put("packs/index/orphan-old/index.json.gz", new byte[]{1}, "application/gzip", PackStore.IMMUTABLE);
        Files.setLastModifiedTime(file("packs/index/orphan-old/index.json.gz"), FileTime.from(now.minus(Duration.ofDays(9))));
        store.put("packs/index/20250101-1700-backfill/index.json.gz", new byte[]{1}, "application/gzip", PackStore.IMMUTABLE);
        Files.setLastModifiedTime(file(PackPublisher.MANIFEST_PATH), FileTime.from(now.minus(Duration.ofDays(30))));

        var r = retention.purge(now);

        assertEquals(List.of(), r.warnings());
        assertEquals(1, r.deleted().get("data_pack"));
        assertEquals(1, r.deleted().get("pack_orphan_files"));
        assertEquals(List.of("e1", "e2", "i1", "i2", "i4", "i5", "i6"),
                jdbc.queryForList("SELECT version FROM data_pack ORDER BY version", String.class));
        assertFalse(Files.exists(file(i3)));
        assertFalse(Files.exists(file(i3).getParent()), "the empty version directory goes too");
        assertTrue(Files.exists(file(i2)));
        assertFalse(Files.exists(file("packs/index/orphan-old/index.json.gz")), "orphan older than 2 days");
        assertTrue(Files.exists(file("packs/index/20250101-1700-backfill/index.json.gz")),
                "a fresh file of an old night is kept: age comes from the file, not the version name");
        assertTrue(Files.exists(file(PackPublisher.MANIFEST_PATH)), "the manifest is never swept");

        assertEquals(0, retention.purge(now).deleted().get("data_pack"), "idempotent");
    }

    @Test
    void anUnreadableManifestStopsPackDeletionWithAWarning() {
        pack("index", "i1", 14, false);
        for (int i = 2; i <= 4; i++) pack("index", "i" + i, 14 - i, false);
        store.put(PackPublisher.MANIFEST_PATH, "{not json".getBytes(StandardCharsets.UTF_8), "application/json", PackStore.MANIFEST);
        var r = retention.purge(now);
        assertEquals(1, r.warnings().size(), r.warnings().toString());
        assertEquals(4, count("SELECT COUNT(*) FROM data_pack"), "without the manifest nothing is known to be safe");
        assertEquals(0, r.deleted().get("kma_forecast_hour"), "the other items still ran");
    }

    // ------------------------------------------------------------------ Spring Batch metadata

    long runHealthcheck() throws Exception {
        return jobs.start(healthcheckJob, new JobParametersBuilder().addLong("run", System.nanoTime()).toJobParameters()).getJobInstanceId();
    }

    int batchRows(long instance) {
        return count("SELECT COUNT(*) FROM BATCH_JOB_INSTANCE WHERE JOB_INSTANCE_ID = ?", instance)
                + count("SELECT COUNT(*) FROM BATCH_JOB_EXECUTION WHERE JOB_INSTANCE_ID = ?", instance)
                + count("SELECT COUNT(*) FROM BATCH_JOB_EXECUTION_PARAMS p JOIN BATCH_JOB_EXECUTION e USING (JOB_EXECUTION_ID) WHERE e.JOB_INSTANCE_ID = ?", instance)
                + count("SELECT COUNT(*) FROM BATCH_JOB_EXECUTION_CONTEXT c JOIN BATCH_JOB_EXECUTION e USING (JOB_EXECUTION_ID) WHERE e.JOB_INSTANCE_ID = ?", instance)
                + count("SELECT COUNT(*) FROM BATCH_STEP_EXECUTION s JOIN BATCH_JOB_EXECUTION e USING (JOB_EXECUTION_ID) WHERE e.JOB_INSTANCE_ID = ?", instance)
                + count("""
                        SELECT COUNT(*) FROM BATCH_STEP_EXECUTION_CONTEXT sc JOIN BATCH_STEP_EXECUTION s USING (STEP_EXECUTION_ID)
                        JOIN BATCH_JOB_EXECUTION e ON e.JOB_EXECUTION_ID = s.JOB_EXECUTION_ID WHERE e.JOB_INSTANCE_ID = ?""", instance);
    }

    void age(long instance, int days, String status) {
        jdbc.update("UPDATE BATCH_JOB_EXECUTION SET CREATE_TIME = ?, STATUS = ? WHERE JOB_INSTANCE_ID = ?",
                Timestamp.valueOf(LocalDateTime.ofInstant(now.minus(Duration.ofDays(days)), ZoneId.systemDefault())), status, instance);
    }

    @Test
    void batchMetadataOlderThanTwoDaysGoesAsWholeInstancesButNeverARunningOne() throws Exception {
        long old1 = runHealthcheck(), old2 = runHealthcheck(), recent = runHealthcheck(), running = runHealthcheck();
        age(old1, 3, "COMPLETED");
        age(old2, 3, "FAILED");
        age(running, 3, "STARTED");
        age(recent, 1, "COMPLETED");
        assertTrue(batchRows(old1) >= 5, "instance, execution, params, contexts and step rows exist before");

        var r = retention.purge(now);

        assertEquals(List.of(), r.warnings());
        assertTrue(r.deleted().get("batch_job_instance") >= 2);
        assertEquals(0, batchRows(old1));
        assertEquals(0, batchRows(old2));
        assertTrue(batchRows(recent) > 0);
        assertTrue(batchRows(running) > 0, "a running execution is never deleted");
        age(running, 0, "COMPLETED");
    }
}
