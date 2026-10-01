package dev.starindex.etl.kma;

import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

/** DB-PLAN 6.1: only the six stored items, no row for an hour without values, rounding and scale of each item. */
class KmaForecastHoursTest {
    static final Instant H1 = Instant.parse("2026-10-12T12:00:00Z"), H2 = H1.plusSeconds(3600), H3 = H2.plusSeconds(3600);

    static KmaForecastClient.Item item(Instant at, String category, Double value) {
        return new KmaForecastClient.Item(at, category, String.valueOf(value), value, false);
    }

    @Test
    void sixItemsRoundingAndScale() {
        var hours = KmaForecastClient.hours(List.of(
                item(H1, "SKY", 3.0), item(H1, "PTY", 0.0), item(H1, "TMP", 14.25), item(H1, "REH", 55.5),
                item(H1, "WSD", 1.85), item(H1, "POP", 29.6), item(H1, "PCP", 1.0), item(H1, "SNO", 0.0), item(H1, "VEC", 270.0)));
        assertEquals(1, hours.size());
        var h = hours.getFirst();
        assertEquals(H1, h.fcstAt());
        assertEquals((short) 3, h.sky());
        assertEquals((short) 0, h.pty());
        assertEquals(new BigDecimal("14.3"), h.tmp(), "TMP: one decimal, HALF_UP");
        assertEquals((short) 56, h.reh(), "REH: Math.round");
        assertEquals(new BigDecimal("1.9"), h.wsd(), "WSD: one decimal, HALF_UP");
        assertEquals((short) 30, h.pop(), "POP: Math.round");
    }

    @Test
    void hoursWithoutAnyStoredValueMakeNoRowAndRowsAreInTimeOrder() {
        var hours = KmaForecastClient.hours(List.of(
                item(H3, "SKY", 1.0),
                new KmaForecastClient.Item(H2, "WSD", "1", null, true),   // extended-period code
                item(H2, "TMP", null),                                       // missing (-999 parsed to null)
                item(H2, "PCP", 5.0),                                        // not a stored item
                item(H1, "POP", 20.0)));
        assertEquals(List.of(H1, H3), hours.stream().map(KmaForecastClient.Hour::fcstAt).toList());
        assertNull(hours.getFirst().sky());
        assertEquals((short) 20, hours.getFirst().pop());
    }
}
