package dev.starindex.etl.kasi;

import dev.starindex.datagokr.ApiSource;
import dev.starindex.datagokr.DataGoKrClient;
import dev.starindex.datagokr.DataGoKrException;
import dev.starindex.datagokr.DataGoKrXml;
import org.springframework.stereotype.Component;

import java.time.LocalDate;
import java.time.LocalTime;
import java.time.YearMonth;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Optional;
import java.util.regex.Pattern;

/**
 * 한국천문연구원 APIs (B090041, XML). Field formats verified against the 활용가이드 and live fixtures: rise/set times are
 * {@code HHmm} padded with spaces (suntransit {@code HHmmss}); astroTime is {@code H:mm}; 24절기 kst is {@code HHmm }.
 */
@Component
public class KasiClient {
    private static final org.slf4j.Logger log = org.slf4j.LoggerFactory.getLogger(KasiClient.class);
    private static final DateTimeFormatter DATE = DateTimeFormatter.BASIC_ISO_DATE;
    private static final Pattern CLOCK = Pattern.compile("^(\\d{1,2}):(\\d{2})$");

    public record RiseSetDay(LocalDate locdate, String location, double latitude, double longitude,
                             LocalTime sunrise, LocalTime suntransit, LocalTime sunset,
                             LocalTime moonrise, LocalTime moontransit, LocalTime moonset,
                             LocalTime civilm, LocalTime civile, LocalTime nautm, LocalTime naute,
                             LocalTime astm, LocalTime aste) {}

    public record AstroEvent(LocalDate locdate, boolean monthFeature, int seq, LocalTime astroTime, String title,
                             String event, String remarks) {}

    public record SpecialDay(LocalDate locdate, String dateKind, String dateName, boolean holiday, LocalTime kst,
                             Integer sunLongitude) {}

    public record LunarDay(LocalDate solDate, int lunYear, int lunMonth, int lunDay, boolean leap, String iljin) {}

    private final DataGoKrClient client;

    public KasiClient(DataGoKrClient client) {
        this.client = client;
    }

    /**
     * getLCRiseSetInfo with decimal coordinates (dnYn=Y). KASI answers with its nearest pre-computed location; a
     * dnYn/format mismatch silently returns a far-away edge location, so anything farther than 1° is rejected.
     */
    public Optional<RiseSetDay> riseSet(double lat, double lon, LocalDate date) {
        Map<String, String> p = new LinkedHashMap<>();
        p.put("locdate", date.format(DATE));
        p.put("longitude", String.format(Locale.ROOT, "%.7f", lon));
        p.put("latitude", String.format(Locale.ROOT, "%.7f", lat));
        p.put("dnYn", "Y");
        DataGoKrXml.Body body = client.get(ApiSource.KASI_RISESET, "getLCRiseSetInfo", p,
                String.format(Locale.ROOT, "%.2f,%.2f@%s", lat, lon, date));
        if (body.items().isEmpty()) return Optional.empty();
        Map<String, String> r = body.items().getFirst();
        Double rLat = returned(r.get("latitudeNum"), r.get("latitude")), rLon = returned(r.get("longitudeNum"), r.get("longitude"));
        if (rLat == null || rLon == null) {
            log.warn("KASI rise/set for {},{} has no usable returned coordinates; location not verified", lat, lon);
            rLat = lat;
            rLon = lon;
        } else if (Math.abs(rLat - lat) > 1 || Math.abs(rLon - lon) > 1) {
            throw new DataGoKrException(ApiSource.KASI_RISESET, DataGoKrException.Kind.PARSE, null, 200,
                    "KASI returned a location " + rLat + "," + rLon + " far from the request (dnYn mismatch?)");
        }
        return Optional.of(new RiseSetDay(parseDate(r.get("locdate"), date), strip(r.get("location")), rLat, rLon,
                time(r.get("sunrise")), time(r.get("suntransit")), time(r.get("sunset")),
                time(r.get("moonrise")), time(r.get("moontransit")), time(r.get("moonset")),
                time(r.get("civilm")), time(r.get("civile")), time(r.get("nautm")), time(r.get("naute")),
                time(r.get("astm")), time(r.get("aste"))));
    }

    /** getAstroEventInfo for one month, paged (months often have more than 10 events). */
    public List<AstroEvent> astroEvents(YearMonth ym) {
        List<AstroEvent> out = new ArrayList<>();
        for (Map<String, String> r : pagedMonth(ApiSource.KASI_ASTRO_EVENT, "getAstroEventInfo", ym, Map.of())) {
            String rawDate = strip(r.get("locdate"));
            boolean feature = rawDate != null && rawDate.length() == 6;
            LocalDate date = feature ? ym.atDay(1) : parseDate(rawDate, null);
            if (date == null) continue;
            String title = strip(r.get("astroTitle")), timeText = strip(r.get("astroTime"));
            // The official sample carries the time in astroTitle; accept either placement.
            if ((timeText == null || timeText.isEmpty()) && title != null && CLOCK.matcher(title).matches()) {
                timeText = title;
                title = null;
            }
            String event = strip(r.get("astroEvent"));
            if (event == null || event.isEmpty()) continue;
            out.add(new AstroEvent(date, feature, intOr(r.get("seq"), out.size() + 1), clock(timeText),
                    emptyToNull(title), event, emptyToNull(strip(r.get("remarks")))));
        }
        return out;
    }

    /** SpcdeInfoService: {@code getRestDeInfo} (공휴일) or {@code get24DivisionsInfo} (24절기). */
    public List<SpecialDay> specialDays(String operation, YearMonth ym) {
        List<SpecialDay> out = new ArrayList<>();
        for (Map<String, String> r : pagedMonth(ApiSource.KASI_SPECIAL_DAY, operation, ym, Map.of())) {
            LocalDate d = parseDate(strip(r.get("locdate")), null);
            if (d == null) continue;
            out.add(new SpecialDay(d, strip(r.get("dateKind")), strip(r.get("dateName")),
                    "Y".equalsIgnoreCase(strip(r.get("isHoliday"))), time(r.get("kst")), intOrNull(r.get("sunLongitude"))));
        }
        return out;
    }

    /** getLunCalInfo for a whole solar month (no solDay → up to 31 items). */
    public List<LunarDay> lunarMonth(YearMonth ym) {
        List<LunarDay> out = new ArrayList<>();
        for (Map<String, String> r : pagedMonth(ApiSource.KASI_LUNAR, "getLunCalInfo", ym, Map.of())) {
            int y = intOr(r.get("solYear"), 0), m = intOr(r.get("solMonth"), 0), d = intOr(r.get("solDay"), 0);
            if (y == 0 || m == 0 || d == 0) continue;
            out.add(new LunarDay(LocalDate.of(y, m, d), intOr(r.get("lunYear"), 0), intOr(r.get("lunMonth"), 0),
                    intOr(r.get("lunDay"), 0), "윤".equals(strip(r.get("lunLeapmonth"))), emptyToNull(strip(r.get("lunIljin")))));
        }
        return out;
    }

    private List<Map<String, String>> pagedMonth(ApiSource source, String op, YearMonth ym, Map<String, String> extra) {
        List<Map<String, String>> rows = new ArrayList<>();
        for (int page = 1; page <= 5; page++) {
            Map<String, String> p = new LinkedHashMap<>();
            p.put("solYear", Integer.toString(ym.getYear()));
            p.put("solMonth", String.format("%02d", ym.getMonthValue()));
            p.put("numOfRows", "100");
            p.put("pageNo", Integer.toString(page));
            p.putAll(extra);
            DataGoKrXml.Body body = client.get(source, op, p, ym + " p" + page);
            rows.addAll(body.items());
            if (body.noData() || body.items().isEmpty() || page * 100 >= body.totalCount()) break;
        }
        return rows;
    }

    /** Trim; 4 digits = HHmm, 6 digits = HHmmss; blank, dashes or anything else = no event (null). */
    public static LocalTime time(String raw) {
        if (raw == null) return null;
        String t = raw.strip();
        if (!t.chars().allMatch(Character::isDigit)) return null;
        try {
            if (t.length() == 4) return normalise(Integer.parseInt(t.substring(0, 2)), Integer.parseInt(t.substring(2, 4)), 0);
            if (t.length() == 6)
                return normalise(Integer.parseInt(t.substring(0, 2)), Integer.parseInt(t.substring(2, 4)), Integer.parseInt(t.substring(4, 6)));
        } catch (RuntimeException e) {
            return null;
        }
        return null;
    }

    static LocalTime clock(String text) {
        if (text == null) return null;
        var m = CLOCK.matcher(text.strip());
        if (!m.matches()) return null;
        return normalise(Integer.parseInt(m.group(1)), Integer.parseInt(m.group(2)), 0);
    }

    private static LocalTime normalise(int h, int m, int s) {
        if (h == 24 && m == 0 && s == 0) return LocalTime.MIDNIGHT;
        if (h > 23 || m > 59 || s > 59) return null;
        return LocalTime.of(h, m, s);
    }

    private static LocalDate parseDate(String s, LocalDate fallback) {
        try {
            return s == null ? fallback : LocalDate.parse(s.strip(), DATE);
        } catch (RuntimeException e) {
            return fallback;
        }
    }

    /**
     * The coordinate KASI answered with: the decimal {@code *Num} field, cross-checked against the degree-minute field
     * ({@code 3733} = 37°33′, {@code 12658} = 126°58′). The guide's own sample copies the latitude into longitudeNum, so
     * when both exist and disagree by more than 0.1° the degree-minute value wins. Null when neither parses.
     */
    public static Double returned(String numField, String ddmmField) {
        Double num = null, ddmm = null;
        try {
            if (numField != null && !numField.isBlank()) num = Double.parseDouble(numField.strip());
        } catch (NumberFormatException ignored) {
            // fall through to the degree-minute field
        }
        try {
            if (ddmmField != null && ddmmField.strip().matches("\\d{4,5}")) {
                int v = Integer.parseInt(ddmmField.strip());
                ddmm = v / 100 + (v % 100) / 60.0;
            }
        } catch (NumberFormatException ignored) {
            // no degree-minute value
        }
        if (num != null && ddmm != null && Math.abs(num - ddmm) > 0.1) return ddmm;
        return num != null ? num : ddmm;
    }

    private static int intOr(String s, int fallback) {
        Integer v = intOrNull(s);
        return v == null ? fallback : v;
    }

    private static Integer intOrNull(String s) {
        try {
            return s == null || s.isBlank() ? null : Integer.parseInt(s.strip());
        } catch (NumberFormatException e) {
            return null;
        }
    }

    private static String strip(String s) { return s == null ? null : s.strip(); }

    private static String emptyToNull(String s) { return s == null || s.isEmpty() ? null : s; }
}
