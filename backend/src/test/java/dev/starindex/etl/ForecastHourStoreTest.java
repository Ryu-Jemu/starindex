package dev.starindex.etl;

import dev.starindex.IntegrationTestBase;
import dev.starindex.etl.kma.KmaBaseTime;
import dev.starindex.etl.kma.KmaForecastClient;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.jdbc.core.JdbcTemplate;

import java.time.Instant;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

/** DB-PLAN 6.1: merge rules of kma_forecast_hour (newest non-missing value per item). */
class ForecastHourStoreTest extends IntegrationTestBase {
    @Autowired EtlRepository repo;
    @Autowired JdbcTemplate jdbc;

    static final Instant H21 = OffsetDateTime.parse("2026-10-12T21:00:00+09:00").toInstant();

    @BeforeEach
    void clean() { jdbc.execute("TRUNCATE kma_forecast_hour"); }

    static KmaForecastClient.Result issue(String hhmm, Object... categoryValue) {
        List<KmaForecastClient.Item> items = new ArrayList<>();
        for (int i = 0; i < categoryValue.length; i += 2) {
            Double v = (Double) categoryValue[i + 1];
            items.add(new KmaForecastClient.Item(H21, (String) categoryValue[i], String.valueOf(v), v, false));
        }
        return new KmaForecastClient.Result(KmaBaseTime.parse("20261012", hhmm), 60, 127, items.size(), items);
    }

    Map<String, Double> row() { return repo.latestForecast(60, 127, H21, H21.plusSeconds(3600)).get(H21); }

    Instant baseAt() {
        return jdbc.queryForObject("SELECT base_at FROM kma_forecast_hour", OffsetDateTime.class).toInstant();
    }

    @Test
    void newerIssueOverwritesValuesButKeepsOlderWhereItHasNone() {
        repo.upsertForecast(issue("1400", "SKY", 1.0, "TMP", 14.0, "WSD", 1.8));
        repo.upsertForecast(issue("1700", "SKY", 3.0, "TMP", null));     // TMP missing (-999) in the newest issue
        var v = row();
        assertEquals(3.0, v.get("SKY"), "② newest value wins");
        assertEquals(14.0, v.get("TMP"), "① newest missing → keep the older value");
        assertEquals(1.8, v.get("WSD"));
        assertEquals(KmaBaseTime.parse("20261012", "1700").at().toInstant(), baseAt());
    }

    @Test
    void lateOlderIssueOnlyFillsBlanksAndBaseAtIsTheGreatest() {
        repo.upsertForecast(issue("1700", "SKY", 3.0));
        repo.upsertForecast(issue("1400", "SKY", 1.0, "POP", 20.0));     // arrives late (backfill)
        var v = row();
        assertEquals(3.0, v.get("SKY"), "③ an older issue never overwrites a newer value");
        assertEquals(20.0, v.get("POP"), "③ … but fills what the newer one lacked");
        assertEquals(KmaBaseTime.parse("20261012", "1700").at().toInstant(), baseAt(), "④ GREATEST");
    }

    @Test
    void reapplyingTheSameIssueIsIdempotent() {
        var i = issue("1700", "SKY", 4.0, "PTY", 1.0, "REH", 90.0);
        repo.upsertForecast(i);
        var first = row();
        repo.upsertForecast(i);
        assertEquals(first, row(), "⑤");
        assertEquals(1, jdbc.queryForObject("SELECT COUNT(*) FROM kma_forecast_hour", Integer.class));
    }
}
