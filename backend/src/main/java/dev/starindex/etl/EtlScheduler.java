package dev.starindex.etl;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.batch.core.job.Job;
import org.springframework.batch.core.job.parameters.JobParametersBuilder;
import org.springframework.batch.core.launch.JobOperator;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.annotation.Configuration;
import org.springframework.scheduling.annotation.EnableScheduling;
import org.springframework.scheduling.annotation.Scheduled;

import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.locks.ReentrantLock;

/**
 * Production schedule (KST), enabled with ETL_SCHEDULE_ENABLED=true:
 * forecast pipeline 15 min after each 단기예보 issue (served from HH:10), KASI rise/set daily, KASI monthly data daily
 * (holidays and substitute holidays are published with a lag). A job never overlaps itself.
 */
@Configuration
@EnableScheduling
@ConditionalOnProperty(name = "starindex.etl.schedule.enabled", havingValue = "true")
public class EtlScheduler {
    private static final Logger log = LoggerFactory.getLogger(EtlScheduler.class);

    private final JobOperator jobs;
    private final Job forecastPipelineJob, astroDailyJob, astroEventsJob;
    private final Map<String, ReentrantLock> locks = new ConcurrentHashMap<>();

    public EtlScheduler(JobOperator jobs, Job forecastPipelineJob, Job astroDailyJob, Job astroEventsJob) {
        this.jobs = jobs;
        this.forecastPipelineJob = forecastPipelineJob;
        this.astroDailyJob = astroDailyJob;
        this.astroEventsJob = astroEventsJob;
    }

    @Scheduled(cron = "0 15 2,5,8,11,14,17,20,23 * * *", zone = "Asia/Seoul")
    void forecast() { run(forecastPipelineJob); }

    @Scheduled(cron = "0 30 0 * * *", zone = "Asia/Seoul")
    void astroDaily() { run(astroDailyJob); }

    @Scheduled(cron = "0 10 1 * * *", zone = "Asia/Seoul")
    void astroEvents() { run(astroEventsJob); }

    void run(Job job) {
        ReentrantLock lock = locks.computeIfAbsent(job.getName(), k -> new ReentrantLock());
        if (!lock.tryLock()) {
            log.warn("{} is still running; skipping this trigger", job.getName());
            return;
        }
        try {
            jobs.start(job, new JobParametersBuilder().addLong("run.at", System.currentTimeMillis()).toJobParameters());
        } catch (Exception e) {
            log.error("{} could not start: {}", job.getName(), e.toString());
        } finally {
            lock.unlock();
        }
    }
}
