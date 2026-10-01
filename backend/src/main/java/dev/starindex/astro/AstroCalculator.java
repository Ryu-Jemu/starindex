package dev.starindex.astro;

import io.github.cosinekitty.astronomy.Aberration;
import io.github.cosinekitty.astronomy.Astronomy;
import io.github.cosinekitty.astronomy.Body;
import io.github.cosinekitty.astronomy.Direction;
import io.github.cosinekitty.astronomy.EquatorEpoch;
import io.github.cosinekitty.astronomy.Equatorial;
import io.github.cosinekitty.astronomy.Observer;
import io.github.cosinekitty.astronomy.Refraction;
import io.github.cosinekitty.astronomy.Time;
import io.github.cosinekitty.astronomy.Topocentric;

import java.time.Instant;
import java.time.LocalDate;
import java.time.LocalTime;
import java.time.ZoneId;
import java.time.ZonedDateTime;

/**
 * Astronomy Engine v2.1.19 (same release as the app) for the server side: the night's twilight
 * boundaries, sunrise/sunset and the Moon's altitude/illumination per hour. Pure and thread-safe
 * (Astronomy Engine functions are stateless for these calls).
 */
public final class AstroCalculator {
    public static final ZoneId KST = ZoneId.of("Asia/Seoul");

    /** Sun events of one night: the evening of {@code nightDate} to the next morning. Null = no event in the window. */
    public record NightEvents(LocalDate nightDate, Instant sunset, Instant civilDusk, Instant nauticalDusk,
                              Instant astronomicalDusk, Instant astronomicalDawn, Instant nauticalDawn,
                              Instant civilDawn, Instant sunrise) {}

    public record MoonState(double altitudeDeg, double illuminatedFraction) {}

    private AstroCalculator() {}

    /**
     * Searches from 12:00 KST on {@code nightDate}: descending events that evening, ascending events the next morning.
     * Twilight thresholds use geometric solar altitude (−6/−12/−18°, USNO/KASI definition); rise/set use the standard
     * −0.833° with refraction as in {@code Astronomy_SearchRiseSet}.
     */
    public static NightEvents night(LocalDate nightDate, double lat, double lon, double heightMeters) {
        Observer obs = new Observer(lat, lon, heightMeters);
        Time noon = toTime(ZonedDateTime.of(nightDate, LocalTime.NOON, KST).toInstant());
        Instant sunset = toInstant(Astronomy.searchRiseSet(Body.Sun, obs, Direction.Set, noon, 1.0));
        Instant civilDusk = altitude(obs, Direction.Set, noon, -6);
        Instant nauticalDusk = altitude(obs, Direction.Set, noon, -12);
        Instant astroDusk = altitude(obs, Direction.Set, noon, -18);
        Time evening = astroDusk != null ? toTime(astroDusk) : noon;
        Instant astroDawn = altitude(obs, Direction.Rise, evening, -18);
        Instant nauticalDawn = altitude(obs, Direction.Rise, evening, -12);
        Instant civilDawn = altitude(obs, Direction.Rise, evening, -6);
        Instant sunrise = toInstant(Astronomy.searchRiseSet(Body.Sun, obs, Direction.Rise, evening, 1.0));
        return new NightEvents(nightDate, sunset, civilDusk, nauticalDusk, astroDusk, astroDawn, nauticalDawn, civilDawn, sunrise);
    }

    /** Sample offsets inside an hour (midpoints of six 10-minute bins). */
    private static final int[] HOUR_SAMPLE_MINUTES = {5, 15, 25, 35, 45, 55};

    /**
     * Mean moon factor over the hour [hourStart, hourStart+1h) (ADR-019): an hourly forecast stands for the whole hour,
     * and a moon rising or setting inside it must count for the part of the hour it is up. One value at hourStart
     * would call a window with a 73% moon rising at 20:53 "no moonlight" (2026-10-01, Seoul).
     */
    public static double moonFactorOverHour(Instant hourStart, double lat, double lon) {
        double sum = 0;
        for (int m : HOUR_SAMPLE_MINUTES) {
            MoonState s = moon(hourStart.plusSeconds(60L * m), lat, lon, 0);
            sum += dev.starindex.index.StarIndexCalculator.moonFactor(s.illuminatedFraction(), s.altitudeDeg());
        }
        return sum / HOUR_SAMPLE_MINUTES.length;
    }

    /** Topocentric Moon altitude (refracted, like the sky view) and illuminated fraction at {@code at}. */
    public static MoonState moon(Instant at, double lat, double lon, double heightMeters) {
        Observer obs = new Observer(lat, lon, heightMeters);
        Time t = toTime(at);
        Equatorial eq = Astronomy.equator(Body.Moon, t, obs, EquatorEpoch.OfDate, Aberration.Corrected);
        Topocentric hor = Astronomy.horizon(t, obs, eq.getRa(), eq.getDec(), Refraction.Normal);
        double fraction = Astronomy.illumination(Body.Moon, t).getPhaseFraction();
        return new MoonState(hor.getAltitude(), fraction);
    }

    private static Instant altitude(Observer obs, Direction dir, Time start, double altitudeDeg) {
        return toInstant(Astronomy.searchAltitude(Body.Sun, obs, dir, start, 1.0, altitudeDeg));
    }

    static Time toTime(Instant i) { return Time.fromMillisecondsSince1970(i.toEpochMilli()); }

    static Instant toInstant(Time t) { return t == null ? null : Instant.ofEpochMilli(t.toMillisecondsSince1970()); }
}
