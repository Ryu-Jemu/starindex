package dev.starindex.etl.kma;

import dev.starindex.datagokr.ApiSource;
import dev.starindex.datagokr.DataGoKrClient;
import dev.starindex.datagokr.DataGoKrException;
import dev.starindex.datagokr.DataGoKrXml;
import org.springframework.stereotype.Component;

import java.math.BigDecimal;
import java.math.RoundingMode;
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
import java.util.TreeMap;

/**
 * 단기예보 getVilageFcst for one grid cell and issue. Pages with numOfRows=1000 until totalCount (17/20/23시 issues
 * exceed 1,000 rows since the 5-day extension). XML is requested (the default). The API always returns all 12 items;
 * only the six the service reads are kept ({@link #hours}).
 */
@Component
public class KmaForecastClient {
    public static final String OPERATION = "getVilageFcst";
    static final int PAGE_SIZE = 1000;
    static final int MAX_PAGES = 5;
    private static final DateTimeFormatter DATE = DateTimeFormatter.BASIC_ISO_DATE;
    private static final DateTimeFormatter TIME = DateTimeFormatter.ofPattern("HHmm");
    /** The only 단기예보 items the service reads (ADR-014): index SKY/PTY, pack series TMP/REH/WSD/POP. */
    public static final Set<String> STORED = Set.of("SKY", "PTY", "TMP", "REH", "WSD", "POP");

    public record Item(Instant fcstAt, String category, String valueText, Double valueNum, boolean code) {}

    /** One stored row: the six items of one forecast hour (null = missing or not a value). */
    public record Hour(Instant fcstAt, Short sky, Short pty, BigDecimal tmp, Short reh, BigDecimal wsd, Short pop) {
        boolean empty() { return sky == null && pty == null && tmp == null && reh == null && wsd == null && pop == null; }
    }

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

    /** Pivots one issue into hourly rows of the six stored items, in time order; hours with no value are dropped. */
    public static List<Hour> hours(List<Item> items) {
        Map<Instant, Map<String, Double>> byHour = new TreeMap<>();
        for (Item i : items) {
            if (!STORED.contains(i.category()) || i.code() || i.valueNum() == null) continue;
            byHour.computeIfAbsent(i.fcstAt(), k -> new java.util.HashMap<>()).put(i.category(), i.valueNum());
        }
        List<Hour> out = new ArrayList<>(byHour.size());
        for (var e : byHour.entrySet()) {
            Map<String, Double> v = e.getValue();
            Hour h = new Hour(e.getKey(), small(v.get("SKY")), small(v.get("PTY")), tenth(v.get("TMP")),
                    small(v.get("REH")), tenth(v.get("WSD")), small(v.get("POP")));
            if (!h.empty()) out.add(h);
        }
        return out;
    }

    private static Short small(Double d) { return d == null ? null : (short) Math.round(d); }

    private static BigDecimal tenth(Double d) { return d == null ? null : BigDecimal.valueOf(d).setScale(1, RoundingMode.HALF_UP); }

    static Item toItem(KmaBaseTime base, Map<String, String> row) {
        String category = row.getOrDefault("category", "").strip();
        LocalDate fcstDate = LocalDate.parse(row.get("fcstDate").strip(), DATE);
        LocalTime fcstTime = LocalTime.parse(row.get("fcstTime").strip(), TIME);
        String text = row.getOrDefault("fcstValue", "").strip();
        Instant at = fcstDate.atTime(fcstTime).atZone(KmaBaseTime.KST).toInstant();
        boolean extended = isExtendedPeriod(base, fcstDate);
        if (extended && category.equals("WSD"))       // 연장 구간 풍속은 1/2/3 코드값이지 m/s가 아니다
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

    /** Parsed number for the stored items, or null for missing values (|v| >= 900) and every other item. */
    static Double numeric(String category, String text) {
        if (!STORED.contains(category)) return null;
        try {
            double v = Double.parseDouble(text);
            return Math.abs(v) >= 900 ? null : v;
        } catch (NumberFormatException e) {
            return null;
        }
    }
}
