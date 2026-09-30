package dev.starindex.etl;

import dev.starindex.astro.AstroCalculator;
import dev.starindex.datagokr.DataGoKrException;
import dev.starindex.etl.kasi.KasiClient;
import dev.starindex.region.Region;
import dev.starindex.region.RegionQueryRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

import java.time.Duration;
import java.time.Instant;
import java.time.LocalDate;
import java.time.LocalTime;
import java.time.YearMonth;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/**
 * Astronomy for the ETL:
 * <ul>
 *   <li>Astronomy Engine nights for every point (no key needed; also the fallback when KASI is missing)</li>
 *   <li>KASI 출몰시각 per point and date, and the KASI-vs-computed cross-check (T16)</li>
 *   <li>KASI monthly data: 천문현상 (required), 특일·음양력 (optional until applied for)</li>
 * </ul>
 */
@Service
public class AstroService {
    private static final Logger log = LoggerFactory.getLogger(AstroService.class);
    /** T16: KASI civil/nautical/astronomical times vs Astronomy Engine; beyond this the pair is reported. */
    public static final Duration CROSSCHECK_WARN = Duration.ofMinutes(2);

    private final RegionQueryRepository regions;
    private final KasiClient kasi;
    private final EtlRepository repo;

    public AstroService(RegionQueryRepository regions, KasiClient kasi, EtlRepository repo) {
        this.regions = regions;
        this.kasi = kasi;
        this.repo = repo;
    }

    /** @return number of (point, night) rows written */
    public int computeNights(LocalDate from, int days) {
        int n = 0;
        for (Region r : regions.findActive())
            for (int d = 0; d < days; d++) {
                repo.upsertNight(r.getId(), AstroCalculator.night(from.plusDays(d), r.getLat(), r.getLon(), 0));
                n++;
            }
        return n;
    }

    public AstroCalculator.NightEvents nightFor(Region r, LocalDate nightDate) {
        return repo.findNight(r.getId(), nightDate).orElseGet(() -> {
            var n = AstroCalculator.night(nightDate, r.getLat(), r.getLon(), 0);
            repo.upsertNight(r.getId(), n);
            return n;
        });
    }

    public record RiseSetReport(int requested, int stored, List<String> failures) {
        public String summary() {
            return "천문연 출몰시각 " + stored + "/" + requested + " 저장" + (failures.isEmpty() ? "" : ", 실패 " + failures);
        }
    }

    public RiseSetReport fetchRiseSet(LocalDate from, int days) {
        int requested = 0, stored = 0;
        List<String> failures = new ArrayList<>();
        for (Region r : regions.findActive())
            for (int d = 0; d < days; d++) {
                LocalDate date = from.plusDays(d);
                requested++;
                try {
                    var day = kasi.riseSet(r.getLat(), r.getLon(), date);
                    if (day.isEmpty()) {
                        failures.add(r.getNameKo() + " " + date + " 자료 없음");
                        continue;
                    }
                    repo.upsertRiseSet(r.getId(), day.get());
                    stored++;
                } catch (DataGoKrException e) {
                    if (e.kind().stopsRun()) throw new EtlStopException(e.guidance(), e);
                    failures.add(r.getNameKo() + " " + date + " " + e.kind());
                }
            }
        return new RiseSetReport(requested, stored, failures);
    }

    public record CrosscheckReport(int pairs, long maxAbsSeconds, List<String> outliers) {
        public String summary() {
            return "교차검증 " + pairs + "쌍, 최대 차 " + maxAbsSeconds + "초" + (outliers.isEmpty() ? "" : ", 2분 초과 " + outliers);
        }
    }

    /** Compares KASI evening times of each date with the Astronomy Engine night of the same date. */
    public CrosscheckReport crosscheck(LocalDate from, int days) {
        int pairs = 0;
        long max = 0;
        List<String> outliers = new ArrayList<>();
        for (Region r : regions.findActive())
            for (int d = 0; d < days; d++) {
                LocalDate date = from.plusDays(d);
                Map<String, LocalTime> k = repo.findKasiEvening(r.getId(), date);
                if (k.isEmpty()) continue;
                var n = nightFor(r, date);
                Map<String, Instant> computed = Map.of("sunset", nz(n.sunset()), "civile", nz(n.civilDusk()),
                        "naute", nz(n.nauticalDusk()), "aste", nz(n.astronomicalDusk()));
                for (var e : computed.entrySet()) {
                    LocalTime kt = k.get(e.getKey());
                    if (kt == null || e.getValue() == Instant.EPOCH) continue;
                    Instant kasiAt = date.atTime(kt).atZone(AstroCalculator.KST).toInstant();
                    repo.upsertCrosscheck(r.getId(), date, e.getKey(), kasiAt, e.getValue());
                    long diff = Math.abs(Duration.between(e.getValue(), kasiAt).toSeconds());
                    pairs++;
                    max = Math.max(max, diff);
                    if (diff > CROSSCHECK_WARN.toSeconds()) outliers.add(r.getNameKo() + " " + date + " " + e.getKey() + " " + diff + "s");
                }
            }
        if (!outliers.isEmpty()) log.warn("KASI vs Astronomy Engine beyond {}: {}", CROSSCHECK_WARN, outliers);
        return new CrosscheckReport(pairs, max, outliers);
    }

    private static Instant nz(Instant i) { return i == null ? Instant.EPOCH : i; }

    public int fetchAstroEvents(YearMonth ym) {
        var events = kasi.astroEvents(ym);
        repo.upsertAstroEvents(events);
        return events.size();
    }

    public int fetchSpecialDays(YearMonth ym) {
        var days = new ArrayList<>(kasi.specialDays("getRestDeInfo", ym));
        days.addAll(kasi.specialDays("get24DivisionsInfo", ym));
        repo.upsertSpecialDays(days);
        return days.size();
    }

    public int fetchLunar(YearMonth ym) {
        var days = kasi.lunarMonth(ym);
        repo.upsertLunar(days);
        return days.size();
    }
}
