package dev.starindex.etl;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.batch.core.configuration.support.MapJobRegistry;
import org.springframework.batch.core.job.Job;
import org.springframework.batch.core.job.JobExecution;
import org.springframework.batch.core.job.parameters.JobParameters;
import org.springframework.batch.core.job.parameters.JobParametersBuilder;
import org.springframework.batch.core.launch.JobOperator;
import org.springframework.batch.core.launch.support.TaskExecutorJobOperator;
import org.springframework.batch.core.repository.JobRepository;
import org.springframework.core.task.SimpleAsyncTaskExecutor;
import org.springframework.core.task.TaskExecutor;
import org.springframework.stereotype.Component;

import java.time.Duration;
import java.time.LocalDateTime;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.regex.Pattern;

/**
 * The one place jobs are started from inside the server: the scheduler (synchronously, on its thread) and the admin
 * API (on a background thread, returning the execution id at once: {@code 202 {executionId}}). A job never runs twice
 * at the same time: an in-process flag per job, plus the JobRepository for runs from another JVM (scripts/etl.sh).
 * A STARTED row older than {@link #STALE_AFTER} is a run that died with its JVM and does not block (Spring Batch
 * never marks those itself).
 */
@Component
public class EtlRunner {
    private static final Logger log = LoggerFactory.getLogger(EtlRunner.class);
    static final Duration STALE_AFTER = Duration.ofHours(3);
    /** Job parameters the admin API may pass (see EtlJobsConfig); values are short dates/times only. */
    public static final Set<String> ADMIN_PARAMS = Set.of("base", "nightDate", "from", "month");
    private static final Pattern PARAM_VALUE = Pattern.compile("[0-9-]{1,16}");

    public static final class AlreadyRunningException extends RuntimeException {
        public AlreadyRunningException(String job) { super(job + " is already running"); }
    }

    private final JobOperator operator;
    private final JobRepository repository;
    private final Map<String, Job> jobs;
    private final Map<String, AtomicBoolean> running = new ConcurrentHashMap<>();
    private final SimpleAsyncTaskExecutor background = new SimpleAsyncTaskExecutor("etl-admin-");

    public EtlRunner(JobOperator operator, JobRepository repository, List<Job> jobs) {
        this.operator = operator;
        this.repository = repository;
        this.jobs = jobs.stream().collect(java.util.stream.Collectors.toUnmodifiableMap(Job::getName, j -> j));
    }

    public Set<String> jobNames() { return jobs.keySet(); }

    public Optional<Job> job(String name) { return Optional.ofNullable(jobs.get(name)); }

    /** Runs in the calling thread; empty when the job is already running (the trigger is skipped). */
    public Optional<JobExecution> runNow(Job job) {
        AtomicBoolean flag = claim(job.getName());
        if (flag == null) {
            log.warn("{} is still running; skipping this trigger", job.getName());
            return Optional.empty();
        }
        try {
            return Optional.of(operator.start(job, uniqueParams(Map.of())));
        } catch (Exception e) {
            log.error("{} could not start: {}", job.getName(), e.toString());
            return Optional.empty();
        } finally {
            flag.set(false);
        }
    }

    /**
     * Starts the job on a background thread and returns its execution (status STARTING) immediately.
     * @throws AlreadyRunningException  the job is running in this JVM or, recently, in another one
     * @throws IllegalArgumentException unknown job, or a parameter outside {@link #ADMIN_PARAMS} / bad value
     */
    public JobExecution startAsync(String name, Map<String, String> params) throws Exception {
        Job job = job(name).orElseThrow(() -> new IllegalArgumentException("unknown job: " + name));
        for (var e : params.entrySet()) {
            if (!ADMIN_PARAMS.contains(e.getKey())) throw new IllegalArgumentException("parameter not allowed: " + e.getKey());
            if (e.getValue() == null || !PARAM_VALUE.matcher(e.getValue()).matches())
                throw new IllegalArgumentException("bad value for " + e.getKey());
        }
        AtomicBoolean flag = claim(name);
        if (flag == null) throw new AlreadyRunningException(name);
        try {
            // Released when the job thread finishes, whatever the outcome.
            TaskExecutor releasing = task -> background.execute(() -> {
                try {
                    task.run();
                } finally {
                    flag.set(false);
                }
            });
            var async = new TaskExecutorJobOperator();
            async.setJobRepository(repository);
            var registry = new MapJobRegistry();
            registry.register(job);
            async.setJobRegistry(registry);
            async.setTaskExecutor(releasing);
            async.afterPropertiesSet();
            return async.start(job, uniqueParams(params));
        } catch (Exception | Error e) {
            flag.set(false);   // never submitted
            throw e;
        }
    }

    /** Null when the job is running here, or another JVM started it less than STALE_AFTER ago. */
    private AtomicBoolean claim(String name) {
        AtomicBoolean flag = running.computeIfAbsent(name, k -> new AtomicBoolean());
        if (!flag.compareAndSet(false, true)) return null;
        try {
            LocalDateTime cutoff = LocalDateTime.now().minus(STALE_AFTER);
            boolean elsewhere = repository.findRunningJobExecutions(name).stream()
                    .anyMatch(e -> e.getCreateTime() != null && e.getCreateTime().isAfter(cutoff));
            if (elsewhere) {
                flag.set(false);
                return null;
            }
        } catch (RuntimeException e) {
            flag.set(false);
            throw e;
        }
        return flag;
    }

    /** Every launch is a new instance: no incrementer (see EtlJobsConfig), a unique run.at instead. */
    private static JobParameters uniqueParams(Map<String, String> params) {
        var b = new JobParametersBuilder();
        params.forEach(b::addString);
        return b.addLong("run.at", System.currentTimeMillis()).toJobParameters();
    }
}
