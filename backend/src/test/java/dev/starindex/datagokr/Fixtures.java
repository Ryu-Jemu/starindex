package dev.starindex.datagokr;

import java.time.LocalDate;
import java.time.format.DateTimeFormatter;
import java.util.List;

/**
 * Response bodies in the shapes verified on 2026-09-30: KMA 활용가이드(260928) XML, the live gateway error bodies
 * (HTTP 403/401), and KASI live fixtures (times "HHmm" + two spaces, suntransit "HHmmss").
 */
public final class Fixtures {
    private Fixtures() {}

    public static final String GATEWAY_30_XML = """
            <?xml version="1.0" encoding="UTF-8"?>
            <OpenAPI_ServiceResponse>
            <cmmMsgHeader>
              <errMsg>SERVICE_KEY_IS_NOT_REGISTERED_ERROR</errMsg>
              <returnAuthMsg>등록되지 않은 서비스키</returnAuthMsg>
              <returnReasonCode>30</returnReasonCode>
            </cmmMsgHeader>
            </OpenAPI_ServiceResponse>""";

    public static final String GATEWAY_30_JSON = """
            {
              "OpenAPI_ServiceResponse": {
                "cmmMsgHeader": {
                  "errMsg": "SERVICE_KEY_IS_NOT_REGISTERED_ERROR",
                  "returnAuthMsg": "등록되지 않은 서비스키",
                  "returnReasonCode": "30"
                }
              }
            }""";

    public static final String GATEWAY_22_XML = """
            <?xml version="1.0" encoding="UTF-8"?>
            <OpenAPI_ServiceResponse><cmmMsgHeader><errMsg>LIMITED_NUMBER_OF_SERVICE_REQUESTS_EXCEEDS_ERROR</errMsg>
            <returnAuthMsg>일일 호출 허용량 초과</returnAuthMsg><returnReasonCode>22</returnReasonCode></cmmMsgHeader>
            </OpenAPI_ServiceResponse>""";

    public static final String GATEWAY_23_XML = """
            <?xml version="1.0" encoding="UTF-8"?>
            <OpenAPI_ServiceResponse><cmmMsgHeader><errMsg>LIMITED_NUMBER_OF_SERVICE_REQUESTS_PER_SECOND_EXCEEDS_ERROR</errMsg>
            <returnAuthMsg>초당 호출 허용량 초과</returnAuthMsg><returnReasonCode>23</returnReasonCode></cmmMsgHeader>
            </OpenAPI_ServiceResponse>""";

    public static String provider(String code, String msg) {
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?><response><header><resultCode>" + code + "</resultCode><resultMsg>"
                + msg + "</resultMsg></header></response>";
    }

    /** A getVilageFcst page: {@code rows} items starting at item {@code offset} of a synthetic issue. */
    public static String kmaPage(String baseDate, String baseTime, int nx, int ny, int totalCount, int pageNo, int numOfRows,
                                 List<String[]> rows) {
        StringBuilder sb = new StringBuilder("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<response><header><resultCode>00</resultCode>"
                + "<resultMsg>NORMAL_SERVICE</resultMsg></header><body><dataType>XML</dataType><items>");
        for (String[] r : rows) {
            sb.append("<item><baseDate>").append(baseDate).append("</baseDate><baseTime>").append(baseTime)
              .append("</baseTime><category>").append(r[0]).append("</category><fcstDate>").append(r[1])
              .append("</fcstDate><fcstTime>").append(r[2]).append("</fcstTime><fcstValue>").append(r[3])
              .append("</fcstValue><nx>").append(nx).append("</nx><ny>").append(ny).append("</ny></item>");
        }
        return sb.append("</items><numOfRows>").append(numOfRows).append("</numOfRows><pageNo>").append(pageNo)
                 .append("</pageNo><totalCount>").append(totalCount).append("</totalCount></body></response>").toString();
    }

    /** Rows for hours [fromHour, fromHour+count) of a day: SKY, PTY, TMP, REH, WSD, POP, PCP. */
    public static List<String[]> kmaHours(LocalDate day, int fromHour, int count, int sky, int pty) {
        var out = new java.util.ArrayList<String[]>();
        String d = day.format(DateTimeFormatter.BASIC_ISO_DATE);
        for (int h = fromHour; h < fromHour + count; h++) {
            LocalDate dd = day.plusDays(h / 24);
            String date = dd.format(DateTimeFormatter.BASIC_ISO_DATE), time = String.format("%02d00", h % 24);
            out.add(new String[]{"SKY", date, time, Integer.toString(sky)});
            out.add(new String[]{"PTY", date, time, Integer.toString(pty)});
            out.add(new String[]{"TMP", date, time, "14"});
            out.add(new String[]{"REH", date, time, "85"});
            out.add(new String[]{"WSD", date, time, "1.8"});
            out.add(new String[]{"POP", date, time, pty > 0 ? "70" : "10"});
            out.add(new String[]{"PCP", date, time, pty > 0 ? "1mm 미만" : "강수없음"});
        }
        return out;
    }

    /** Decimal coordinates plus the matching degree-minute fields (DDMM / DDDMM), as live responses carry both. */
    public static String riseSet(String locdate, String location, String lat, String lon) {
        return riseSet(locdate, location, lat, lon, ddmm(lat), ddmm(lon));
    }

    /** {@code latDdmm}/{@code lonDdmm} null → element omitted (e.g. when lat/lon are WireMock templates). */
    public static String riseSet(String locdate, String location, String lat, String lon, String latDdmm, String lonDdmm) {
        String dm = (latDdmm == null ? "" : "<latitude>" + latDdmm + "</latitude>") + (lonDdmm == null ? "" : "<longitude>" + lonDdmm + "</longitude>");
        return """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?><response><header><resultCode>00</resultCode><resultMsg>NORMAL SERVICE.</resultMsg></header><body><items><item><aste>1943  </aste><astm>0436  </astm><civile>1845  </civile><civilm>0559  </civilm>%s<latitudeNum>%s</latitudeNum><location>%s</location><locdate>%s</locdate><longitudeNum>%s</longitudeNum><moonrise>1925  </moonrise><moonset>0904  </moonset><moontransit>------</moontransit><naute>1914  </naute><nautm>0530  </nautm><sunrise>0625  </sunrise><sunset>1819  </sunset><suntransit>122245</suntransit></item></items><numOfRows>10</numOfRows><pageNo>1</pageNo><totalCount>1</totalCount></body></response>"""
                .formatted(dm, lat, location, locdate, lon);
    }

    static String ddmm(String decimal) {
        double v = Double.parseDouble(decimal);
        int deg = (int) v, min = (int) Math.round((v - deg) * 60);
        return String.format("%d%02d", deg, min);
    }

    /** The official sample's quirks: time inside astroTitle, a YYYYMM monthly feature item. */
    public static final String ASTRO_EVENTS = """
            <response><header><resultCode>00</resultCode><resultMsg>NORMAL SERVICE.</resultMsg></header><body><items>
            <item><astroEvent>이달의 천문 이야기</astroEvent><astroTitle>가을 별자리</astroTitle><locdate>202610</locdate><seq>1</seq></item>
            <item><astroEvent>보름(망)</astroEvent><astroTitle>13:53</astroTitle><locdate>20261026</locdate><remarks/><seq>1</seq></item>
            <item><astroEvent>오리온자리 유성우 극대</astroEvent><astroTime>6:00</astroTime><astroTitle></astroTitle><locdate>20261021</locdate><seq>1</seq></item>
            </items><numOfRows>100</numOfRows><pageNo>1</pageNo><totalCount>3</totalCount></body></response>""";

    public static final String REST_DAYS = """
            <response> <header> <resultCode>00</resultCode> <resultMsg>NORMAL SERVICE.</resultMsg> </header> <body> <items>
            <item> <dateKind>01</dateKind> <dateName>개천절</dateName> <isHoliday>Y</isHoliday> <locdate>20261003</locdate> <seq>1</seq> </item>
            <item> <dateKind>01</dateKind> <dateName>한글날</dateName> <isHoliday>Y</isHoliday> <locdate>20261009</locdate> <seq>1</seq> </item>
            </items> <numOfRows>100</numOfRows> <pageNo>1</pageNo> <totalCount>2</totalCount> </body> </response>""";

    public static final String DIVISIONS = """
            <response><header><resultCode>00</resultCode><resultMsg>NORMAL SERVICE.</resultMsg></header><body><items>
            <item><dateKind>03</dateKind><dateName>한로</dateName><isHoliday>N</isHoliday><kst>0541 </kst><locdate>20261008</locdate><seq>1</seq><sunLongitude>195</sunLongitude></item>
            </items><numOfRows>100</numOfRows><pageNo>1</pageNo><totalCount>1</totalCount></body></response>""";

    public static final String LUNAR_TWO_DAYS = """
            <response><header><resultCode>00</resultCode><resultMsg>NORMAL SERVICE.</resultMsg></header><body><items>
            <item><lunDay>21</lunDay><lunIljin>갑자(甲子)</lunIljin><lunLeapmonth>평</lunLeapmonth><lunMonth>08</lunMonth><lunNday>30</lunNday><lunYear>2026</lunYear><solDay>01</solDay><solJd>2461315</solJd><solLeapyear>평</solLeapyear><solMonth>10</solMonth><solWeek>목</solWeek><solYear>2026</solYear></item>
            <item><lunDay>22</lunDay><lunIljin>을축(乙丑)</lunIljin><lunLeapmonth>평</lunLeapmonth><lunMonth>08</lunMonth><lunNday>30</lunNday><lunYear>2026</lunYear><solDay>02</solDay><solJd>2461316</solJd><solLeapyear>평</solLeapyear><solMonth>10</solMonth><solWeek>금</solWeek><solYear>2026</solYear></item>
            </items><numOfRows>100</numOfRows><pageNo>1</pageNo><totalCount>2</totalCount></body></response>""";
}
