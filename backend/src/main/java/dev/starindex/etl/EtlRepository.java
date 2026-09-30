package dev.starindex.etl;

import dev.starindex.etl.kasi.KasiClient;
import dev.starindex.etl.kma.KmaBaseTime;
import dev.starindex.etl.kma.KmaForecastClient;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

import java.sql.Date;
import java.sql.Time;
import java.time.Instant;
import java.time.LocalDate;
import java.time.LocalTime;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;

/** All ETL reads/writes (JdbcTemplate, PostgreSQL upserts). Instants are written as TIMESTAMPTZ (UTC offset). */
@Repository
public class EtlRepository {
    private final JdbcTemplate jdbc;

    public EtlRepository(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    static OffsetDateTime ts(Instant i) { return i == null ? null : OffsetDateTime.ofInstant(i, ZoneOffset.UTC); }

    static Time time(LocalTime t) { return t == null ? null : Time.valueOf(t); }

    // ---------------------------------------------------------------- KMA forecast

    /**
     * Merges one issue into kma_forecast_hour (one row per cell and forecast hour). A newer issue overwrites each item
     * it has a value for and keeps the stored value where it has none; an older issue arriving late only fills blanks.
     * With issues in order this equals "newest non-missing value per item".
     * @return hourly rows written
     */
    public int upsertForecast(KmaForecastClient.Result r) {
        OffsetDateTime base = ts(r.base().at().toInstant());
        List<Object[]> rows = new ArrayList<>();
        for (var h : KmaForecastClient.hours(r.items()))
            rows.add(new Object[]{r.nx(), r.ny(), ts(h.fcstAt()), base, h.sky(), h.pty(), h.tmp(), h.reh(), h.wsd(), h.pop()});
        jdbc.batchUpdate("""
                INSERT INTO kma_forecast_hour AS t (nx, ny, fcst_at, base_at, sky, pty, tmp, reh, wsd, pop)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (nx, ny, fcst_at) DO UPDATE SET
                  sky = CASE WHEN EXCLUDED.base_at >= t.base_at THEN COALESCE(EXCLUDED.sky, t.sky) ELSE COALESCE(t.sky, EXCLUDED.sky) END,
                  pty = CASE WHEN EXCLUDED.base_at >= t.base_at THEN COALESCE(EXCLUDED.pty, t.pty) ELSE COALESCE(t.pty, EXCLUDED.pty) END,
                  tmp = CASE WHEN EXCLUDED.base_at >= t.base_at THEN COALESCE(EXCLUDED.tmp, t.tmp) ELSE COALESCE(t.tmp, EXCLUDED.tmp) END,
                  reh = CASE WHEN EXCLUDED.base_at >= t.base_at THEN COALESCE(EXCLUDED.reh, t.reh) ELSE COALESCE(t.reh, EXCLUDED.reh) END,
                  wsd = CASE WHEN EXCLUDED.base_at >= t.base_at THEN COALESCE(EXCLUDED.wsd, t.wsd) ELSE COALESCE(t.wsd, EXCLUDED.wsd) END,
                  pop = CASE WHEN EXCLUDED.base_at >= t.base_at THEN COALESCE(EXCLUDED.pop, t.pop) ELSE COALESCE(t.pop, EXCLUDED.pop) END,
                  base_at = GREATEST(t.base_at, EXCLUDED.base_at)""", rows);
        return rows.size();
    }

    /** Stored items per forecast hour in [from, to) for one grid cell; keys SKY, PTY, TMP, REH, WSD, POP (null = none). */
    public Map<Instant, Map<String, Double>> latestForecast(int nx, int ny, Instant from, Instant to) {
        Map<Instant, Map<String, Double>> out = new HashMap<>();
        jdbc.query("""
                SELECT fcst_at, sky, pty, tmp, reh, wsd, pop FROM kma_forecast_hour
                WHERE nx = ? AND ny = ? AND fcst_at >= ? AND fcst_at < ?""",
                rs -> {
                    Map<String, Double> v = new HashMap<>();
                    for (String c : List.of("SKY", "PTY", "TMP", "REH", "WSD", "POP")) {
                        java.math.BigDecimal d = rs.getBigDecimal(c.toLowerCase());
                        v.put(c, d == null ? null : d.doubleValue());
                    }
                    out.put(rs.getObject("fcst_at", OffsetDateTime.class).toInstant(), v);
                }, nx, ny, ts(from), ts(to));
        return out;
    }

    /**
     * Retention: forecasts older than {@code forecastDays} (only the latest issue near the current night is ever read)
     * and call audit rows older than {@code auditDays}. @return rows deleted per table
     */
    public Map<String, Integer> purge(int forecastDays, int auditDays) {
        Map<String, Integer> n = new java.util.LinkedHashMap<>();
        n.put("kma_forecast_hour", jdbc.update("DELETE FROM kma_forecast_hour WHERE fcst_at < now() - make_interval(days => ?)", forecastDays));
        n.put("etl_api_call", jdbc.update("DELETE FROM etl_api_call WHERE called_at < now() - make_interval(days => ?)", auditDays));
        return n;
    }

    public Optional<Instant> latestBaseAt(int nx, int ny) {
        List<OffsetDateTime> l = jdbc.queryForList("SELECT MAX(base_at) FROM kma_forecast_hour WHERE nx = ? AND ny = ?",
                OffsetDateTime.class, nx, ny);
        return l.isEmpty() || l.getFirst() == null ? Optional.empty() : Optional.of(l.getFirst().toInstant());
    }

    // ---------------------------------------------------------------- astronomy

    /** Only the evening times the pack shows and the cross-check compares (DB-PLAN 2.2). */
    public void upsertRiseSet(long regionId, KasiClient.RiseSetDay d) {
        jdbc.update("""
                INSERT INTO kasi_riseset (region_id, locdate, sunset, civile, naute, aste) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT (region_id, locdate) DO UPDATE SET sunset = EXCLUDED.sunset, civile = EXCLUDED.civile,
                    naute = EXCLUDED.naute, aste = EXCLUDED.aste""",
                regionId, Date.valueOf(d.locdate()), time(d.sunset()), time(d.civile()), time(d.naute()), time(d.aste()));
    }

    /** Evening events of {@code locdate} as KST wall times: sunset, civile, naute, aste (null when absent). */
    public Map<String, LocalTime> findKasiEvening(long regionId, LocalDate locdate) {
        Map<String, LocalTime> out = new HashMap<>();
        jdbc.query("SELECT sunset, civile, naute, aste FROM kasi_riseset WHERE region_id = ? AND locdate = ?", rs -> {
            for (String f : List.of("sunset", "civile", "naute", "aste")) {
                Time t = rs.getTime(f);
                out.put(f, t == null ? null : t.toLocalTime());
            }
        }, regionId, Date.valueOf(locdate));
        return out;
    }

    /** @param diffSeconds KASI time minus the Astronomy Engine time */
    public void upsertCrosscheck(long regionId, LocalDate night, String field, int diffSeconds) {
        jdbc.update("""
                INSERT INTO astro_crosscheck (region_id, night_date, field, diff_seconds) VALUES (?, ?, ?, ?)
                ON CONFLICT (region_id, night_date, field) DO UPDATE SET diff_seconds = EXCLUDED.diff_seconds""",
                regionId, Date.valueOf(night), field, diffSeconds);
    }

    public void upsertAstroEvents(List<KasiClient.AstroEvent> events) {
        jdbc.batchUpdate("""
                INSERT INTO kasi_astro_event (locdate, month_feature, seq, astro_time, title, event, remarks)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (locdate, month_feature, seq) DO UPDATE SET astro_time = EXCLUDED.astro_time,
                    title = EXCLUDED.title, event = EXCLUDED.event, remarks = EXCLUDED.remarks""",
                events.stream().map(e -> new Object[]{Date.valueOf(e.locdate()), e.monthFeature(), e.seq(), time(e.astroTime()),
                        e.title(), e.event(), e.remarks()}).toList());
    }

    public void upsertSpecialDays(List<KasiClient.SpecialDay> days) {
        jdbc.batchUpdate("""
                INSERT INTO kasi_special_day (locdate, date_kind, date_name, is_holiday) VALUES (?, ?, ?, ?)
                ON CONFLICT (locdate, date_kind, date_name) DO UPDATE SET is_holiday = EXCLUDED.is_holiday""",
                days.stream().map(d -> new Object[]{Date.valueOf(d.locdate()), d.dateKind(), d.dateName(), d.holiday()}).toList());
    }

    public void upsertLunar(List<KasiClient.LunarDay> days) {
        jdbc.batchUpdate("""
                INSERT INTO kasi_lunar_day (sol_date, lun_year, lun_month, lun_day, lun_leap) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT (sol_date) DO UPDATE SET lun_year = EXCLUDED.lun_year, lun_month = EXCLUDED.lun_month,
                    lun_day = EXCLUDED.lun_day, lun_leap = EXCLUDED.lun_leap""",
                days.stream().map(d -> new Object[]{Date.valueOf(d.solDate()), d.lunYear(), d.lunMonth(), d.lunDay(),
                        d.leap()}).toList());
    }

    // ---------------------------------------------------------------- index + packs

    /** Nightly score only: the pack carries the hourly detail, and the R3 public ranking reads score and grade. */
    public void upsertIndex(long regionId, LocalDate night, Instant baseAt, int score, String grade) {
        jdbc.update("""
                INSERT INTO star_index_nightly (region_id, night_date, base_at, score, grade) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT (region_id, night_date) DO UPDATE SET base_at = EXCLUDED.base_at, score = EXCLUDED.score,
                    grade = EXCLUDED.grade""",
                regionId, Date.valueOf(night), ts(baseAt), score, grade);
    }

    /** @return true when a new row was inserted (false: this exact pack version was already published) */
    public boolean insertPack(String kind, String version, LocalDate night, Instant baseAt, String path, String sha256, int bytes) {
        return jdbc.update("""
                INSERT INTO data_pack (kind, version, night_date, base_at, path, sha256, bytes)
                VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT (kind, version) DO NOTHING""",
                kind, version, night == null ? null : Date.valueOf(night), ts(baseAt), path, sha256, bytes) == 1;
    }

    public int count(String table) {
        if (!table.matches("[a-z_]+")) throw new IllegalArgumentException(table);
        Integer n = jdbc.queryForObject("SELECT COUNT(*) FROM " + table, Integer.class);
        return n == null ? 0 : n;
    }
}
