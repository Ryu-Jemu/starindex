package dev.starindex.etl.kma;

import dev.starindex.datagokr.ApiSource;
import dev.starindex.datagokr.DataGoKrClient;
import dev.starindex.datagokr.DataGoKrException;
import dev.starindex.datagokr.DataGoKrXml;
import org.springframework.stereotype.Component;

import java.time.Instant;
import java.time.LocalDate;
import java.time.LocalTime;
import java.time.format.DateTimeFormatter;
import java.time.temporal.ChronoUnit;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * 단기예보 getVilageFcst for one grid cell and issue. Pages with numOfRows=1000 until totalCount (17/20/23시 issues
 * exceed 1,000 rows since the 5-day extension). XML is requested (the default).
 */
@Component
public class KmaForecastClient {
    public static final String OPERATION = "getVilageFcst";
    static final int PAGE_SIZE = 1000;
    static final int MAX_PAGES = 5;
    private static final DateTimeFormatter DATE = DateTimeFormatter.BASIC_ISO_DATE;
    private static final DateTimeFormatter TIME = DateTimeFormatter.ofPattern("HHmm");
    /** Hourly numeric categories of 단기예보 (SKY/PTY are code numbers, stored numerically). */
    private static final Set<String> NUMERIC = Set.of("TMP", "TMN", "TMX", "UUU", "VVV", "VEC", "WSD", "POP", "REH", "SKY", "PTY", "WAV");

    public record Item(Instant fcstAt, String category, String valueText, Double valueNum, boolean code) {}

    public record Result(KmaBaseTime base, int nx, int ny, int totalCount, List<Item> items) {}

    private final DataGoKrClient client;

    public KmaForecastClient(DataGoKrClient client) {
        this.client = client;
    }

    public Result fetch(int nx, int ny, KmaBaseTime base) {
        List<Item> items = new ArrayList<>();
        int total = 0;
        for (int page = 1; page <= MAX_PAGES; page++) {
            Map<String, String> p = new LinkedHashMap<>();
            p.put("pageNo", Integer.toString(page));
            p.put("numOfRows", Integer.toString(PAGE_SIZE));
            p.put("base_date", base.dateParam());
            p.put("base_time", base.timeParam());
            p.put("nx", Integer.toString(nx));
            p.put("ny", Integer.toString(ny));
            DataGoKrXml.Body body = client.get(ApiSource.KMA_VILAGE, OPERATION, p,
                    nx + "," + ny + "@" + base + " p" + page);
            if (body.noData()) break;
            total = body.totalCount();
            for (Map<String, String> row : body.items()) items.add(toItem(base, row));
            if (body.items().isEmpty() || (long) page * PAGE_SIZE >= total) break;
        }
        if (total > 0 && items.size() != total)
            throw new DataGoKrException(ApiSource.KMA_VILAGE, DataGoKrException.Kind.PARSE, null, 200,
                    "incomplete paging: " + items.size() + " of " + total + " rows for " + nx + "," + ny + "@" + base);
        return new Result(base, nx, ny, total, items);
    }

    static Item toItem(KmaBaseTime base, Map<String, String> row) {
        String category = row.getOrDefault("category", "").strip();
        LocalDate fcstDate = LocalDate.parse(row.get("fcstDate").strip(), DATE);
        LocalTime fcstTime = LocalTime.parse(row.get("fcstTime").strip(), TIME);
        String text = row.getOrDefault("fcstValue", "").strip();
        Instant at = fcstDate.atTime(fcstTime).atZone(KmaBaseTime.KST).toInstant();
        boolean extended = isExtendedPeriod(base, fcstDate);
        if (extended && (category.equals("PCP") || category.equals("SNO") || category.equals("WSD")))
            return new Item(at, category, text, null, true);
        return new Item(at, category, text, numeric(category, text), false);
    }

    /**
     * 5-day extension (활용가이드 2026-09-28): 글피 for the 02–14시 issues, 그글피 for 17–23시 issues are 3-hourly and
     * give PCP/SNO/WSD as qualitative codes instead of amounts.
     */
    static boolean isExtendedPeriod(KmaBaseTime base, LocalDate fcstDate) {
        long offset = ChronoUnit.DAYS.between(base.date(), fcstDate);
        return base.time().getHour() <= 14 ? offset >= 3 : offset >= 4;
    }

    /** Parsed number, or null for missing (|v| >= 900) and text we cannot place on a scale. */
    static Double numeric(String category, String text) {
        if (NUMERIC.contains(category)) {
            try {
                double v = Double.parseDouble(text);
                return Math.abs(v) >= 900 ? null : v;
            } catch (NumberFormatException e) {
                return null;
            }
        }
        if (category.equals("PCP") || category.equals("SNO")) return amount(text);
        return null;
    }

    /** '강수없음'/'적설없음' → 0, '1mm 미만' → 0.5, '6.2mm' → 6.2, '30.0~50.0mm' → 30, '50.0mm 이상' → 50. */
    static Double amount(String text) {
        String t = text.replace(" ", "");
        if (t.equals("강수없음") || t.equals("적설없음") || t.equals("-") || t.isEmpty()) return 0.0;
        if (t.endsWith("미만")) return t.startsWith("0.5") ? 0.25 : 0.5;
        String num = t.replaceAll("^([0-9.]+).*$", "$1");
        try {
            double v = Double.parseDouble(num);
            return Math.abs(v) >= 900 ? null : v;
        } catch (NumberFormatException e) {
            return null;
        }
    }
}
