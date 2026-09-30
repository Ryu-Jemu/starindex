package dev.starindex;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.jdbc.core.JdbcTemplate;

import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;
import java.util.TreeSet;

import static org.junit.jupiter.api.Assertions.*;

/**
 * DB-PLAN 2.2 / ADR-014 "store only what the service needs": the application tables and their columns are exactly
 * the kept set. A new table or column must be added here on purpose, with its retention rule in DB-PLAN 2.2.
 */
class SchemaGuardTest extends IntegrationTestBase {
    @Autowired JdbcTemplate jdbc;

    static final Map<String, List<String>> KEPT = new TreeMap<>(Map.ofEntries(
            Map.entry("region", List.of("id", "kind", "sido", "sigungu", "name_ko", "lat", "lon", "kma_nx", "kma_ny", "active")),
            Map.entry("kma_forecast_hour", List.of("nx", "ny", "fcst_at", "base_at", "sky", "pty", "tmp", "reh", "wsd", "pop")),
            Map.entry("kasi_riseset", List.of("region_id", "locdate", "sunset", "civile", "naute", "aste")),
            Map.entry("astro_crosscheck", List.of("region_id", "night_date", "field", "diff_seconds")),
            Map.entry("kasi_astro_event", List.of("locdate", "month_feature", "seq", "astro_time", "title", "event", "remarks")),
            Map.entry("kasi_special_day", List.of("locdate", "date_kind", "date_name", "is_holiday")),
            Map.entry("kasi_lunar_day", List.of("sol_date", "lun_year", "lun_month", "lun_day", "lun_leap")),
            Map.entry("star_index_nightly", List.of("region_id", "night_date", "base_at", "score", "grade")),
            Map.entry("data_pack", List.of("id", "kind", "version", "night_date", "base_at", "path", "sha256", "bytes",
                    "published_at", "pinned")),
            Map.entry("etl_api_call", List.of("id", "source", "operation", "request_key", "http_status", "result_code",
                    "result_msg", "duration_ms", "outcome", "called_at"))));

    static final Set<String> DROPPED = Set.of("kma_forecast", "kma_forecast_issue", "astro_night", "star_index_hourly");

    Set<String> appTables() {
        return new TreeSet<>(jdbc.queryForList("""
                SELECT table_name FROM information_schema.tables
                WHERE table_schema = current_schema() AND table_type = 'BASE TABLE'
                  AND table_name NOT LIKE 'batch\\_%' AND table_name <> 'flyway_schema_history'""", String.class));
    }

    @Test
    void applicationTablesAreExactlyTheKeptOnes() {
        assertEquals(KEPT.keySet(), appTables());
        for (String t : DROPPED) assertFalse(appTables().contains(t), t);
    }

    @Test
    void everyTableHasExactlyTheKeptColumns() {
        for (var e : KEPT.entrySet()) {
            var actual = new LinkedHashSet<>(jdbc.queryForList("""
                    SELECT column_name FROM information_schema.columns
                    WHERE table_schema = current_schema() AND table_name = ? ORDER BY ordinal_position""", String.class, e.getKey()));
            assertEquals(new TreeSet<>(e.getValue()), new TreeSet<>(actual), e.getKey());
        }
    }

    @Test
    void failureReasonsAreShortAndPacksCanBePinned() {
        assertEquals(80, jdbc.queryForObject("""
                SELECT character_maximum_length FROM information_schema.columns
                WHERE table_schema = current_schema() AND table_name = 'etl_api_call' AND column_name = 'result_msg'""", Integer.class));
        assertEquals("false", jdbc.queryForObject("""
                SELECT column_default FROM information_schema.columns
                WHERE table_schema = current_schema() AND table_name = 'data_pack' AND column_name = 'pinned'""", String.class));
    }
}
