package dev.starindex.etl.kma;

import java.time.Duration;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.time.LocalTime;
import java.time.ZoneId;
import java.time.ZonedDateTime;
import java.time.format.DateTimeFormatter;
import java.util.List;

/**
 * 단기예보(getVilageFcst) issue times: 02, 05, 08, 11, 14, 17, 20, 23 KST. A run is served by the API some
 * minutes after its base time ({@code availabilityDelay}); before that the call returns NO_DATA.
 */
public record KmaBaseTime(LocalDate date, LocalTime time) implements Comparable<KmaBaseTime> {
    public static final ZoneId KST = ZoneId.of("Asia/Seoul");
    public static final List<Integer> HOURS = List.of(2, 5, 8, 11, 14, 17, 20, 23);
    private static final DateTimeFormatter DATE = DateTimeFormatter.BASIC_ISO_DATE;
    private static final DateTimeFormatter TIME = DateTimeFormatter.ofPattern("HHmm");

    public KmaBaseTime {
        if (time.getMinute() != 0 || time.getSecond() != 0 || !HOURS.contains(time.getHour()))
            throw new IllegalArgumentException("not a 단기예보 base time: " + time);
    }

    /** Latest base time whose data is available at {@code now}. */
    public static KmaBaseTime latestAvailable(ZonedDateTime now, Duration availabilityDelay) {
        LocalDateTime t = now.withZoneSameInstant(KST).toLocalDateTime().minus(availabilityDelay);
        for (int i = HOURS.size() - 1; i >= 0; i--) {
            int h = HOURS.get(i);
            if (t.getHour() >= h) return new KmaBaseTime(t.toLocalDate(), LocalTime.of(h, 0));
        }
        return new KmaBaseTime(t.toLocalDate().minusDays(1), LocalTime.of(23, 0));
    }

    public static KmaBaseTime parse(String yyyyMMdd, String hhmm) {
        return new KmaBaseTime(LocalDate.parse(yyyyMMdd, DATE), LocalTime.parse(hhmm, TIME));
    }

    public String dateParam() { return date.format(DATE); }

    public String timeParam() { return time.format(TIME); }

    public ZonedDateTime at() { return ZonedDateTime.of(date, time, KST); }

    @Override
    public int compareTo(KmaBaseTime o) { return at().compareTo(o.at()); }

    @Override
    public String toString() { return dateParam() + " " + timeParam(); }
}
