package dev.starindex.etl;

import dev.starindex.IntegrationTestBase;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.batch.core.BatchStatus;
import org.springframework.batch.core.job.Job;
import org.springframework.batch.core.job.JobExecution;
import org.springframework.batch.core.job.parameters.JobParametersBuilder;
import org.springframework.batch.core.launch.JobOperator;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.TestPropertySource;

import java.util.stream.Collectors;

import static org.junit.jupiter.api.Assertions.*;

/** Before the key arrives: key-dependent jobs stop with guidance, Astronomy Engine work still completes. */
@TestPropertySource(properties = {"starindex.data-go-kr.service-key=", "starindex.data-go-kr.base-url=http://127.0.0.1:9"})
class EtlWithoutKeyTest extends IntegrationTestBase {
    @Autowired JobOperator jobs;
    @Autowired JdbcTemplate jdbc;
    @Autowired @Qualifier("forecastIngestJob") Job forecastIngestJob;
    @Autowired @Qualifier("astroDailyJob") Job astroDailyJob;
    @Autowired @Qualifier("apiKeyCheckJob") Job apiKeyCheckJob;

    @BeforeEach
    void clean() {
        jdbc.execute("TRUNCATE etl_api_call, kasi_riseset, astro_night, astro_crosscheck");
    }

    JobExecution run(Job job, String... kv) throws Exception {
        var b = new JobParametersBuilder().addLong("run", System.nanoTime());
        for (int i = 0; i < kv.length; i += 2) b.addString(kv[i], kv[i + 1]);
        return jobs.start(job, b.toJobParameters());
    }

    @Test
    void keyDependentJobsStopWithGuidance() throws Exception {
        for (Job job : new Job[]{forecastIngestJob, apiKeyCheckJob}) {
            JobExecution e = run(job);
            assertEquals(BatchStatus.FAILED, e.getStatus(), job.getName());
            String msg = e.getAllFailureExceptions().stream().map(Throwable::getMessage).collect(Collectors.joining());
            assertTrue(msg.contains("DATA_GO_KR_SERVICE_KEY"), msg);
        }
        assertEquals(0, jdbc.queryForObject("SELECT COUNT(*) FROM etl_api_call", Integer.class), "no call without a key");
    }

    @Test
    void dailyRetentionDropsOldForecastsAndAudit() throws Exception {
        jdbc.execute("TRUNCATE kma_forecast_hour");
        jdbc.update("""
                INSERT INTO kma_forecast_hour (nx, ny, fcst_at, base_at, sky) VALUES
                (60, 127, now() - interval '29 days', now() - interval '30 days', 1),
                (60, 127, now(), now() - interval '1 day', 3)""");
        jdbc.update("INSERT INTO etl_api_call (source, operation, request_key, duration_ms, outcome, called_at) "
                + "VALUES ('KMA_VILAGE', 'getVilageFcst', 'old', 1, 'OK', now() - interval '200 days')");
        assertEquals(BatchStatus.COMPLETED, run(astroDailyJob).getStatus());
        assertEquals(1, jdbc.queryForObject("SELECT COUNT(*) FROM kma_forecast_hour", Integer.class));
        assertEquals(0, jdbc.queryForObject("SELECT COUNT(*) FROM etl_api_call", Integer.class));
    }

    @Test
    void astroDailyStillComputesWithoutKey() throws Exception {
        JobExecution e = run(astroDailyJob, "from", "2026-10-12");
        assertEquals(BatchStatus.COMPLETED, e.getStatus());
        assertEquals(17 * 4, jdbc.queryForObject("SELECT COUNT(*) FROM astro_night", Integer.class));
        assertEquals(0, jdbc.queryForObject("SELECT COUNT(*) FROM kasi_riseset", Integer.class));
        assertEquals(2, e.getStepExecutions().size(), "retention + astroCompute, then the decider ends the job");
    }
}
