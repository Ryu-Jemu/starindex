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
        // Fixtures are dated October 2026 and every pipeline ends with retention: pin "now" before them (TimeConfig).
        r.add("starindex.clock.fixed", () -> "2026-10-01T09:00:00+09:00");
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
        jdbc.execute("TRUNCATE etl_api_call, kma_forecast_hour, kasi_riseset, astro_crosscheck, "
                + "kasi_astro_event, kasi_special_day, kasi_lunar_day, star_index_nightly, data_pack");
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

    static StepExecution step(JobExecution e, String name) {
        return e.getStepExecutions().stream().filter(s -> s.getStepName().equals(name)).findFirst().orElseThrow();
    }

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
        var fetch = step(e, "forecastFetch");
        assertEquals(17, fetch.getWriteCount(), "cells stored");
        assertEquals(0, fetch.getFilterCount(), "cells failed");
        assertEquals(17 * 60, count("kma_forecast_hour"), "one row per cell and hour, six items only");
        assertEquals(0, jdbc.queryForObject("SELECT COUNT(*) FROM etl_api_call WHERE result_msg IS NOT NULL", Integer.class),
                "successful calls keep no message");
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
        assertEquals(17 * 60, count("kma_forecast_hour"));
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
    void anUnreachableDataGoKrStopsAfterTwoCellsInsteadOfWaitingForAll() throws Exception {
        // A blocked network path (data.go.kr refusing an overseas runner): the connection is reset on every call.
        WM.stubFor(get(urlPathEqualTo("/1360000/VilageFcstInfoService_2.0/getVilageFcst"))
                .willReturn(aResponse().withFault(com.github.tomakehurst.wiremock.http.Fault.CONNECTION_RESET_BY_PEER)));
        JobExecution e = run(forecastPipelineJob, "base", "202610121700", "nightDate", "2026-10-12");
        assertEquals(BatchStatus.FAILED, e.getStatus());
        assertTrue(failures(e).contains("data.go.kr에 연결할 수 없습니다"), failures(e));
        long cellsTried = WM.getAllServeEvents().stream()
                .map(ev -> ev.getRequest().queryParameter("nx").firstValue() + "," + ev.getRequest().queryParameter("ny").firstValue())
                .distinct().count();
        assertEquals(ForecastIngestService.UNREACHABLE_AFTER, cellsTried, "stopped early instead of trying all 17 cells");
    }

    @Test
    void malformedParametersStopWithTheExpectedFormat() throws Exception {
        JobExecution e = run(forecastIngestJob, "base", "2026101217");
        assertEquals(BatchStatus.FAILED, e.getStatus());
        assertTrue(failures(e).contains("base=2026101217 형식이 틀렸습니다"), failures(e));
        assertEquals(0, WM.getAllServeEvents().size());
    }

    /**
     * DB-PLAN C2: the app-facing pack must not change while the storage underneath is reshaped (V5/V6). The hash was
     * recorded with the pre-change code (commit 269d608) for this fixed input; mixed SKY/PTY exercise every branch.
     */
    static final String PACK_JSON_GOLDEN_SHA256 = "e95eda135a3e3743832f2f3a44d77b7a74ca5c189badc3ac4eeb2fd0dfebb79b";

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
        // Contract files first: with UPDATE_GOLDEN=1 they are rewritten, then the pinned hash below must be updated too.
        assertMatchesContract(json, packStore.get(manifestField("/packs/index/path")).orElseThrow());
        assertEquals(PACK_JSON_GOLDEN_SHA256, PackWriter.sha256(json.getBytes(StandardCharsets.UTF_8)), json.substring(0, 400));
    }

    /**
     * contracts/golden/ is the app-facing contract: SkyCore's IndexPack tests decode these exact files. Regenerate with
     * {@code UPDATE_GOLDEN=1 ./gradlew test --tests '*EtlJobsIntegrationTest.packJsonIsUnchangedByStorageChanges'}.
     */
    void assertMatchesContract(String json, byte[] gz) throws Exception {
        Path dir = Path.of("../contracts/golden");
        Path packJson = dir.resolve("index-pack-v2.json"), packGz = dir.resolve("index-pack-v2.json.gz"),
                manifest = dir.resolve("manifest-v1.json");
        // generatedAt is the publish wall clock; the contract file carries a fixed one.
        var mapper = JsonMapper.builder().build();
        var m = (tools.jackson.databind.node.ObjectNode) mapper.readTree(packStore.get(PackPublisher.MANIFEST_PATH).orElseThrow());
        m.put("generatedAt", "2026-10-12T17:21:04+09:00");
        String manifestJson = mapper.writerWithDefaultPrettyPrinter().writeValueAsString(m) + "\n";
        if (System.getenv("UPDATE_GOLDEN") != null) {
            Files.createDirectories(dir);
            Files.writeString(packJson, json);
            Files.write(packGz, gz);
            Files.writeString(manifest, manifestJson);
        }
        assertEquals(Files.readString(packJson), json, "contracts/golden/index-pack-v2.json");
        assertEquals(json, PackPublisher.gunzipToString(Files.readAllBytes(packGz)), "contracts/golden/index-pack-v2.json.gz");
        assertEquals(Files.readString(manifest), manifestJson, "contracts/golden/manifest-v1.json");
        assertEquals(PackWriter.sha256(gz), m.at("/packs/index/sha256").asString());
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
        assertEquals(0, count("kma_forecast_hour"));
        assertEquals(1, count("etl_api_call"));
        assertEquals("SERVICE_KEY_IS_NOT_REGISTERED_ERROR", jdbc.queryForObject("SELECT result_msg FROM etl_api_call", String.class),
                "a failure keeps its reason");
    }

    @Test
    void incompleteForecastFailsTheCompletenessGate() throws Exception {
        stubForecastForAllCells("20261012", "1700", LocalDate.of(2026, 10, 12), 1, 0);
        WM.stubFor(get(urlPathEqualTo("/1360000/VilageFcstInfoService_2.0/getVilageFcst")).withQueryParam("nx", equalTo("60"))
                .atPriority(1).willReturn(aResponse().withStatus(502).withBody("upstream down")));
        JobExecution e = run(forecastIngestJob, "base", "202610121700");
        assertEquals(BatchStatus.FAILED, e.getStatus());
        assertTrue(failures(e).contains("완결성 미달"), failures(e));
        assertEquals(15, jdbc.queryForObject("SELECT COUNT(DISTINCT (nx, ny)) FROM kma_forecast_hour", Integer.class),
                "서울(60,127)과 경기(60,120)만 실패하고 나머지는 저장");
        var fetch = step(e, "forecastFetch");
        assertEquals(15, fetch.getWriteCount());
        assertEquals(2, fetch.getFilterCount());
    }

    @Test
    void aRetentionWarningDoesNotStopTheDailyJob() throws Exception {
        org.junit.jupiter.api.Assumptions.assumeFalse("root".equals(System.getProperty("user.name")), "root ignores directory permissions");
        WM.stubFor(get(urlPathEqualTo("/B090041/openapi/service/RiseSetInfoService/getLCRiseSetInfo"))
                .willReturn(aResponse().withHeader("Content-Type", "application/xml").withBody(
                        Fixtures.riseSet("{{request.query.locdate}}", "테스트", "{{request.query.latitude}}", "{{request.query.longitude}}", null, null))));
        var now = java.time.Instant.now();
        for (int i = 0; i < 4; i++) {   // four old index packs: only the oldest falls outside the newest three
            String path = "packs/index/old" + i + "/index.json.gz";
            packStore.put(path, new byte[]{1}, "application/gzip", PackStore.IMMUTABLE);
            jdbc.update("INSERT INTO data_pack (kind, version, path, sha256, bytes, published_at) VALUES ('index', ?, ?, ?, 1, ?)",
                    "old" + i, path, "0".repeat(64), java.time.OffsetDateTime.ofInstant(now.minus(java.time.Duration.ofDays(20 - i)), java.time.ZoneOffset.UTC));
        }
        java.io.File locked = PACKS.resolve("packs/index/old0").toFile();
        assertTrue(locked.setWritable(false));
        try {
            JobExecution e = run(astroDailyJob, "from", "2026-09-29");
            assertEquals(BatchStatus.COMPLETED, e.getStatus(), failures(e));
            assertEquals("COMPLETED_WITH_WARNINGS", step(e, "retention").getExitStatus().getExitCode());
            assertEquals(BatchStatus.COMPLETED, step(e, "kasiRiseSet").getStatus(), "later steps still run");
            assertEquals(BatchStatus.COMPLETED, step(e, "crosscheck").getStatus());
            assertEquals(4, count("data_pack"), "the row stays for tomorrow's retry");
        } finally {
            locked.setWritable(true);
        }
    }

    @Test
    void astroDailyStoresKasiTimesAndCrossChecksAgainstAstronomyEngine() throws Exception {
        WM.stubFor(get(urlPathEqualTo("/B090041/openapi/service/RiseSetInfoService/getLCRiseSetInfo"))
                .willReturn(aResponse().withHeader("Content-Type", "application/xml").withBody(
                        Fixtures.riseSet("{{request.query.locdate}}", "테스트", "{{request.query.latitude}}", "{{request.query.longitude}}", null, null))));
        JobExecution e = run(astroDailyJob, "from", "2026-09-29");
        assertEquals(BatchStatus.COMPLETED, e.getStatus(), failures(e));
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
