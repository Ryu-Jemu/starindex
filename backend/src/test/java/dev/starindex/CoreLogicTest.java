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
        for (int i = 0; i < sky.length; i++) hours.add(new HourInput(t0.plusSeconds(3600L * i), sky[i], 0, 0.1, -5, 1.0));
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
                new HourInput(t0, 4, 1, 0, -5, 1), new HourInput(t0.plusSeconds(3600), 4, 1, 0, -5, 1)));
        assertEquals(0, rainy.score());
        assertEquals(1.0, rainy.contributions().get("precip"));
        assertTrue(rainy.reasons().contains("PRECIP"));

        var mixed = StarIndexCalculator.night(List.of(
                new HourInput(t0, 3, 0, 0.9, 40, 0.8), new HourInput(t0.plusSeconds(3600), 3, 0, 0.9, 45, 0.8)));
        double sum = mixed.contributions().values().stream().mapToDouble(Double::doubleValue).sum();
        assertEquals(1.0, sum, 0.01);
        assertTrue(mixed.contributions().get("cloud") > mixed.contributions().get("light"));
        assertNull(StarIndexCalculator.night(List.of()));
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
