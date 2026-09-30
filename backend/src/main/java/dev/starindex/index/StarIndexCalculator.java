package dev.starindex.index;

import java.time.Instant;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Star index v1 (PLAN 3.4, coefficients provisional until T13/G12):
 * <ul>
 *   <li>f_cloud: SKY 1/3/4 → 1.0/0.5/0.15</li>
 *   <li>f_precip: PTY &gt; 0 → 0, else 1</li>
 *   <li>f_moon = 1 − 0.7·k·√max(0, sin h_moon), k = illuminated fraction, h = altitude</li>
 *   <li>f_light: light-pollution factor (1 until VIIRS is loaded in R3)</li>
 * </ul>
 * Hourly score S = 100·Π f. The night's index is the best mean over two consecutive dark hours.
 * Contributions: precipitation → "관측 불가"; all factors 1 → zeros; otherwise ln f_i / Σ ln f_j over the best window.
 */
public final class StarIndexCalculator {

    public record HourInput(Instant hour, int sky, int pty, double moonIlluminated, double moonAltitudeDeg, double lightFactor) {}

    public record HourScore(Instant hour, int sky, int pty, double fCloud, double fPrecip, double fMoon, double fLight, int score) {}

    public enum Grade { POOR, FAIR, GOOD, EXCELLENT }

    public record NightScore(int score, Grade grade, Instant bestFrom, Instant bestTo,
                             Map<String, Double> contributions, List<String> reasons, List<HourScore> hours) {}

    private StarIndexCalculator() {}

    public static double cloudFactor(int sky) {
        return switch (sky) {
            case 1 -> 1.0;
            case 3 -> 0.5;
            case 4 -> 0.15;
            default -> throw new IllegalArgumentException("SKY code must be 1, 3 or 4: " + sky);
        };
    }

    public static double moonFactor(double illuminated, double altitudeDeg) {
        double k = Math.min(1, Math.max(0, illuminated));
        double s = Math.max(0, Math.sin(Math.toRadians(altitudeDeg)));
        return 1 - 0.7 * k * Math.sqrt(s);
    }

    public static HourScore hour(HourInput in) {
        double fc = cloudFactor(in.sky());
        double fp = in.pty() > 0 ? 0 : 1;
        double fm = moonFactor(in.moonIlluminated(), in.moonAltitudeDeg());
        double fl = Math.min(1, Math.max(0, in.lightFactor()));
        int score = (int) Math.round(100 * fc * fp * fm * fl);
        return new HourScore(in.hour(), in.sky(), in.pty(), fc, fp, fm, fl, score);
    }

    /**
     * @param darkHours hourly inputs inside astronomical night, consecutive and in time order
     * @return null when there is no dark hour with a forecast
     */
    public static NightScore night(List<HourInput> darkHours) {
        if (darkHours.isEmpty()) return null;
        List<HourScore> hours = darkHours.stream().map(StarIndexCalculator::hour).toList();
        int bestStart = 0, width = Math.min(2, hours.size());
        double best = -1;
        for (int i = 0; i + width <= hours.size(); i++) {
            double mean = 0;
            for (int j = i; j < i + width; j++) mean += hours.get(j).score();
            mean /= width;
            if (mean > best) { best = mean; bestStart = i; }
        }
        List<HourScore> window = hours.subList(bestStart, bestStart + width);
        int score = (int) Math.round(best);
        Instant from = window.getFirst().hour();
        Instant to = window.getLast().hour().plusSeconds(3600);
        return new NightScore(score, grade(score), from, to, contributions(window), reasons(window), hours);
    }

    public static Grade grade(int score) {
        if (score >= 80) return Grade.EXCELLENT;
        if (score >= 60) return Grade.GOOD;
        if (score >= 40) return Grade.FAIR;
        return Grade.POOR;
    }

    static Map<String, Double> contributions(List<HourScore> window) {
        Map<String, Double> c = new LinkedHashMap<>();
        double fc = mean(window, HourScore::fCloud), fp = mean(window, HourScore::fPrecip);
        double fm = mean(window, HourScore::fMoon), fl = mean(window, HourScore::fLight);
        if (window.stream().anyMatch(h -> h.pty() > 0)) {
            c.put("cloud", 0.0); c.put("precip", 1.0); c.put("moon", 0.0); c.put("light", 0.0);
            return c;
        }
        double lc = Math.log(fc), lp = Math.log(fp), lm = Math.log(fm), ll = Math.log(fl);
        double total = lc + lp + lm + ll;
        if (total == 0) {
            c.put("cloud", 0.0); c.put("precip", 0.0); c.put("moon", 0.0); c.put("light", 0.0);
            return c;
        }
        c.put("cloud", round3(lc / total)); c.put("precip", round3(lp / total));
        c.put("moon", round3(lm / total)); c.put("light", round3(ll / total));
        return c;
    }

    static List<String> reasons(List<HourScore> window) {
        List<String> r = new ArrayList<>();
        if (window.stream().anyMatch(h -> h.pty() > 0)) r.add("PRECIP");
        int worstSky = window.stream().mapToInt(HourScore::sky).max().orElse(1);
        r.add(switch (worstSky) { case 1 -> "CLOUD_CLEAR"; case 3 -> "CLOUD_MOSTLY"; default -> "CLOUD_OVERCAST"; });
        double fm = mean(window, HourScore::fMoon);
        r.add(fm >= 0.95 ? "MOON_NONE" : (fm >= 0.7 ? "MOON_SOME" : "MOON_BRIGHT"));
        return r;
    }

    private static double mean(List<HourScore> hs, java.util.function.ToDoubleFunction<HourScore> f) {
        return hs.stream().mapToDouble(f).average().orElse(1);
    }

    private static double round3(double v) { return Math.round(v * 1000) / 1000.0; }
}
