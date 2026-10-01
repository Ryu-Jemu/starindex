package dev.starindex.pack;

import org.junit.jupiter.api.Test;

import java.time.OffsetDateTime;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;

class PackTimeFormatTest {
    @Test
    void displayedTimesAreRoundedToTheNearestMinuteLikeKasi() {
        assertEquals("1816", PackPublisher.hhmm(OffsetDateTime.parse("2026-10-01T18:15:55.8+09:00").toInstant()));  // was 1815
        assertEquals("1842", PackPublisher.hhmm(OffsetDateTime.parse("2026-10-01T18:41:30+09:00").toInstant()));    // half up
        assertEquals("1841", PackPublisher.hhmm(OffsetDateTime.parse("2026-10-01T18:41:29.9+09:00").toInstant()));
        assertEquals("0000", PackPublisher.hhmm(OffsetDateTime.parse("2026-10-01T23:59:45+09:00").toInstant()));    // next day
        assertEquals("2000", PackPublisher.hhmm(OffsetDateTime.parse("2026-10-01T20:00:00+09:00").toInstant()));    // whole hours unchanged
        assertNull(PackPublisher.hhmm(null));
    }
}
