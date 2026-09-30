package dev.starindex.etl;

import dev.starindex.astro.AstroCalculator;
import dev.starindex.etl.kasi.KasiClient;
import dev.starindex.etl.kma.KmaBaseTime;
import dev.starindex.etl.kma.KmaForecastClient;
import dev.starindex.index.StarIndexCalculator;
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

    public int upsertForecast(KmaForecastClient.Result r) {
        OffsetDateTime base = ts(r.base().at().toInstant());
        List<Object[]> rows = new ArrayList<>(r.items().size());
        for (var i : r.items())
            rows.add(new Object[]{r.nx(), r.ny(), base, ts(i.fcstAt()), i.category(), i.valueText(), i.valueNum(), i.code()});
        jdbc.batchUpdate("""
                INSERT INTO kma_forecast (nx, ny, base_at, fcst_at, category, value_text, value_num, value_is_code)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (nx, ny, base_at, fcst_at, category) DO UPDATE
                SET value_text = EXCLUDED.value_text, value_num = EXCLUDED.value_num,
                    value_is_code = EXCLUDED.value_is_code, ingested_at = now()""", rows);
        jdbc.update("""
                INSERT INTO kma_forecast_issue (nx, ny, base_at, row_count, total_count) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT (nx, ny, base_at) DO UPDATE
                SET row_count = EXCLUDED.row_count, total_count = EXCLUDED.total_count, fetched_at = now()""",
                r.nx(), r.ny(), base, r.items().size(), r.totalCount());
        return rows.size();
    }

    public int countIssueCells(KmaBaseTime base) {
        Integer n = jdbc.queryForObject("SELECT COUNT(*) FROM kma_forecast_issue WHERE base_at = ?", Integer.class,
                ts(base.at().toInstant()));
        return n == null ? 0 : n;
    }

    /** Latest-issue value per (hour, category) in [from, to) for one grid cell. */
    public Map<Instant, Map<String, Double>> latestForecast(int nx, int ny, Instant from, Instant to, List<String> categories) {
        Map<Instant, Map<String, Double>> out = new HashMap<>();
        String in = String.join(",", categories.stream().map(c -> "'" + c.replaceAll("[^A-Z0-9]", "") + "'").toList());
        jdbc.query("""
                SELECT DISTINCT ON (fcst_at, category) fcst_at, category, value_num
                FROM kma_forecast
                WHERE nx = ? AND ny = ? AND fcst_at >= ? AND fcst_at < ? AND category IN (%s)
                ORDER BY fcst_at, category, (value_num IS NULL), base_at DESC""".formatted(in),
                rs -> {
                    Instant at = rs.getObject("fcst_at", OffsetDateTime.class).toInstant();
                    double v = rs.getDouble("value_num");
                    Double value = rs.wasNull() ? null : v;
                    out.computeIfAbsent(at, k -> new HashMap<>()).put(rs.getString("category"), value);
                }, nx, ny, ts(from), ts(to));
        return out;
    }

    /**
     * Retention: forecasts older than {@code forecastDays} (only the latest issue near the current night is ever read)
     * and call audit rows older than {@code auditDays}. @return rows deleted per table
     */
    public Map<String, Integer> purge(int forecastDays, int auditDays) {
        Map<String, Integer> n = new java.util.LinkedHashMap<>();
        n.put("kma_forecast", jdbc.update("DELETE FROM kma_forecast WHERE base_at < now() - make_interval(days => ?)", forecastDays));
        n.put("kma_forecast_issue", jdbc.update("DELETE FROM kma_forecast_issue WHERE base_at < now() - make_interval(days => ?)", forecastDays));
        n.put("etl_api_call", jdbc.update("DELETE FROM etl_api_call WHERE called_at < now() - make_interval(days => ?)", auditDays));
        n.put("star_index_hourly", jdbc.update("DELETE FROM star_index_hourly WHERE night_date < current_date - ?", auditDays));
        return n;
    }

    public Optional<Instant> latestBaseAt(int nx, int ny) {
        List<OffsetDateTime> l = jdbc.queryForList("SELECT MAX(base_at) FROM kma_forecast_issue WHERE nx = ? AND ny = ?",
                OffsetDateTime.class, nx, ny);
        return l.isEmpty() || l.getFirst() == null ? Optional.empty() : Optional.of(l.getFirst().toInstant());
    }

    // ---------------------------------------------------------------- astronomy

    public void upsertNight(long regionId, AstroCalculator.NightEvents n) {
        jdbc.update("""
                INSERT INTO astro_night (region_id, night_date, sunset, civil_dusk, nautical_dusk, astronomical_dusk,
                                         astronomical_dawn, nautical_dawn, civil_dawn, sunrise)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (region_id, night_date) DO UPDATE SET sunset = EXCLUDED.sunset, civil_dusk = EXCLUDED.civil_dusk,
                    nautical_dusk = EXCLUDED.nautical_dusk, astronomical_dusk = EXCLUDED.astronomical_dusk,
                    astronomical_dawn = EXCLUDED.astronomical_dawn, nautical_dawn = EXCLUDED.nautical_dawn,
                    civil_dawn = EXCLUDED.civil_dawn, sunrise = EXCLUDED.sunrise, computed_at = now()""",
                regionId, Date.valueOf(n.nightDate()), ts(n.sunset()), ts(n.civilDusk()), ts(n.nauticalDusk()),
                ts(n.astronomicalDusk()), ts(n.astronomicalDawn()), ts(n.nauticalDawn()), ts(n.civilDawn()), ts(n.sunrise()));
    }

    public Optional<AstroCalculator.NightEvents> findNight(long regionId, LocalDate nightDate) {
        return jdbc.query("SELECT * FROM astro_night WHERE region_id = ? AND night_date = ?", (rs, i) ->
                new AstroCalculator.NightEvents(nightDate, inst(rs, "sunset"), inst(rs, "civil_dusk"), inst(rs, "nautical_dusk"),
                        inst(rs, "astronomical_dusk"), inst(rs, "astronomical_dawn"), inst(rs, "nautical_dawn"),
                        inst(rs, "civil_dawn"), inst(rs, "sunrise")), regionId, Date.valueOf(nightDate)).stream().findFirst();
    }

    private static Instant inst(java.sql.ResultSet rs, String col) throws java.sql.SQLException {
        OffsetDateTime o = rs.getObject(col, OffsetDateTime.class);
        return o == null ? null : o.toInstant();
    }

    public void upsertRiseSet(long regionId, KasiClient.RiseSetDay d) {
        jdbc.update("""
                INSERT INTO kasi_riseset (region_id, locdate, kasi_location, sunrise, suntransit, sunset, moonrise,
                                          moontransit, moonset, civilm, civile, nautm, naute, astm, aste)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (region_id, locdate) DO UPDATE SET kasi_location = EXCLUDED.kasi_location,
                    sunrise = EXCLUDED.sunrise, suntransit = EXCLUDED.suntransit, sunset = EXCLUDED.sunset,
                    moonrise = EXCLUDED.moonrise, moontransit = EXCLUDED.moontransit, moonset = EXCLUDED.moonset,
                    civilm = EXCLUDED.civilm, civile = EXCLUDED.civile, nautm = EXCLUDED.nautm, naute = EXCLUDED.naute,
                    astm = EXCLUDED.astm, aste = EXCLUDED.aste, fetched_at = now()""",
                regionId, Date.valueOf(d.locdate()), d.location(), time(d.sunrise()), time(d.suntransit()), time(d.sunset()),
                time(d.moonrise()), time(d.moontransit()), time(d.moonset()), time(d.civilm()), time(d.civile()),
                time(d.nautm()), time(d.naute()), time(d.astm()), time(d.aste()));
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

    public void upsertCrosscheck(long regionId, LocalDate night, String field, Instant kasiAt, Instant computedAt) {
        int diff = (int) java.time.Duration.between(computedAt, kasiAt).toSeconds();
        jdbc.update("""
                INSERT INTO astro_crosscheck (region_id, night_date, field, kasi_at, computed_at, diff_seconds)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT (region_id, night_date, field) DO UPDATE SET kasi_at = EXCLUDED.kasi_at,
                    computed_at = EXCLUDED.computed_at, diff_seconds = EXCLUDED.diff_seconds, checked_at = now()""",
                regionId, Date.valueOf(night), field, ts(kasiAt), ts(computedAt), diff);
    }

    public void upsertAstroEvents(List<KasiClient.AstroEvent> events) {
        jdbc.batchUpdate("""
                INSERT INTO kasi_astro_event (locdate, month_feature, seq, astro_time, title, event, remarks)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (locdate, month_feature, seq) DO UPDATE SET astro_time = EXCLUDED.astro_time,
                    title = EXCLUDED.title, event = EXCLUDED.event, remarks = EXCLUDED.remarks, fetched_at = now()""",
                events.stream().map(e -> new Object[]{Date.valueOf(e.locdate()), e.monthFeature(), e.seq(), time(e.astroTime()),
                        e.title(), e.event(), e.remarks()}).toList());
    }

    public void upsertSpecialDays(List<KasiClient.SpecialDay> days) {
        jdbc.batchUpdate("""
                INSERT INTO kasi_special_day (locdate, date_kind, date_name, is_holiday, kst, sun_longitude)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT (locdate, date_kind, date_name) DO UPDATE SET is_holiday = EXCLUDED.is_holiday,
                    kst = EXCLUDED.kst, sun_longitude = EXCLUDED.sun_longitude, fetched_at = now()""",
                days.stream().map(d -> new Object[]{Date.valueOf(d.locdate()), d.dateKind(), d.dateName(), d.holiday(),
                        time(d.kst()), d.sunLongitude()}).toList());
    }

    public void upsertLunar(List<KasiClient.LunarDay> days) {
        jdbc.batchUpdate("""
                INSERT INTO kasi_lunar_day (sol_date, lun_year, lun_month, lun_day, lun_leap, lun_iljin)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT (sol_date) DO UPDATE SET lun_year = EXCLUDED.lun_year, lun_month = EXCLUDED.lun_month,
                    lun_day = EXCLUDED.lun_day, lun_leap = EXCLUDED.lun_leap, lun_iljin = EXCLUDED.lun_iljin, fetched_at = now()""",
                days.stream().map(d -> new Object[]{Date.valueOf(d.solDate()), d.lunYear(), d.lunMonth(), d.lunDay(),
                        d.leap(), d.iljin()}).toList());
    }

    // ---------------------------------------------------------------- index + packs

    public void upsertIndex(long regionId, LocalDate night, Instant baseAt, StarIndexCalculator.NightScore s, String contribJson,
                            String reasonsJson) {
        jdbc.batchUpdate("""
                INSERT INTO star_index_hourly (region_id, night_date, hour_at, base_at, sky, pty, f_cloud, f_precip,
                                               f_moon, f_light, score)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (region_id, hour_at) DO UPDATE SET night_date = EXCLUDED.night_date, base_at = EXCLUDED.base_at,
                    sky = EXCLUDED.sky, pty = EXCLUDED.pty, f_cloud = EXCLUDED.f_cloud, f_precip = EXCLUDED.f_precip,
                    f_moon = EXCLUDED.f_moon, f_light = EXCLUDED.f_light, score = EXCLUDED.score""",
                s.hours().stream().map(h -> new Object[]{regionId, Date.valueOf(night), ts(h.hour()), ts(baseAt), h.sky(), h.pty(),
                        (float) h.fCloud(), (float) h.fPrecip(), (float) h.fMoon(), (float) h.fLight(), h.score()}).toList());
        jdbc.update("""
                INSERT INTO star_index_nightly (region_id, night_date, base_at, score, grade, best_from, best_to, contrib, reasons)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?::jsonb, ?::jsonb)
                ON CONFLICT (region_id, night_date) DO UPDATE SET base_at = EXCLUDED.base_at, score = EXCLUDED.score,
                    grade = EXCLUDED.grade, best_from = EXCLUDED.best_from, best_to = EXCLUDED.best_to,
                    contrib = EXCLUDED.contrib, reasons = EXCLUDED.reasons, computed_at = now()""",
                regionId, Date.valueOf(night), ts(baseAt), s.score(), s.grade().name(), ts(s.bestFrom()), ts(s.bestTo()),
                contribJson, reasonsJson);
    }

    /** @return true when a new row was inserted (false: this exact pack version was already published) */
    public boolean insertPack(String kind, String version, LocalDate night, Instant baseAt, String path, String sha256,
                              int bytes, int rawBytes, int regions) {
        return jdbc.update("""
                INSERT INTO data_pack (kind, version, night_date, base_at, path, sha256, bytes, raw_bytes, region_count)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT (kind, version) DO NOTHING""",
                kind, version, night == null ? null : Date.valueOf(night), ts(baseAt), path, sha256, bytes, rawBytes, regions) == 1;
    }

    public int count(String table) {
        if (!table.matches("[a-z_]+")) throw new IllegalArgumentException(table);
        Integer n = jdbc.queryForObject("SELECT COUNT(*) FROM " + table, Integer.class);
        return n == null ? 0 : n;
    }
}
