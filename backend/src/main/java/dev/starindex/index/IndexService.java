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

    /**
     * The night a moment belongs to: the date of the preceding 06:00 KST (ADR-018). From the morning on, "tonight" is
     * the coming night; until 06:00 it is still the night in progress. (Noon before ADR-018.)
     */
    public static LocalDate nightDateOf(ZonedDateTime now) {
        return now.withZoneSameInstant(AstroCalculator.KST).minusHours(6).toLocalDate();
    }

    /**
     * The whole hours [h, h+1h) inside astronomical night (ADR-019): the first starts at or after dusk, the last ends at
     * or before dawn. Until 10-01 the last hour only had to start before dawn, so a window could run up to 59 minutes
     * into morning twilight and count it as moonless dark sky (Seoul 10/22: 04:00–06:00 with dawn at 05:20).
     */
    public static List<Instant> darkHours(Instant astronomicalDusk, Instant astronomicalDawn) {
        List<Instant> hours = new ArrayList<>();
        if (astronomicalDusk == null || astronomicalDawn == null) return hours;
        Instant h = astronomicalDusk.truncatedTo(ChronoUnit.HOURS);   // KST is a whole-hour offset from UTC
        if (h.isBefore(astronomicalDusk)) h = h.plus(1, ChronoUnit.HOURS);
        for (; !h.plus(1, ChronoUnit.HOURS).isAfter(astronomicalDawn); h = h.plus(1, ChronoUnit.HOURS)) hours.add(h);
        return hours;
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
            for (Instant h : darkHours(night.astronomicalDusk(), night.astronomicalDawn())) {
                Map<String, Double> v = series.get(h);
                if (v == null || v.get("SKY") == null || v.get("PTY") == null) continue;
                int sky = (int) Math.round(v.get("SKY")), pty = (int) Math.round(v.get("PTY"));
                if (sky != 1 && sky != 3 && sky != 4) continue;
                double fMoon = AstroCalculator.moonFactorOverHour(h, r.getLat(), r.getLon());
                dark.add(new StarIndexCalculator.HourInput(h, sky, pty, fMoon, lightFactor));
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
