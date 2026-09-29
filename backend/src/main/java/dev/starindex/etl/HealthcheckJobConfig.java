package dev.starindex.etl;

import org.springframework.batch.core.job.Job;
import org.springframework.batch.core.job.builder.JobBuilder;
import org.springframework.batch.core.repository.JobRepository;
import org.springframework.batch.core.step.Step;
import org.springframework.batch.core.step.builder.StepBuilder;
import org.springframework.batch.infrastructure.repeat.RepeatStatus;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.transaction.PlatformTransactionManager;

/**
 * Smoke job for the W2 definition of done: running it must create a row in
 * BATCH_JOB_EXECUTION (i.e. the JDBC JobRepository from spring-boot-starter-batch-jdbc is active).
 */
@Configuration
public class HealthcheckJobConfig {

    @Bean
    Job healthcheckJob(JobRepository jobRepository, Step healthcheckStep) {
        return new JobBuilder("healthcheckJob", jobRepository).start(healthcheckStep).build();
    }

    @Bean
    Step healthcheckStep(JobRepository jobRepository, PlatformTransactionManager tx) {
        return new StepBuilder("healthcheckStep", jobRepository)
                .tasklet((contribution, context) -> RepeatStatus.FINISHED, tx)
                .build();
    }
}
