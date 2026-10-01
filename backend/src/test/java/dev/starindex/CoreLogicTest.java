package dev.starindex;

import dev.starindex.astro.AstroCalculator;
import dev.starindex.geo.KmaGrid;
import dev.starindex.index.StarIndexCalculator;
import dev.starindex.index.StarIndexCalculator.HourInput;
import dev.starindex.pack.PackWriter;
import org.junit.jupiter.api.Test;

import java.io.ByteArrayInputStream;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.time.Instant;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.zip.GZIPInputStream;

import static org.junit.jupiter.api.Assertions.*;

/** Pure logic, no Spring context: grid, astronomy, index, pack. */
class CoreLogicTest {

    static Instant kst(String iso) { return LocalDateTime.parse(iso).atZone(AstroCalculator.KST).toInstant(); }

    static void assertNear(Instant expected, Instant actual, Duration tol, String what) {
        assertNotNull(actual, what + " is null");
        long diff = Math.abs(Duration.between(expected, actual).toSeconds());
        assertTrue(diff <= tol.toSeconds(), what + ": expected " + expected + " got " + actual + " (Δ " + diff + " s)");
    }

    @Test
    void theNightTurnsAtSixKst() {   // ADR-018: from the morning on, "tonight" is the coming night
        var kst = AstroCalculator.KST;
        assertEquals(LocalDate.of(2026, 10, 12), dev.starindex.index.IndexService.nightDateOf(java.time.ZonedDateTime.of(2026, 10, 13, 5, 59, 59, 0, kst)));
        assertEquals(LocalDate.of(2026, 10, 13), dev.starindex.index.IndexService.nightDateOf(java.time.ZonedDateTime.of(2026, 10, 13, 6, 0, 0, 0, kst)));
        assertEquals(LocalDate.of(2026, 10, 13), dev.starindex.index.IndexService.nightDateOf(java.time.ZonedDateTime.of(2026, 10, 13, 23, 0, 0, 0, kst)));
        assertEquals(LocalDate.of(2026, 12, 31), dev.starindex.index.IndexService.nightDateOf(
                java.time.ZonedDateTime.of(2026, 12, 31, 20, 0, 0, 0, java.time.ZoneOffset.UTC)), "05:00 KST on Jan 1 → New Year's Eve");
    }

    @Test
    void kmaGridMatchesPublishedSeoulAndRejectsOutside() {
        assertEquals(new KmaGrid.Cell(60, 127), KmaGrid.toGrid(37.5665, 126.9780).orElseThrow());
        assertTrue(KmaGrid.toGrid(0, 0).isEmpty());
        assertTrue(KmaGrid.toGrid(Double.NaN, 127).isEmpty());
        assertTrue(KmaGrid.toGrid(90, 127).isEmpty());
    }

    /**
     * Reference: USNO Astronomical Applications API, Seoul 37.5665N 126.978E, tz +9 (fetched 2026-09-30):
     * 9/29 Set 18:19, End Civil Twilight 18:45; 9/30 Begin Civil Twilight 06:00, Rise 06:26. Minutes are rounded → ±2 min.
     */
    @Test
    void nightEventsMatchUsnoForSeoul() {
        var n = AstroCalculator.night(LocalDate.of(2026, 9, 29), 37.5665, 126.978, 38);
        Duration tol = Duration.ofMinutes(2);
        assertNear(kst("2026-09-29T18:19"), n.sunset(), tol, "sunset");
        assertNear(kst("2026-09-29T18:45"), n.civilDusk(), tol, "civil dusk");
        assertNear(kst("2026-09-30T06:00"), n.civilDawn(), tol, "civil dawn");
        assertNear(kst("2026-09-30T06:26"), n.sunrise(), tol, "sunrise");
        // Ordering of the whole night.
        List<Instant> seq = List.of(n.sunset(), n.civilDusk(), n.nauticalDusk(), n.astronomicalDusk(),
                n.astronomicalDawn(), n.nauticalDawn(), n.civilDawn(), n.sunrise());
        for (int i = 1; i < seq.size(); i++) assertTrue(seq.get(i - 1).isBefore(seq.get(i)), "order at " + i);
        // Each twilight band at 37.5°N in late September is ~25–35 min.
        long nautical = Duration.between(n.civilDusk(), n.nauticalDusk()).toMinutes();
        assertTrue(nautical >= 25 && nautical <= 35, "nautical band " + nautical);
    }

    /** USNO: Moon rises 19:25 on 9/29 in Seoul, waning gibbous 93%. */
    @Test
    void moonBelowHorizonBeforeRiseAndUpAfter() {
        var before = AstroCalculator.moon(kst("2026-09-29T18:30"), 37.5665, 126.978, 38);
        var after = AstroCalculator.moon(kst("2026-09-29T22:00"), 37.5665, 126.978, 38);
        assertTrue(before.altitudeDeg() < 0, "before rise " + before.altitudeDeg());
        assertTrue(after.altitudeDeg() > 10, "after rise " + after.altitudeDeg());
        assertTrue(after.illuminatedFraction() > 0.85 && after.illuminatedFraction() < 0.97, "illum " + after.illuminatedFraction());
    }

    @Test
    void indexFactorsFollowPlanCoefficients() {
        assertEquals(1.0, StarIndexCalculator.cloudFactor(1));
        assertEquals(0.5, StarIndexCalculator.cloudFactor(3));
        assertEquals(0.15, StarIndexCalculator.cloudFactor(4));
        assertThrows(IllegalArgumentException.class, () -> StarIndexCalculator.cloudFactor(2));
        assertEquals(1.0, StarIndexCalculator.moonFactor(1.0, -10), 1e-12);        // below horizon
        assertEquals(0.3, StarIndexCalculator.moonFactor(1.0, 90), 1e-12);         // full moon at zenith
        assertEquals(1 - 0.7 * 0.5 * Math.sqrt(0.5), StarIndexCalculator.moonFactor(0.5, 30), 1e-12);
    }

    @Test
    void nightPicksBestTwoHourWindowAndExplainsIt() {
        Instant t0 = kst("2026-10-12T20:00");
        List<HourInput> hours = new ArrayList<>();
        int[] sky = {4, 3, 1, 1, 3, 4};
        for (int i = 0; i < sky.length; i++) hours.add(new HourInput(t0.plusSeconds(3600L * i), sky[i], 0, 1.0, 1.0));
        var night = StarIndexCalculator.night(hours);
        assertNotNull(night);
        assertEquals(100, night.score());
        assertEquals(StarIndexCalculator.Grade.EXCELLENT, night.grade());
        assertEquals(t0.plusSeconds(7200), night.bestFrom());
        assertEquals(t0.plusSeconds(4 * 3600), night.bestTo());
        assertEquals(0.0, night.contributions().values().stream().mapToDouble(Double::doubleValue).sum(), 1e-9);
        assertTrue(night.reasons().contains("CLOUD_CLEAR") && night.reasons().contains("MOON_NONE"));
    }

    @Test
    void precipitationAndPartialFactorsProduceContributions() {
        Instant t0 = kst("2026-10-12T21:00");
        var rainy = StarIndexCalculator.night(List.of(
                new HourInput(t0, 4, 1, 1, 1), new HourInput(t0.plusSeconds(3600), 4, 1, 1, 1)));
        assertEquals(0, rainy.score());
        assertEquals(1.0, rainy.contributions().get("precip"));
        assertTrue(rainy.reasons().contains("PRECIP"));

        var mixed = StarIndexCalculator.night(List.of(
                new HourInput(t0, 3, 0, StarIndexCalculator.moonFactor(0.9, 40), 0.8),
                new HourInput(t0.plusSeconds(3600), 3, 0, StarIndexCalculator.moonFactor(0.9, 45), 0.8)));
        double sum = mixed.contributions().values().stream().mapToDouble(Double::doubleValue).sum();
        assertEquals(1.0, sum, 0.01);
        assertTrue(mixed.contributions().get("cloud") > mixed.contributions().get("light"));
        assertNull(StarIndexCalculator.night(List.of()));
    }

    @Test
    void theMoonCountsForThePartOfTheHourItIsUp() {
        // 2026-10-01 Seoul: a 73% moon rises about 20:53. Evaluated only at 20:00 and 21:00 (altitude ≈ +0.6°) the
        // clear 20–22 window looked moonless; averaged over each hour it is "some moonlight" (ADR-019).
        double lat = 37.5665, lon = 126.978;
        Instant h20 = kst("2026-10-01T20:00"), h21 = kst("2026-10-01T21:00");
        double f20 = AstroCalculator.moonFactorOverHour(h20, lat, lon), f21 = AstroCalculator.moonFactorOverHour(h21, lat, lon);
        assertTrue(f20 > 0.99, "moon below the horizon for most of 20:00–21:00: " + f20);
        assertTrue(f21 < 0.9, "moon up for the whole of 21:00–22:00: " + f21);
        var night = StarIndexCalculator.night(List.of(new HourInput(h20, 1, 0, f20, 1), new HourInput(h21, 1, 0, f21, 1)));
        assertTrue(night.reasons().contains("MOON_SOME"), night.reasons().toString());
        assertTrue(night.score() >= 90 && night.score() <= 95, "clear sky, rising moon: " + night.score());
        assertTrue(night.contributions().get("moon") == 1.0, night.contributions().toString());
    }

    @Test
    void darkHoursAreWholeHoursInsideAstronomicalNight() {
        // ADR-019: [h, h+1h) must lie between dusk and dawn. 10/1 Seoul: dusk 19:43, dawn 05:01 → 20:00 … 04:00;
        // the 05:00 hour is 59 minutes of morning twilight.
        double lat = 37.5665, lon = 126.978;
        var oct1 = AstroCalculator.night(LocalDate.of(2026, 10, 1), lat, lon, 0);
        var hours = dev.starindex.index.IndexService.darkHours(oct1.astronomicalDusk(), oct1.astronomicalDawn());
        assertEquals(kst("2026-10-01T20:00"), hours.getFirst());
        assertEquals(kst("2026-10-02T04:00"), hours.getLast());
        assertEquals(9, hours.size());
        // Dawn 06:09 (12/20): the last hour is 05:00, so no window crosses the 06:00 night boundary (ADR-018).
        var dec20 = AstroCalculator.night(LocalDate.of(2026, 12, 20), lat, lon, 0);
        assertEquals(kst("2026-12-21T05:00"), dev.starindex.index.IndexService.darkHours(dec20.astronomicalDusk(), dec20.astronomicalDawn()).getLast());
        // Ends exactly on the hour count; no night, no hours.
        assertEquals(List.of(kst("2026-10-12T20:00"), kst("2026-10-12T21:00")),
                dev.starindex.index.IndexService.darkHours(kst("2026-10-12T20:00"), kst("2026-10-12T22:00")));
        assertTrue(dev.starindex.index.IndexService.darkHours(null, kst("2026-10-13T05:00")).isEmpty());
    }

    @Test
    void aMoonSettingBeforeDawnDoesNotPullTheWindowIntoTwilight() {
        // 10/22 Seoul, clear: an 80% moon sets 03:19 and astronomical dawn is 05:20. Counting the 05:00 hour, mostly
        // twilight, as moonless dark sky gave 04:00–06:00 at 100; whole dark hours give 03:00–05:00.
        double lat = 37.5665, lon = 126.978;
        var n = AstroCalculator.night(LocalDate.of(2026, 10, 22), lat, lon, 0);
        var dark = new ArrayList<HourInput>();
        for (Instant h : dev.starindex.index.IndexService.darkHours(n.astronomicalDusk(), n.astronomicalDawn()))
            dark.add(new HourInput(h, 1, 0, AstroCalculator.moonFactorOverHour(h, lat, lon), 1));
        var night = StarIndexCalculator.night(dark);
        assertEquals(kst("2026-10-23T03:00"), night.bestFrom());
        assertEquals(kst("2026-10-23T05:00"), night.bestTo());
        assertFalse(night.bestTo().isAfter(n.astronomicalDawn()));
        assertEquals(99, night.score());
    }

    @Test
    void theBatchCliExits75OnlyWhenDataGoKrWasUnreachable() {   // .github/workflows/etl-attempt.yml retries on 75
        assertEquals(0, StarIndexApplication.exitCode(0, false));
        assertEquals(5, StarIndexApplication.exitCode(5, false), "FAILED");
        assertEquals(75, StarIndexApplication.exitCode(5, true));
        assertEquals(0, StarIndexApplication.exitCode(0, true), "a completed run is never reported as unreachable");
    }

    @Test
    void theWindowMeanIsRoundedOnce() {
        Instant t0 = kst("2026-10-12T20:00");
        // Hourly 100 and 94.81: the mean 97.405 rounds to 97 (rounding each hour first gave (100+95)/2 = 97.5 → 98).
        var night = StarIndexCalculator.night(List.of(new HourInput(t0, 1, 0, 1.0, 1), new HourInput(t0.plusSeconds(3600), 1, 0, 0.9481, 1)));
        assertEquals(97, night.score());
        assertEquals(95, night.hours().get(1).score(), "hourly scores are still rounded for display");
    }

    @Test
    void aMissingForecastHourBreaksTheWindow() {
        Instant t0 = kst("2026-10-12T20:00");
        // 21:00 has no forecast: 20:00 and 22:00 are not one window; the best pair is 22:00–24:00.
        var night = StarIndexCalculator.night(List.of(
                new HourInput(t0, 1, 0, 1, 1),
                new HourInput(t0.plusSeconds(2 * 3600), 1, 0, 1, 1),
                new HourInput(t0.plusSeconds(3 * 3600), 3, 0, 1, 1)));
        assertEquals(t0.plusSeconds(2 * 3600), night.bestFrom());
        assertEquals(t0.plusSeconds(4 * 3600), night.bestTo());
        assertEquals(75, night.score());
        // Only isolated hours: the best single hour stands alone.
        var lone = StarIndexCalculator.night(List.of(new HourInput(t0, 3, 0, 1, 1), new HourInput(t0.plusSeconds(2 * 3600), 1, 0, 1, 1)));
        assertEquals(100, lone.score());
        assertEquals(t0.plusSeconds(2 * 3600), lone.bestFrom());
        assertEquals(t0.plusSeconds(3 * 3600), lone.bestTo());
    }

    @Test
    void packShaIsOverCompressedBytesAndRoundTrips() throws Exception {
        byte[] json = "{\"schema\":2,\"regions\":[]}".getBytes(StandardCharsets.UTF_8);
        var p = PackWriter.gzip(json);
        assertEquals(PackWriter.sha256(p.gzipBytes()), p.sha256());
        assertNotEquals(PackWriter.sha256(json), p.sha256());
        try (var in = new GZIPInputStream(new ByteArrayInputStream(p.gzipBytes()))) {
            assertArrayEquals(json, in.readAllBytes());
        }
        assertEquals(json.length, p.rawBytes());
    }
}
