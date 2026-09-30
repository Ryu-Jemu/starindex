package dev.starindex.etl;

import com.github.tomakehurst.wiremock.WireMockServer;
import dev.starindex.IntegrationTestBase;
import dev.starindex.datagokr.Fixtures;
import dev.starindex.pack.PackPublisher;
import dev.starindex.pack.PackStore;
import dev.starindex.pack.PackWriter;
import dev.starindex.region.RegionQueryRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.batch.core.BatchStatus;
import org.springframework.batch.core.job.Job;
import org.springframework.batch.core.job.JobExecution;
import org.springframework.batch.core.job.parameters.JobParametersBuilder;
import org.springframework.batch.core.launch.JobOperator;
import org.springframework.batch.core.step.StepExecution;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.LocalDate;
import java.util.stream.Collectors;

import static com.github.tomakehurst.wiremock.client.WireMock.*;
import static com.github.tomakehurst.wiremock.core.WireMockConfiguration.options;
import static org.junit.jupiter.api.Assertions.*;

/** End-to-end ETL with a key: WireMock stands in for data.go.kr, PostgreSQL 18 and Valkey are real. */
class EtlJobsIntegrationTest extends IntegrationTestBase {
    static final WireMockServer WM = new WireMockServer(options().dynamicPort().globalTemplating(true));
    static final Path PACKS;

    static {
        WM.start();
        try {
            PACKS = Files.createTempDirectory("starindex-packs");
        } catch (java.io.IOException e) {
            throw new IllegalStateException(e);
        }
    }

    @DynamicPropertySource
    static void props(DynamicPropertyRegistry r) {
        r.add("starindex.data-go-kr.base-url", WM::baseUrl);
        r.add("starindex.data-go-kr.service-key", () -> "test+key/value==");
        r.add("starindex.data-go-kr.min-interval", () -> "1ms");
        r.add("starindex.pack.local-dir", PACKS::toString);
    }

    @Autowired JobOperator jobs;
    @Autowired JdbcTemplate jdbc;
    @Autowired RegionQueryRepository regions;
    @Autowired PackStore packStore;
    @Autowired @Qualifier("forecastPipelineJob") Job forecastPipelineJob;
    @Autowired @Qualifier("forecastIngestJob") Job forecastIngestJob;
    @Autowired @Qualifier("astroDailyJob") Job astroDailyJob;
    @Autowired @Qualifier("astroEventsJob") Job astroEventsJob;
    @Autowired @Qualifier("apiKeyCheckJob") Job apiKeyCheckJob;

    @BeforeEach
    void clean() {
        WM.resetAll();
        jdbc.execute("TRUNCATE etl_api_call, kma_forecast, kma_forecast_issue, kasi_riseset, astro_night, astro_crosscheck, "
                + "kasi_astro_event, kasi_special_day, kasi_lunar_day, star_index_hourly, star_index_nightly, data_pack");
    }

    JobExecution run(Job job, String... kv) throws Exception {
        var b = new JobParametersBuilder().addLong("run", System.nanoTime());
        for (int i = 0; i < kv.length; i += 2) b.addString(kv[i], kv[i + 1]);
        return jobs.start(job, b.toJobParameters());
    }

    static String failures(JobExecution e) {
        return e.getAllFailureExceptions().stream().map(Throwable::getMessage).collect(Collectors.joining(" | "));
    }

    int count(String table) { return jdbc.queryForObject("SELECT COUNT(*) FROM " + table, Integer.class); }

    void stubForecastForAllCells(String baseDate, String baseTime, LocalDate night, int sky, int pty) {
        for (var r : regions.findActive()) {
            String body = Fixtures.kmaPage(baseDate, baseTime, r.getKmaNx(), r.getKmaNy(), 60 * 7, 1, 1000,
                    Fixtures.kmaHours(night, 18, 60, sky, pty));
            WM.stubFor(get(urlPathEqualTo("/1360000/VilageFcstInfoService_2.0/getVilageFcst"))
                    .withQueryParam("base_date", equalTo(baseDate)).withQueryParam("base_time", equalTo(baseTime))
                    .withQueryParam("nx", equalTo(Integer.toString(r.getKmaNx()))).withQueryParam("ny", equalTo(Integer.toString(r.getKmaNy())))
                    .willReturn(aResponse().withHeader("Content-Type", "application/xml").withBody(body)));
        }
    }

    @Test
    void forecastPipelineIngestsScoresAndPublishesIdempotently() throws Exception {
        LocalDate night = LocalDate.of(2026, 10, 12);
        stubForecastForAllCells("20261012", "1700", night, 1, 0);

        JobExecution e = run(forecastPipelineJob, "base", "202610121700", "nightDate", "2026-10-12");
        assertEquals(BatchStatus.COMPLETED, e.getStatus(), failures(e));
        assertEquals(17, count("kma_forecast_issue"));
        assertEquals(17 * 60 * 7, count("kma_forecast"));
        assertEquals(17, count("star_index_nightly"));
        assertEquals(1, count("data_pack"));
        // Key reached the gateway decoded exactly as configured (strict encoding on the wire).
        WM.verify(17, getRequestedFor(urlPathEqualTo("/1360000/VilageFcstInfoService_2.0/getVilageFcst"))
                .withQueryParam("serviceKey", equalTo("test+key/value==")));

        var manifest = JsonMapper.builder().build().readTree(packStore.get(PackPublisher.MANIFEST_PATH).orElseThrow());
        String path = manifest.at("/packs/index/path").asString();
        byte[] gz = packStore.get(path).orElseThrow();
        assertEquals(manifest.at("/packs/index/sha256").asString(), PackWriter.sha256(gz));
        assertEquals(jdbc.queryForObject("SELECT sha256 FROM data_pack", String.class), PackWriter.sha256(gz));

        JsonNode pack = JsonMapper.builder().build().readTree(PackPublisher.gunzipToString(gz));
        assertEquals(2, pack.get("schema").asInt());
        assertEquals("2026-10-12", pack.get("nightDate").asString());
        assertEquals(17, pack.get("regions").size());
        JsonNode seoul = null;
        for (JsonNode r : pack.get("regions")) if (r.get("id").asString().equals("1100000000")) seoul = r;
        assertNotNull(seoul);
        assertTrue(seoul.get("score").asInt() >= 90, "clear, dark night should score high: " + seoul.get("score"));
        assertEquals(72, seoul.at("/hourly/sky").size());
        assertEquals(2, seoul.get("best").size());
        assertNotNull(seoul.at("/twilight/computed/aste").asString());
        assertFalse(new String(gz, StandardCharsets.ISO_8859_1).contains("test+key"), "pack must never contain the key");

        // Rerun: same rows, same pack version (content-addressed), nothing duplicated.
        JobExecution again = run(forecastPipelineJob, "base", "202610121700", "nightDate", "2026-10-12");
        assertEquals(BatchStatus.COMPLETED, again.getStatus(), failures(again));
        assertEquals(17 * 60 * 7, count("kma_forecast"));
        assertEquals(1, count("data_pack"));
        assertEquals(manifest.at("/packs/index/version").asString(),
                JsonMapper.builder().build().readTree(packStore.get(PackPublisher.MANIFEST_PATH).orElseThrow()).at("/packs/index/version").asString());
    }

    @Test
    void cloudyForecastLowersTheIndex() throws Exception {
        LocalDate night = LocalDate.of(2026, 10, 12);
        stubForecastForAllCells("20261012", "1700", night, 4, 0);
        JobExecution e = run(forecastPipelineJob, "base", "202610121700", "nightDate", "2026-10-12");
        assertEquals(BatchStatus.COMPLETED, e.getStatus(), failures(e));
        Integer max = jdbc.queryForObject("SELECT MAX(score) FROM star_index_nightly", Integer.class);
        assertTrue(max != null && max <= 15, "overcast (SKY 4 → 0.15) caps the score: " + max);
    }

    @Test
    void rejectedKeyStopsIngestWithGuidance() throws Exception {
        WM.stubFor(get(anyUrl()).willReturn(aResponse().withStatus(403).withHeader("Content-Type", "application/xml")
                .withBody(Fixtures.GATEWAY_30_XML)));
        JobExecution e = run(forecastIngestJob, "base", "202610131700");
        assertEquals(BatchStatus.FAILED, e.getStatus());
        assertTrue(failures(e).contains("활용신청"), failures(e));
        assertEquals(1, WM.getAllServeEvents().size(), "stop at the first key error, not 17 times");
        assertEquals(0, count("kma_forecast"));
        assertEquals(1, count("etl_api_call"));
    }

    @Test
    void incompleteForecastFailsTheCompletenessGate() throws Exception {
        stubForecastForAllCells("20261012", "1700", LocalDate.of(2026, 10, 12), 1, 0);
        WM.stubFor(get(urlPathEqualTo("/1360000/VilageFcstInfoService_2.0/getVilageFcst")).withQueryParam("nx", equalTo("60"))
                .atPriority(1).willReturn(aResponse().withStatus(502).withBody("upstream down")));
        JobExecution e = run(forecastIngestJob, "base", "202610121700");
        assertEquals(BatchStatus.FAILED, e.getStatus());
        assertTrue(failures(e).contains("완결성 미달"), failures(e));
        assertEquals(15, count("kma_forecast_issue"), "서울(60,127)과 경기(60,120)만 실패하고 나머지는 저장");
    }

    @Test
    void astroDailyStoresKasiTimesAndCrossChecksAgainstAstronomyEngine() throws Exception {
        WM.stubFor(get(urlPathEqualTo("/B090041/openapi/service/RiseSetInfoService/getLCRiseSetInfo"))
                .willReturn(aResponse().withHeader("Content-Type", "application/xml").withBody(
                        Fixtures.riseSet("{{request.query.locdate}}", "테스트", "{{request.query.latitude}}", "{{request.query.longitude}}"))));
        JobExecution e = run(astroDailyJob, "from", "2026-09-29");
        assertEquals(BatchStatus.COMPLETED, e.getStatus(), failures(e));
        assertEquals(17 * 4, count("astro_night"));
        assertEquals(17 * 4, count("kasi_riseset"));
        Integer seoulSunsetDiff = jdbc.queryForObject("""
                SELECT diff_seconds FROM astro_crosscheck WHERE region_id = 1100000000 AND night_date = '2026-09-29' AND field = 'sunset'""",
                Integer.class);
        assertNotNull(seoulSunsetDiff);
        assertTrue(Math.abs(seoulSunsetDiff) <= 120, "Seoul 9/29 sunset: fixture 18:19 (USNO) vs Astronomy Engine: " + seoulSunsetDiff);
    }

    @Test
    void astroEventsSkipsUnapprovedOptionalApis() throws Exception {
        WM.stubFor(get(urlPathEqualTo("/B090041/openapi/service/AstroEventInfoService/getAstroEventInfo"))
                .willReturn(aResponse().withBody(Fixtures.ASTRO_EVENTS)));
        WM.stubFor(get(urlPathMatching("/B090041/openapi/service/(SpcdeInfoService|LrsrCldInfoService)/.*"))
                .willReturn(aResponse().withStatus(403).withBody(Fixtures.GATEWAY_30_XML)));
        JobExecution e = run(astroEventsJob, "month", "2026-10");
        assertEquals(BatchStatus.COMPLETED, e.getStatus(), failures(e));
        assertEquals(3, count("kasi_astro_event"));
        var exits = e.getStepExecutions().stream().collect(Collectors.toMap(StepExecution::getStepName, s -> s.getExitStatus().getExitCode()));
        assertEquals("SKIPPED", exits.get("specialDays"));
        assertEquals("SKIPPED", exits.get("lunar"));

        WM.resetAll();
        WM.stubFor(get(urlPathEqualTo("/B090041/openapi/service/AstroEventInfoService/getAstroEventInfo"))
                .willReturn(aResponse().withBody(Fixtures.ASTRO_EVENTS)));
        WM.stubFor(get(urlPathMatching("/B090041/openapi/service/SpcdeInfoService/getRestDeInfo")).willReturn(aResponse().withBody(Fixtures.REST_DAYS)));
        WM.stubFor(get(urlPathMatching("/B090041/openapi/service/SpcdeInfoService/get24DivisionsInfo")).willReturn(aResponse().withBody(Fixtures.DIVISIONS)));
        WM.stubFor(get(urlPathMatching("/B090041/openapi/service/LrsrCldInfoService/getLunCalInfo")).willReturn(aResponse().withBody(Fixtures.LUNAR_TWO_DAYS)));
        JobExecution all = run(astroEventsJob, "month", "2026-10");
        assertEquals(BatchStatus.COMPLETED, all.getStatus(), failures(all));
        assertEquals(3, count("kasi_special_day"));
        assertEquals(2, count("kasi_lunar_day"));
    }

    @Test
    void apiKeyCheckReportsEachApi() throws Exception {
        WM.stubFor(get(urlPathEqualTo("/1360000/VilageFcstInfoService_2.0/getVilageFcst"))
                .willReturn(aResponse().withBody(Fixtures.provider("03", "NO_DATA"))));
        WM.stubFor(get(urlPathEqualTo("/B090041/openapi/service/RiseSetInfoService/getLCRiseSetInfo"))
                .willReturn(aResponse().withBody(Fixtures.riseSet("20260930", "서울", "37.5500000", "126.9666660"))));
        WM.stubFor(get(urlPathEqualTo("/B090041/openapi/service/AstroEventInfoService/getAstroEventInfo"))
                .willReturn(aResponse().withBody(Fixtures.ASTRO_EVENTS)));
        WM.stubFor(get(urlPathMatching("/B090041/openapi/service/(SpcdeInfoService|LrsrCldInfoService)/.*"))
                .willReturn(aResponse().withStatus(403).withBody(Fixtures.GATEWAY_30_XML)));
        JobExecution ok = run(apiKeyCheckJob);
        assertEquals(BatchStatus.COMPLETED, ok.getStatus(), failures(ok));
        String report = ok.getExecutionContext().getString("summary.apiKeyCheck");
        assertTrue(report.contains("OK   기상청 단기예보") && report.contains("FAIL 한국천문연구원 특일") && report.contains("[선택]"), report);
        assertEquals(5, WM.getAllServeEvents().size(), "one call per API");

        WM.resetAll();
        WM.stubFor(get(anyUrl()).willReturn(aResponse().withStatus(403).withBody(Fixtures.GATEWAY_30_XML)));
        JobExecution bad = run(apiKeyCheckJob);
        assertEquals(BatchStatus.FAILED, bad.getStatus());
        assertTrue(failures(bad).contains("필수 API 실패: 기상청 단기예보 조회서비스"), failures(bad));
    }
}
