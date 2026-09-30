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
    void clean() throws java.io.IOException {
        WM.resetAll();
        // Packs and the manifest are shared state across tests: start every test from an empty store.
        try (var paths = Files.walk(PACKS)) {
            paths.sorted(java.util.Comparator.reverseOrder()).filter(p -> !p.equals(PACKS)).forEach(p -> p.toFile().delete());
        }
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

    @Autowired @Qualifier("starIndexPublishJob") Job starIndexPublishJob;
    @Autowired EtlRepository etlRepository;

    String manifestField(String pointer) {
        return JsonMapper.builder().build().readTree(packStore.get(PackPublisher.MANIFEST_PATH).orElseThrow()).at(pointer).asString();
    }

    @Test
    void backfillingAnOlderNightDoesNotRollBackTheLiveManifest() throws Exception {
        stubForecastForAllCells("20261012", "1700", LocalDate.of(2026, 10, 12), 1, 0);
        JobExecution tonight = run(forecastPipelineJob, "base", "202610121700", "nightDate", "2026-10-13");
        assertEquals(BatchStatus.COMPLETED, tonight.getStatus(), failures(tonight));
        assertEquals("2026-10-13", manifestField("/packs/index/nightDate"));
        String liveVersion = manifestField("/packs/index/version");

        JobExecution backfill = run(starIndexPublishJob, "nightDate", "2026-10-12");
        assertEquals(BatchStatus.COMPLETED, backfill.getStatus(), failures(backfill));
        assertEquals(2, count("data_pack"), "the older night's pack is still stored");
        assertEquals(liveVersion, manifestField("/packs/index/version"), "manifest must not go back to 10-12");
        assertTrue(backfill.getExecutionContext().getString("summary.indexPublish").contains("manifest 유지"));
    }

    @Test
    void manifestDescribesTheStoredFileWhenTheVersionAlreadyExists() throws Exception {
        stubForecastForAllCells("20261012", "1700", LocalDate.of(2026, 10, 12), 1, 0);
        assertEquals(BatchStatus.COMPLETED, run(forecastPipelineJob, "base", "202610121700", "nightDate", "2026-10-12").getStatus());
        String path = manifestField("/packs/index/path");
        // Same JSON compressed differently (as after a JDK/zlib change): the immutable stored file must win.
        byte[] json = PackPublisher.gunzipToString(packStore.get(path).orElseThrow()).getBytes(StandardCharsets.UTF_8);
        var bos = new java.io.ByteArrayOutputStream();
        try (var gz = new java.util.zip.GZIPOutputStream(bos) { { def.setLevel(1); } }) { gz.write(json); }
        packStore.put(path, bos.toByteArray(), "application/gzip", PackStore.IMMUTABLE);
        assertEquals(BatchStatus.COMPLETED, run(starIndexPublishJob, "nightDate", "2026-10-12").getStatus());
        assertEquals(PackWriter.sha256(packStore.get(path).orElseThrow()), manifestField("/packs/index/sha256"));
    }

    @Test
    void malformedParametersStopWithTheExpectedFormat() throws Exception {
        JobExecution e = run(forecastIngestJob, "base", "2026101217");
        assertEquals(BatchStatus.FAILED, e.getStatus());
        assertTrue(failures(e).contains("base=2026101217 형식이 틀렸습니다"), failures(e));
        assertEquals(0, WM.getAllServeEvents().size());
    }

    @Test
    void aMissingNewestValueFallsBackToTheOlderIssue() {
        var hour = java.time.OffsetDateTime.parse("2026-10-12T21:00:00+09:00");
        jdbc.update("""
                INSERT INTO kma_forecast (nx, ny, base_at, fcst_at, category, value_text, value_num) VALUES
                (60, 127, '2026-10-12T14:00:00+09:00', ?, 'SKY', '1', 1),
                (60, 127, '2026-10-12T17:00:00+09:00', ?, 'SKY', '-999', NULL)""", hour, hour);
        var v = etlRepository.latestForecast(60, 127, hour.toInstant(), hour.toInstant().plusSeconds(3600), java.util.List.of("SKY"));
        assertEquals(1.0, v.get(hour.toInstant()).get("SKY"));
    }

    /**
     * DB-PLAN C2: the app-facing pack must not change while the storage underneath is reshaped (V5/V6). The hash was
     * recorded with the pre-change code (commit 269d608) for this fixed input; mixed SKY/PTY exercise every branch.
     */
    static final String PACK_JSON_GOLDEN_SHA256 = "e039f859c2a117b2a54f0c7b3fa1a21c98081d7e0cddb506ddbbe5261253c8b6";

    @Test
    void packJsonIsUnchangedByStorageChanges() throws Exception {
        LocalDate night = LocalDate.of(2026, 10, 12);
        for (var r : regions.findActive()) {
            var rows = new java.util.ArrayList<String[]>();
            int[] sky = {1, 1, 3, 4, 1, 3};
            for (int block = 0; block < 6; block++)
                rows.addAll(Fixtures.kmaHours(night.plusDays((18 + block * 10) / 24), (18 + block * 10) % 24, 10,
                        sky[(block + (int) (r.getId() % 3)) % 6], block == 4 && r.getKmaNy() > 100 ? 1 : 0));
            String body = Fixtures.kmaPage("20261012", "1700", r.getKmaNx(), r.getKmaNy(), rows.size(), 1, 1000, rows);
            WM.stubFor(get(urlPathEqualTo("/1360000/VilageFcstInfoService_2.0/getVilageFcst"))
                    .withQueryParam("nx", equalTo(Integer.toString(r.getKmaNx()))).withQueryParam("ny", equalTo(Integer.toString(r.getKmaNy())))
                    .willReturn(aResponse().withBody(body)));
        }
        JobExecution e = run(forecastPipelineJob, "base", "202610121700", "nightDate", "2026-10-12");
        assertEquals(BatchStatus.COMPLETED, e.getStatus(), failures(e));
        String json = PackPublisher.gunzipToString(packStore.get(manifestField("/packs/index/path")).orElseThrow());
        assertTrue(json.contains("\"tmp\":[null,null,null,null,null,null,14.0,"), "slots before 18:00 are null; TMP keeps one decimal");
        assertTrue(json.contains("1.8"), "WSD 1.8 printed exactly");
        assertEquals(PACK_JSON_GOLDEN_SHA256, PackWriter.sha256(json.getBytes(StandardCharsets.UTF_8)), json.substring(0, 400));
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
                        Fixtures.riseSet("{{request.query.locdate}}", "테스트", "{{request.query.latitude}}", "{{request.query.longitude}}", null, null))));
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
