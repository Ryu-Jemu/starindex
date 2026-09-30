package dev.starindex.index;

import dev.starindex.astro.AstroCalculator;
import dev.starindex.etl.AstroService;
import dev.starindex.etl.EtlRepository;
import dev.starindex.region.Region;
import dev.starindex.region.RegionQueryRepository;
import org.springframework.stereotype.Service;

import java.time.Instant;
import java.time.LocalDate;
import java.time.LocalTime;
import java.time.ZonedDateTime;
import java.time.temporal.ChronoUnit;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/**
 * Star index for one night and every active point, from the latest stored forecast per hour (SKY/PTY), the Moon
 * (Astronomy Engine) and the light factor (1.0 until VIIRS, R3). Dark hours = whole hours inside astronomical night.
 */
@Service
public class IndexService {
    public static final List<String> SERIES = List.of("SKY", "PTY", "TMP", "REH", "WSD", "POP");

    /** Per point: the score (null when no dark hour has a forecast) and the hourly series for the pack. */
    public record RegionNight(Region region, AstroCalculator.NightEvents night, StarIndexCalculator.NightScore score,
                              Instant baseAt, Instant seriesStart, Map<Instant, Map<String, Double>> series) {}

    private final RegionQueryRepository regions;
    private final EtlRepository repo;
    private final AstroService astro;

    public IndexService(RegionQueryRepository regions, EtlRepository repo, AstroService astro) {
        this.regions = regions;
        this.repo = repo;
        this.astro = astro;
    }

    /** The night a moment belongs to: the date of the preceding 12:00 KST (SERVICE-PLAN 4.2). */
    public static LocalDate nightDateOf(ZonedDateTime now) {
        return now.withZoneSameInstant(AstroCalculator.KST).minusHours(12).toLocalDate();
    }

    public List<RegionNight> compute(LocalDate nightDate, int seriesSlots, double lightFactor) {
        Instant seriesStart = ZonedDateTime.of(nightDate, LocalTime.NOON, AstroCalculator.KST).toInstant();
        Instant seriesEnd = seriesStart.plus(seriesSlots, ChronoUnit.HOURS);
        List<RegionNight> out = new ArrayList<>();
        for (Region r : regions.findActive()) {
            var night = astro.nightFor(r, nightDate);
            var series = repo.latestForecast(r.getKmaNx(), r.getKmaNy(), seriesStart, seriesEnd);
            Instant baseAt = repo.latestBaseAt(r.getKmaNx(), r.getKmaNy()).orElse(null);
            List<StarIndexCalculator.HourInput> dark = new ArrayList<>();
            if (night.astronomicalDusk() != null && night.astronomicalDawn() != null) {
                Instant h = night.astronomicalDusk().truncatedTo(ChronoUnit.HOURS);
                if (h.isBefore(night.astronomicalDusk())) h = h.plus(1, ChronoUnit.HOURS);
                for (; !h.isAfter(night.astronomicalDawn()); h = h.plus(1, ChronoUnit.HOURS)) {
                    Map<String, Double> v = series.get(h);
                    if (v == null || v.get("SKY") == null || v.get("PTY") == null) continue;
                    int sky = (int) Math.round(v.get("SKY")), pty = (int) Math.round(v.get("PTY"));
                    if (sky != 1 && sky != 3 && sky != 4) continue;
                    var moon = AstroCalculator.moon(h, r.getLat(), r.getLon(), 0);
                    dark.add(new StarIndexCalculator.HourInput(h, sky, pty, moon.illuminatedFraction(), moon.altitudeDeg(), lightFactor));
                }
            }
            var score = StarIndexCalculator.night(dark);
            out.add(new RegionNight(r, night, score, baseAt, seriesStart, series));
        }
        return out;
    }

    /** Stores the nightly score of the points that have one. @return number of scored points */
    public int persist(LocalDate nightDate, List<RegionNight> nights) {
        int n = 0;
        for (RegionNight rn : nights) {
            if (rn.score() == null) continue;
            Instant base = rn.baseAt() != null ? rn.baseAt() : rn.score().bestFrom();
            repo.upsertIndex(rn.region().getId(), nightDate, base, rn.score().score(), rn.score().grade().name());
            n++;
        }
        return n;
    }
}
