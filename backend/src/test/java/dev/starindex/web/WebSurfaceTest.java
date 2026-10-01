package dev.starindex.web;

import dev.starindex.IntegrationTestBase;
import org.junit.jupiter.api.Test;
import org.springframework.batch.core.job.Job;
import org.springframework.batch.core.job.builder.JobBuilder;
import org.springframework.batch.core.repository.JobRepository;
import org.springframework.batch.core.step.builder.StepBuilder;
import org.springframework.batch.infrastructure.repeat.RepeatStatus;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.http.MediaType;
import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.MvcResult;
import org.springframework.test.web.servlet.request.MockHttpServletRequestBuilder;
import org.springframework.test.web.servlet.request.RequestPostProcessor;
import org.springframework.transaction.PlatformTransactionManager;
import tools.jackson.databind.json.JsonMapper;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

/**
 * Port 8080's two audiences (PLAN 3.4 보안 필터): CloudFront with X-Origin-Verify gets health, /api/v1 and /ws/v1
 * only; the SSM tunnel (loopback) gets the admin page and, with a JWT, /api/admin. Everyone else gets 403.
 */
@AutoConfigureMockMvc
@Import(WebSurfaceTest.SlowJobConfig.class)
class WebSurfaceTest extends IntegrationTestBase {
    static final String SECRET = "test-origin-secret-0123456789abcdef";
    static final String PASSWORD = "correct horse battery staple";
    static final CountDownLatch RELEASE = new CountDownLatch(1);

    @DynamicPropertySource
    static void props(DynamicPropertyRegistry r) {
        r.add("starindex.security.origin-verify-secret", () -> SECRET);
        r.add("starindex.admin.password-hash", () -> new BCryptPasswordEncoder(4).encode(PASSWORD));
    }

    /** A job that waits for the test, to observe "already running" (409). */
    @TestConfiguration
    static class SlowJobConfig {
        @Bean
        Job slowTestJob(JobRepository repo, PlatformTransactionManager tx) {
            return new JobBuilder("slowTestJob", repo).start(new StepBuilder("waitForTest", repo).tasklet((c, ctx) -> {
                if (!RELEASE.await(30, TimeUnit.SECONDS)) throw new IllegalStateException("test never released the job");
                return RepeatStatus.FINISHED;
            }, tx).build()).build();
        }
    }

    @Autowired MockMvc mvc;
    final JsonMapper json = JsonMapper.builder().build();

    static RequestPostProcessor from(String ip) {
        return r -> { r.setRemoteAddr(ip); return r; };
    }

    static MockHttpServletRequestBuilder viaCloudFront(MockHttpServletRequestBuilder b) {
        return b.header("X-Origin-Verify", SECRET).with(from("13.124.199.10"));
    }

    // ---------------------------------------------------------------- origin filter

    @Test
    void healthIsUpWithoutTouchingTheDatabase() throws Exception {
        mvc.perform(get("/api/health")).andExpect(status().isOk()).andExpect(jsonPath("$.status").value("UP"));
        mvc.perform(viaCloudFront(get("/api/health"))).andExpect(status().isOk());
    }

    @Test
    void directInternetTrafficIsRefusedEvenWithAForgedForwardedFor() throws Exception {
        mvc.perform(get("/api/health").with(from("198.51.100.7"))).andExpect(status().isForbidden());
        mvc.perform(get("/api/health").with(from("198.51.100.7")).header("X-Forwarded-For", "127.0.0.1")
                .header("Forwarded", "for=127.0.0.1")).andExpect(status().isForbidden());
        mvc.perform(get("/admin/index.html").with(from("198.51.100.7"))).andExpect(status().isForbidden());
    }

    @Test
    void wrongOriginSecretIsRefused() throws Exception {
        mvc.perform(get("/api/health").header("X-Origin-Verify", "nope").with(from("13.124.199.10"))).andExpect(status().isForbidden());
        mvc.perform(get("/api/health").header("X-Origin-Verify", SECRET + "x").with(from("13.124.199.10"))).andExpect(status().isForbidden());
    }

    @Test
    void cloudFrontNeverReachesAdminPaths() throws Exception {
        String token = login("127.0.0.11");
        mvc.perform(viaCloudFront(get("/admin"))).andExpect(status().isForbidden());
        mvc.perform(viaCloudFront(get("/admin/index.html"))).andExpect(status().isForbidden());
        mvc.perform(viaCloudFront(post("/api/admin/auth/login").contentType(MediaType.APPLICATION_JSON)
                .content("{\"username\":\"admin\",\"password\":\"" + PASSWORD + "\"}"))).andExpect(status().isForbidden());
        mvc.perform(viaCloudFront(get("/api/admin/etl/runs")).header("Authorization", "Bearer " + token)).andExpect(status().isForbidden());
        mvc.perform(viaCloudFront(get("/api/v1/../admin/index.html"))).andExpect(status().isForbidden());
        mvc.perform(viaCloudFront(get("/api/v1/%2e%2e/admin/index.html"))).andExpect(status().isForbidden());
        mvc.perform(viaCloudFront(get("/api/v1;x/admin"))).andExpect(status().isForbidden());
        mvc.perform(viaCloudFront(get("/actuator/health"))).andExpect(status().isForbidden());
    }

    @Test
    void adminPageIsServedOverTheTunnelWithACsp() throws Exception {
        mvc.perform(get("/admin")).andExpect(status().isOk()).andExpect(forwardedUrl("/admin/index.html"));
        MvcResult page = mvc.perform(get("/admin/index.html")).andExpect(status().isOk())
                .andExpect(header().string("Content-Security-Policy", org.hamcrest.Matchers.containsString("frame-ancestors 'none'")))
                .andReturn();
        assertTrue(page.getResponse().getContentAsString(java.nio.charset.StandardCharsets.UTF_8).contains("별 지수 관리자"));
        mvc.perform(get("/admin/admin.js")).andExpect(status().isOk());
    }

    // ---------------------------------------------------------------- auth

    @Test
    void adminApiNeedsAToken() throws Exception {
        mvc.perform(get("/api/admin/etl/runs")).andExpect(status().isUnauthorized());
        mvc.perform(get("/api/admin/etl/runs").header("Authorization", "Bearer not.a.jwt")).andExpect(status().isUnauthorized());
    }

    @Test
    void wrongPasswordsLockTheAddressForFifteenMinutes() throws Exception {
        String ip = "127.0.0.21";
        for (int i = 0; i < 5; i++)
            mvc.perform(loginRequest("admin", "wrong", ip)).andExpect(status().isUnauthorized());
        mvc.perform(loginRequest("admin", PASSWORD, ip)).andExpect(status().isTooManyRequests())
                .andExpect(header().string("Retry-After", "900"));
        mvc.perform(loginRequest("someone", PASSWORD, "127.0.0.22")).andExpect(status().isUnauthorized());
    }

    @Test
    void logoutRevokesTheToken() throws Exception {
        String token = login("127.0.0.31");
        mvc.perform(get("/api/admin/quota").header("Authorization", "Bearer " + token)).andExpect(status().isOk())
                .andExpect(jsonPath("$.used.KMA_VILAGE").exists());
        mvc.perform(post("/api/admin/auth/logout").header("Authorization", "Bearer " + token)).andExpect(status().isNoContent());
        mvc.perform(get("/api/admin/quota").header("Authorization", "Bearer " + token)).andExpect(status().isUnauthorized());
    }

    // ---------------------------------------------------------------- ETL operations

    @Test
    void runsAJobOnceAndRefusesASecondConcurrentRun() throws Exception {
        String auth = "Bearer " + login("127.0.0.41");
        MvcResult started = mvc.perform(post("/api/admin/etl/jobs/slowTestJob/run").header("Authorization", auth))
                .andExpect(status().isAccepted()).andReturn();
        long id = json.readTree(started.getResponse().getContentAsString()).get("executionId").asLong();
        mvc.perform(post("/api/admin/etl/jobs/slowTestJob/run").header("Authorization", auth)).andExpect(status().isConflict());
        RELEASE.countDown();
        String st = waitForEnd(auth, id);
        assertEquals("COMPLETED", st);
        mvc.perform(get("/api/admin/etl/runs").param("job", "slowTestJob").param("status", "COMPLETED").header("Authorization", auth))
                .andExpect(status().isOk()).andExpect(jsonPath("$.runs[0].id").value(id))
                .andExpect(jsonPath("$.runs[0].jobName").value("slowTestJob"));
        mvc.perform(get("/api/admin/etl/runs/" + id).header("Authorization", auth)).andExpect(status().isOk())
                .andExpect(jsonPath("$.steps[0].name").value("waitForTest"))
                .andExpect(jsonPath("$.params['run.at']").exists());
        // The flag is released when the job thread ends: the next run starts.
        mvc.perform(post("/api/admin/etl/jobs/healthcheckJob/run").header("Authorization", auth)).andExpect(status().isAccepted());
    }

    @Test
    void filtersAndJobNamesAreWhitelisted() throws Exception {
        String auth = "Bearer " + login("127.0.0.51");
        mvc.perform(get("/api/admin/etl/runs").param("job", "bogusJob").header("Authorization", auth)).andExpect(status().isBadRequest());
        mvc.perform(get("/api/admin/etl/runs").param("status", "DONE").header("Authorization", auth)).andExpect(status().isBadRequest());
        mvc.perform(get("/api/admin/etl/runs").param("sort", "id desc; drop table x").header("Authorization", auth)).andExpect(status().isBadRequest());
        mvc.perform(get("/api/admin/etl/runs").param("size", "101").header("Authorization", auth)).andExpect(status().isBadRequest());
        mvc.perform(get("/api/admin/etl/runs").param("since", "2026-13-01").header("Authorization", auth)).andExpect(status().isBadRequest());
        mvc.perform(post("/api/admin/etl/jobs/bogusJob/run").header("Authorization", auth)).andExpect(status().isBadRequest());
        mvc.perform(post("/api/admin/etl/jobs/healthcheckJob/run").header("Authorization", auth).contentType(MediaType.APPLICATION_JSON)
                .content("{\"params\":{\"evil\":\"1\"}}")).andExpect(status().isBadRequest());
        mvc.perform(post("/api/admin/etl/jobs/healthcheckJob/run").header("Authorization", auth).contentType(MediaType.APPLICATION_JSON)
                .content("{\"params\":{\"nightDate\":\"2026-10-12'; --\"}}")).andExpect(status().isBadRequest());
        mvc.perform(get("/api/admin/etl/jobs").header("Authorization", auth)).andExpect(status().isOk())
                .andExpect(jsonPath("$.jobs").isArray()).andExpect(jsonPath("$.serverZone").exists());
    }

    // ---------------------------------------------------------------- helpers

    MockHttpServletRequestBuilder loginRequest(String user, String password, String ip) {
        return post("/api/admin/auth/login").with(from(ip)).contentType(MediaType.APPLICATION_JSON)
                .content(json.writeValueAsString(java.util.Map.of("username", user, "password", password)));
    }

    String login(String ip) throws Exception {
        MvcResult r = mvc.perform(loginRequest("admin", PASSWORD, ip)).andExpect(status().isOk()).andReturn();
        return json.readTree(r.getResponse().getContentAsString()).get("token").asString();
    }

    String waitForEnd(String auth, long id) throws Exception {
        long until = System.currentTimeMillis() + 20_000;
        while (System.currentTimeMillis() < until) {
            MvcResult r = mvc.perform(get("/api/admin/etl/runs/" + id).header("Authorization", auth)).andReturn();
            String st = json.readTree(r.getResponse().getContentAsString()).get("status").asString();
            if (!st.equals("STARTING") && !st.equals("STARTED")) return st;
            Thread.sleep(100);
        }
        fail("job " + id + " did not finish");
        return null;
    }
}
