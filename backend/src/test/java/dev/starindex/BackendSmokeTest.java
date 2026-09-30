package dev.starindex;

import dev.starindex.geo.KmaGrid;
import dev.starindex.region.Region;
import dev.starindex.region.RegionQueryRepository;
import org.junit.jupiter.api.Test;
import org.springframework.batch.core.BatchStatus;
import org.springframework.batch.core.job.Job;
import org.springframework.batch.core.job.JobExecution;
import org.springframework.batch.core.job.parameters.JobParametersBuilder;
import org.springframework.batch.core.launch.JobOperator;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.jdbc.core.JdbcTemplate;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** Batch JDBC repository + Flyway (PostgreSQL 18) + QueryDSL + region seed. */
class BackendSmokeTest extends IntegrationTestBase {

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
        String version = jdbc.queryForObject("SHOW server_version", String.class);
        assertTrue(version != null && version.startsWith("18"), "PostgreSQL version " + version);
    }

    @Test
    void regionSeedIsTheOfficialGridSheetAndMatchesKmaGrid() {
        var all = regions.findActive();
        assertEquals(17, all.size());
        assertEquals(16, all.stream().filter(r -> r.getKind() == Region.Kind.SIDO).count());
        var seoul = regions.findBySido("서울특별시").getFirst();
        assertEquals(60, seoul.getKmaNx());
        assertEquals(127, seoul.getKmaNy());
        for (Region r : all) {
            var cell = KmaGrid.toGrid(r.getLat(), r.getLon()).orElseThrow();
            assertEquals(new KmaGrid.Cell(r.getKmaNx(), r.getKmaNy()), cell, r.getNameKo());
        }
        assertEquals(17, regions.findAll(RegionQueryRepository.SortKey.NAME).size());
    }
}
