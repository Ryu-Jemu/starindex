package dev.starindex.datagokr;

import com.github.tomakehurst.wiremock.WireMockServer;
import dev.starindex.etl.kasi.KasiClient;
import dev.starindex.etl.kma.KmaBaseTime;
import dev.starindex.etl.kma.KmaForecastClient;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.time.LocalDate;
import java.time.LocalTime;
import java.time.YearMonth;
import java.time.ZonedDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

import static com.github.tomakehurst.wiremock.client.WireMock.*;
import static com.github.tomakehurst.wiremock.core.WireMockConfiguration.options;
import static org.junit.jupiter.api.Assertions.*;

/** data.go.kr client against WireMock: encoding, error classification, paging, KMA/KASI parsing. No Spring. */
class DataGoKrClientTest {
    /** A Decoding key with every character that needs strict encoding. */
    static final String KEY = "abc+DEF/ghi==";
    static WireMockServer wm;
    List<ApiCallRecorder.Call> calls;

    @BeforeAll
    static void start() {
        wm = new WireMockServer(options().dynamicPort());
        wm.start();
    }

    @AfterAll
    static void stop() { wm.stop(); }

    @BeforeEach
    void reset() {
        wm.resetAll();
        calls = new ArrayList<>();
    }

    DataGoKrClient client(String key) {
        var props = new DataGoKrProperties(key, wm.baseUrl(), Duration.ofSeconds(2), Duration.ofSeconds(5),
                Duration.ofMillis(1), 10_000, 0.7, 0.9);
        return new DataGoKrClient(props, calls::add, QuotaGuard.NONE);
    }

    static String xml(String s) { return s; }

    @Test
    void keyIsStrictlyEncodedOnceAndNeverDoubleEncoded() {
        var uri = client(KEY).buildUri(ApiSource.KMA_VILAGE, "getVilageFcst", Map.of("nx", "60"));
        assertTrue(uri.getRawQuery().contains("serviceKey=abc%2BDEF%2Fghi%3D%3D"), uri.getRawQuery());
        wm.stubFor(get(urlPathEqualTo("/1360000/VilageFcstInfoService_2.0/getVilageFcst"))
                .withQueryParam("serviceKey", equalTo(KEY))
                .willReturn(aResponse().withStatus(200).withBody(Fixtures.provider("03", "NO_DATA"))));
        var body = client(KEY).get(ApiSource.KMA_VILAGE, "getVilageFcst", Map.of("nx", "60"), "t");
        assertTrue(body.noData());
        assertEquals("NO_DATA", calls.getLast().outcome());
    }

    @Test
    void koreanQueryValuesAreEncoded() {
        var uri = client(KEY).buildUri(ApiSource.KASI_RISESET, "getAreaRiseSetInfo", Map.of("location", "서울"));
        assertTrue(uri.getRawQuery().contains("location=%EC%84%9C%EC%9A%B8"), uri.getRawQuery());
    }

    @Test
    void missingKeyFailsBeforeAnyCall() {
        var e = assertThrows(DataGoKrException.class, () -> client("  ").get(ApiSource.KMA_VILAGE, "getVilageFcst", Map.of(), "t"));
        assertEquals(DataGoKrException.Kind.KEY_MISSING, e.kind());
        assertTrue(e.guidance().contains("DATA_GO_KR_SERVICE_KEY"));
        assertEquals(0, wm.getAllServeEvents().size());
    }

    @Test
    void gatewayKeyErrorIsReadFrom403BodyAndNotRetried() {
        wm.stubFor(get(anyUrl()).willReturn(aResponse().withStatus(403).withHeader("Content-Type", "application/xml")
                .withBody(Fixtures.GATEWAY_30_XML.getBytes(StandardCharsets.UTF_8))));
        var e = assertThrows(DataGoKrException.class, () -> client(KEY).get(ApiSource.KASI_RISESET, "getLCRiseSetInfo", Map.of(), "t"));
        assertEquals(DataGoKrException.Kind.KEY_REJECTED, e.kind());
        assertEquals("30", e.code());
        assertEquals(403, e.httpStatus());
        assertTrue(e.guidance().contains("활용신청"));
        assertEquals(1, wm.getAllServeEvents().size(), "key errors must not be retried");
        assertEquals("KEY_REJECTED", calls.getLast().outcome());
    }

    @Test
    void gatewayJsonErrorAndQuotaAreClassified() {
        wm.stubFor(get(anyUrl()).willReturn(aResponse().withStatus(403).withHeader("Content-Type", "application/json")
                .withBody(Fixtures.GATEWAY_30_JSON)));
        assertEquals(DataGoKrException.Kind.KEY_REJECTED,
                assertThrows(DataGoKrException.class, () -> client(KEY).get(ApiSource.KMA_VILAGE, "x", Map.of(), "t")).kind());
        wm.resetAll();
        wm.stubFor(get(anyUrl()).willReturn(aResponse().withStatus(429).withBody(Fixtures.GATEWAY_22_XML)));
        assertEquals(DataGoKrException.Kind.QUOTA,
                assertThrows(DataGoKrException.class, () -> client(KEY).get(ApiSource.KMA_VILAGE, "x", Map.of(), "t")).kind());
    }

    @Test
    void transientErrorsAreRetriedThenSurface() {
        wm.stubFor(get(anyUrl()).willReturn(aResponse().withStatus(502).withBody("Bad gateway")));
        var e = assertThrows(DataGoKrException.class, () -> client(KEY).get(ApiSource.KMA_VILAGE, "x", Map.of(), "t"));
        assertEquals(DataGoKrException.Kind.IO, e.kind());
        assertEquals(3, wm.getAllServeEvents().size(), "1 try + 2 retries");
        wm.resetAll();
        wm.stubFor(get(anyUrl()).willReturn(aResponse().withStatus(200).withBody(Fixtures.provider("99", "UNKNOWN_ERROR"))));
        assertEquals(DataGoKrException.Kind.PROVIDER,
                assertThrows(DataGoKrException.class, () -> client(KEY).get(ApiSource.KMA_VILAGE, "x", Map.of(), "t")).kind());
        assertEquals(3, wm.getAllServeEvents().size(), "transient provider errors are retried");
    }

    @Test
    void perSecondLimitIsRetriedButMalformedRequestsAreNot() {
        wm.stubFor(get(anyUrl()).willReturn(aResponse().withStatus(429).withBody(Fixtures.GATEWAY_23_XML)));
        var rate = assertThrows(DataGoKrException.class, () -> client(KEY).get(ApiSource.KMA_VILAGE, "x", Map.of(), "t"));
        assertEquals(DataGoKrException.Kind.RATE_LIMITED, rate.kind());
        assertFalse(rate.kind().stopsRun());
        assertEquals(3, wm.getAllServeEvents().size(), "23 is transient: retried");
        wm.resetAll();
        wm.stubFor(get(anyUrl()).willReturn(aResponse().withStatus(200).withBody(Fixtures.provider("10", "INVALID_REQUEST_PARAMETER_ERROR"))));
        var bad = assertThrows(DataGoKrException.class, () -> client(KEY).get(ApiSource.KMA_VILAGE, "x", Map.of(), "t"));
        assertEquals(DataGoKrException.Kind.REQUEST, bad.kind());
        assertTrue(bad.kind().stopsRun());
        assertEquals(1, wm.getAllServeEvents().size(), "10 repeats for every call: not retried");
    }

    @Test
    void kasiReturnedCoordinatePrefersDegreeMinuteWhenNumDisagrees() {
        assertEquals(37.55, KasiClient.returned("37.5500000", "3733"), 1e-9);
        assertEquals(126 + 58 / 60.0, KasiClient.returned("37.5500000", "12658"), 1e-9, "guide sample copies latitude into longitudeNum");
        assertEquals(36 + 13 / 60.0, KasiClient.returned(null, "3613"), 1e-9);
        assertNull(KasiClient.returned(" ", "x"));
    }

    @Test
    void doctypeIsRejected() {
        String xxe = "<?xml version=\"1.0\"?><!DOCTYPE r [<!ENTITY x SYSTEM \"file:///etc/passwd\">]><response>&x;</response>";
        assertThrows(IllegalArgumentException.class, () -> DataGoKrXml.parse(xxe.getBytes(StandardCharsets.UTF_8)));
    }

    @Test
    void kmaFetchPagesPastOneThousandRowsAndParsesValues() {
        var base = KmaBaseTime.parse("20261012", "1700");
        LocalDate d = LocalDate.of(2026, 10, 12);
        List<String[]> all = new ArrayList<>(Fixtures.kmaHours(d, 18, 146, 3, 0));        // 146 h × 7 = 1022 rows
        all.add(new String[]{"WSD", "20261016", "1800", "1"});                              // 그글피 → code, not m/s
        all.add(new String[]{"TMP", "20261013", "0300", "-999"});                           // missing
        int total = all.size();
        wm.stubFor(get(urlPathEqualTo("/1360000/VilageFcstInfoService_2.0/getVilageFcst")).withQueryParam("pageNo", equalTo("1"))
                .willReturn(aResponse().withBody(Fixtures.kmaPage("20261012", "1700", 60, 127, total, 1, 1000, all.subList(0, 1000)))));
        wm.stubFor(get(urlPathEqualTo("/1360000/VilageFcstInfoService_2.0/getVilageFcst")).withQueryParam("pageNo", equalTo("2"))
                .willReturn(aResponse().withBody(Fixtures.kmaPage("20261012", "1700", 60, 127, total, 2, 1000, all.subList(1000, total)))));
        var res = new KmaForecastClient(client(KEY)).fetch(60, 127, base);
        assertEquals(total, res.items().size());
        assertEquals(2, wm.getAllServeEvents().size());
        var code = res.items().stream().filter(i -> i.category().equals("WSD") && i.code()).findFirst().orElseThrow();
        assertNull(code.valueNum());
        // Stored rows: six items per hour only, codes and missing values never become numbers.
        var hours = KmaForecastClient.hours(res.items());
        assertEquals(146, hours.size(), "one row per forecast hour");
        var first = hours.getFirst();
        assertEquals((short) 3, first.sky());
        assertEquals(new java.math.BigDecimal("14.0"), first.tmp());
        assertEquals(new java.math.BigDecimal("1.8"), first.wsd());
        var coded = hours.stream().filter(h -> h.fcstAt().equals(code.fcstAt())).findFirst().orElseThrow();
        assertNull(coded.wsd(), "extended-period WSD is a code, never stored as m/s");
        assertEquals((short) 3, coded.sky());
        var tmp0300 = hours.stream().filter(h -> h.fcstAt().equals(ZonedDateTime.of(2026, 10, 13, 3, 0, 0, 0, KmaBaseTime.KST).toInstant()))
                .findFirst().orElseThrow();
        assertEquals(new java.math.BigDecimal("14.0"), tmp0300.tmp(), "a missing (-999) duplicate never erases a value");
        var missing = res.items().stream().filter(i -> i.valueText().equals("-999")).findFirst().orElseThrow();
        assertNull(missing.valueNum());
        var sky = res.items().stream().filter(i -> i.category().equals("SKY")).findFirst().orElseThrow();
        assertEquals(3.0, sky.valueNum());
        assertEquals(ZonedDateTime.of(2026, 10, 12, 18, 0, 0, 0, KmaBaseTime.KST).toInstant(), sky.fcstAt());
    }

    @Test
    void kasiRiseSetParsesPaddedTimesAndRejectsFarLocations() {
        wm.stubFor(get(urlPathEqualTo("/B090041/openapi/service/RiseSetInfoService/getLCRiseSetInfo"))
                .withQueryParam("ServiceKey", equalTo(KEY)).withQueryParam("dnYn", equalTo("Y"))
                .willReturn(aResponse().withBody(Fixtures.riseSet("20260929", "서울", "37.5500000", "126.9666660"))));
        var day = new KasiClient(client(KEY)).riseSet(37.5636, 126.9800, LocalDate.of(2026, 9, 29)).orElseThrow();
        assertEquals("서울", day.location());
        assertEquals(LocalTime.of(18, 19), day.sunset());
        assertEquals(LocalTime.of(18, 45), day.civile());
        assertEquals(LocalTime.of(12, 22, 45), day.suntransit());
        assertNull(day.moontransit(), "dashes = no event");
        wm.resetAll();
        wm.stubFor(get(anyUrl()).willReturn(aResponse().withBody(Fixtures.riseSet("20260929", "독도", "37.2400000", "131.8666660"))));
        var e = assertThrows(DataGoKrException.class,
                () -> new KasiClient(client(KEY)).riseSet(37.5636, 126.9800, LocalDate.of(2026, 9, 29)));
        assertEquals(DataGoKrException.Kind.PARSE, e.kind());
    }

    @Test
    void kasiEventsSpecialDaysAndLunarAreLenient() {
        wm.stubFor(get(urlPathEqualTo("/B090041/openapi/service/AstroEventInfoService/getAstroEventInfo"))
                .willReturn(aResponse().withBody(Fixtures.ASTRO_EVENTS)));
        wm.stubFor(get(urlPathEqualTo("/B090041/openapi/service/SpcdeInfoService/getRestDeInfo"))
                .willReturn(aResponse().withBody(Fixtures.REST_DAYS)));
        wm.stubFor(get(urlPathEqualTo("/B090041/openapi/service/SpcdeInfoService/get24DivisionsInfo"))
                .willReturn(aResponse().withBody(Fixtures.DIVISIONS)));
        wm.stubFor(get(urlPathEqualTo("/B090041/openapi/service/LrsrCldInfoService/getLunCalInfo"))
                .willReturn(aResponse().withBody(Fixtures.LUNAR_TWO_DAYS)));
        var kasi = new KasiClient(client(KEY));
        var ym = YearMonth.of(2026, 10);
        var events = kasi.astroEvents(ym);
        assertEquals(3, events.size());
        assertTrue(events.getFirst().monthFeature());
        assertEquals(LocalDate.of(2026, 10, 1), events.getFirst().locdate());
        var fullMoon = events.get(1);
        assertEquals(LocalTime.of(13, 53), fullMoon.astroTime());
        assertNull(fullMoon.title(), "time moved out of astroTitle");
        assertEquals(LocalTime.of(6, 0), events.get(2).astroTime());
        var rest = kasi.specialDays("getRestDeInfo", ym);
        assertEquals(2, rest.size());
        assertTrue(rest.getFirst().holiday());
        var div = kasi.specialDays("get24DivisionsInfo", ym).getFirst();
        assertEquals(LocalTime.of(5, 41), div.kst());
        assertEquals(195, div.sunLongitude());
        var lunar = kasi.lunarMonth(ym);
        assertEquals(2, lunar.size());
        assertEquals(8, lunar.getFirst().lunMonth());
        assertFalse(lunar.getFirst().leap());
        assertEquals(LocalDate.of(2026, 10, 1), lunar.getFirst().solDate());
    }

    @Test
    void kasiTimeParser() {
        assertEquals(LocalTime.of(7, 46), KasiClient.time("0746  "));
        assertEquals(LocalTime.of(7, 46, 48), KasiClient.time("074648"));
        assertEquals(LocalTime.MIDNIGHT, KasiClient.time("2400"));
        assertNull(KasiClient.time("------"));
        assertNull(KasiClient.time("   "));
        assertNull(KasiClient.time("7:46"));
        assertNull(KasiClient.time(null));
    }

    @Test
    void latestAvailableBaseTime() {
        var delay = Duration.ofMinutes(15);
        assertEquals("20261012 1700", KmaBaseTime.latestAvailable(ZonedDateTime.of(2026, 10, 12, 17, 15, 0, 0, KmaBaseTime.KST), delay).toString());
        assertEquals("20261012 1400", KmaBaseTime.latestAvailable(ZonedDateTime.of(2026, 10, 12, 17, 14, 0, 0, KmaBaseTime.KST), delay).toString());
        assertEquals("20261011 2300", KmaBaseTime.latestAvailable(ZonedDateTime.of(2026, 10, 12, 2, 5, 0, 0, KmaBaseTime.KST), delay).toString());
        assertEquals("20261012 0200", KmaBaseTime.latestAvailable(ZonedDateTime.of(2026, 10, 12, 2, 15, 0, 0, KmaBaseTime.KST), delay).toString());
        assertThrows(IllegalArgumentException.class, () -> KmaBaseTime.parse("20261012", "1600"));
    }
}
