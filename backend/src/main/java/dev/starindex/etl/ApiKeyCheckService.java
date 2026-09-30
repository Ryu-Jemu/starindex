package dev.starindex.etl;

import dev.starindex.astro.AstroCalculator;
import dev.starindex.datagokr.ApiSource;
import dev.starindex.datagokr.DataGoKrClient;
import dev.starindex.datagokr.DataGoKrException;
import dev.starindex.etl.kma.KmaBaseTime;
import org.springframework.stereotype.Service;

import java.time.LocalDate;
import java.time.ZonedDateTime;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * One minimal request per data.go.kr API (5 calls in total) to tell, right after the key is entered, which APIs are
 * approved and working. Used by {@code apiKeyCheckJob} and {@code scripts/etl.sh check}.
 */
@Service
public class ApiKeyCheckService {
    public record Check(ApiSource source, boolean ok, String detail) {
        public String line() {
            return (ok ? "OK   " : "FAIL ") + source.titleKo() + " (data.go.kr/data/" + source.dataGoKrId() + ") — " + detail
                    + (source.requiredForM0() ? "" : " [선택]");
        }
    }

    private final DataGoKrClient client;
    private final EtlProperties.Etl etl;

    public ApiKeyCheckService(DataGoKrClient client, EtlProperties.Etl etl) {
        this.client = client;
        this.etl = etl;
    }

    public List<Check> checkAll() {
        ZonedDateTime now = ZonedDateTime.now(AstroCalculator.KST);
        LocalDate today = now.toLocalDate();
        String ymd = today.format(DateTimeFormatter.BASIC_ISO_DATE);
        KmaBaseTime base = KmaBaseTime.latestAvailable(now, etl.kmaAvailabilityDelay());
        List<Check> out = new ArrayList<>();
        out.add(check(ApiSource.KMA_VILAGE, "getVilageFcst", params("pageNo", "1", "numOfRows", "10",
                "base_date", base.dateParam(), "base_time", base.timeParam(), "nx", "60", "ny", "127")));
        out.add(check(ApiSource.KASI_RISESET, "getLCRiseSetInfo", params("locdate", ymd, "longitude", "126.9800083",
                "latitude", "37.5635694", "dnYn", "Y")));
        String year = Integer.toString(today.getYear()), month = String.format("%02d", today.getMonthValue());
        out.add(check(ApiSource.KASI_ASTRO_EVENT, "getAstroEventInfo", params("solYear", year, "solMonth", month, "numOfRows", "1")));
        out.add(check(ApiSource.KASI_SPECIAL_DAY, "getRestDeInfo", params("solYear", year, "solMonth", month, "numOfRows", "1")));
        out.add(check(ApiSource.KASI_LUNAR, "getLunCalInfo", params("solYear", year, "solMonth", month,
                "solDay", String.format("%02d", today.getDayOfMonth()))));
        return out;
    }

    private Check check(ApiSource source, String op, Map<String, String> p) {
        try {
            var body = client.get(source, op, p, "keycheck");
            return new Check(source, true, body.noData() ? "응답 정상(해당 기간 자료 없음)" : "응답 정상, " + body.totalCount() + "건");
        } catch (DataGoKrException e) {
            return new Check(source, false, e.guidance());
        }
    }

    private static Map<String, String> params(String... kv) {
        Map<String, String> m = new LinkedHashMap<>();
        for (int i = 0; i < kv.length; i += 2) m.put(kv[i], kv[i + 1]);
        return m;
    }
}
