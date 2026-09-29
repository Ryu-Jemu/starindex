package dev.starindex;

import dev.starindex.region.RegionQueryRepository;
import org.junit.jupiter.api.Test;
import org.springframework.batch.core.BatchStatus;
import org.springframework.batch.core.job.Job;
import org.springframework.batch.core.job.JobExecution;
import org.springframework.batch.core.job.parameters.JobParametersBuilder;
import org.springframework.batch.core.launch.JobOperator;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.testcontainers.service.connection.ServiceConnection;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.transaction.annotation.Transactional;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.mysql.MySQLContainer;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** W2 definition of done: Batch JDBC repository + Flyway + QueryDSL on MySQL 8.4. */
@SpringBootTest(properties = "spring.data.redis.repositories.enabled=false")
@Testcontainers
class BackendSmokeTest {

    @Container
    @ServiceConnection
    static MySQLContainer mysql = new MySQLContainer("mysql:8.4");

    @Autowired JobOperator jobOperator;
    @Autowired Job healthcheckJob;
    @Autowired JdbcTemplate jdbc;
    @Autowired RegionQueryRepository regions;

    @Test
    void healthcheckJobWritesBatchJobExecution() throws Exception {
        JobExecution exec = jobOperator.start(healthcheckJob,
                new JobParametersBuilder().addLong("run", System.nanoTime()).toJobParameters());
        assertEquals(BatchStatus.COMPLETED, exec.getStatus());
        Integer rows = jdbc.queryForObject("SELECT COUNT(*) FROM BATCH_JOB_EXECUTION", Integer.class);
        assertTrue(rows != null && rows >= 1, "BATCH_JOB_EXECUTION rows: " + rows);
    }

    @Test
    @Transactional
    void queryDslReadsSeededRegion() {
        var seoul = regions.findBySido("서울특별시");
        assertEquals(1, seoul.size());
        assertEquals(60, seoul.getFirst().getKmaNx());
        assertEquals(127, seoul.getFirst().getKmaNy());
        assertEquals(1, regions.findAll(RegionQueryRepository.SortKey.NAME).size());
    }
}
