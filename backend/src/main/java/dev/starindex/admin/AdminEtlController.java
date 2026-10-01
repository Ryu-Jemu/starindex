package dev.starindex.admin;

import org.springframework.boot.autoconfigure.condition.ConditionalOnWebApplication;
import dev.starindex.astro.AstroCalculator;
import dev.starindex.datagokr.ApiSource;
import dev.starindex.datagokr.DataGoKrProperties;
import dev.starindex.etl.EtlRunner;
import dev.starindex.pack.PackPublisher;
import dev.starindex.pack.PackStore;
import org.springframework.batch.core.BatchStatus;
import org.springframework.batch.core.job.JobExecution;
import org.springframework.batch.core.repository.JobRepository;
import org.springframework.batch.core.step.StepExecution;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.time.LocalDate;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeSet;

/** Admin ETL operations (PLAN 3.4): run history, one run's steps, start a job, the live manifest, API quota. */
@ConditionalOnWebApplication(type = ConditionalOnWebApplication.Type.SERVLET)
@RestController
@RequestMapping("/api/admin")
public class AdminEtlController {
    private final EtlRunQueryRepository runs;
    private final EtlRunner runner;
    private final JobRepository jobRepository;
    private final PackStore packs;
    private final StringRedisTemplate redis;
    private final DataGoKrProperties dataGoKr;

    public AdminEtlController(EtlRunQueryRepository runs, EtlRunner runner, JobRepository jobRepository, PackStore packs,
                              StringRedisTemplate redis, DataGoKrProperties dataGoKr) {
        this.runs = runs;
        this.runner = runner;
        this.jobRepository = jobRepository;
        this.packs = packs;
        this.redis = redis;
        this.dataGoKr = dataGoKr;
    }

    public record RunRequest(Map<String, String> params) {}

    @GetMapping("/etl/jobs")
    public Map<String, Object> jobs() {
        // Batch stores LocalDateTime in the JVM zone (UTC on EC2): the page labels times with it.
        return Map.of("jobs", new TreeSet<>(runner.jobNames()), "params", new TreeSet<>(EtlRunner.ADMIN_PARAMS),
                "serviceKey", dataGoKr.hasServiceKey(), "serverZone", java.time.ZoneId.systemDefault().getId());
    }

    /**
     * @param job    one of the server's job names, else 400
     * @param status a BatchStatus name (COMPLETED, FAILED, STARTED, …), else 400
     * @param since  yyyy-MM-dd (server local date), runs created on or after it
     */
    @GetMapping("/etl/runs")
    public ResponseEntity<?> runs(@RequestParam(required = false) String job,
                                  @RequestParam(required = false) String status,
                                  @RequestParam(required = false) String since,
                                  @RequestParam(defaultValue = "NEWEST") String sort,
                                  @RequestParam(defaultValue = "0") int page,
                                  @RequestParam(defaultValue = "20") int size) {
        String jobName = blank(job) ? null : job;
        if (jobName != null && !runner.jobNames().contains(jobName)) return bad("unknown job: " + job);
        BatchStatus st;
        EtlRunQueryRepository.SortKey sortKey;
        LocalDate day;
        try {
            st = blank(status) ? null : BatchStatus.valueOf(status);
            sortKey = EtlRunQueryRepository.SortKey.valueOf(sort);
            day = blank(since) ? null : LocalDate.parse(since);
        } catch (RuntimeException e) {
            return bad("bad filter: status=" + status + ", sort=" + sort + ", since=" + since);
        }
        if (page < 0 || size < 1 || size > 100) return bad("page >= 0, 1 <= size <= 100");
        var filter = new EtlRunQueryRepository.Filter(jobName, st, day == null ? null : day.atStartOfDay());
        return ResponseEntity.ok(runs.find(filter, sortKey, page, size));
    }

    @GetMapping("/etl/runs/{id}")
    public ResponseEntity<?> run(@PathVariable long id) {
        JobExecution e = jobRepository.getJobExecution(id);
        if (e == null) return ResponseEntity.notFound().build();
        List<Map<String, Object>> steps = new ArrayList<>();
        for (StepExecution s : e.getStepExecutions()) {
            Map<String, Object> m = new LinkedHashMap<>();
            m.put("name", s.getStepName());
            m.put("status", s.getStatus().name());
            m.put("exitCode", s.getExitStatus().getExitCode());
            m.put("startTime", s.getStartTime());
            m.put("endTime", s.getEndTime());
            m.put("writeCount", s.getWriteCount());
            m.put("filterCount", s.getFilterCount());
            m.put("summary", e.getExecutionContext().getString("summary." + s.getStepName(), null));
            m.put("exitDescription", truncate(s.getExitStatus().getExitDescription(), 2000));
            steps.add(m);
        }
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("id", e.getId());
        out.put("jobName", e.getJobInstance().getJobName());
        out.put("status", e.getStatus().name());
        out.put("exitCode", e.getExitStatus().getExitCode());
        out.put("createTime", e.getCreateTime());
        out.put("startTime", e.getStartTime());
        out.put("endTime", e.getEndTime());
        Map<String, String> params = new LinkedHashMap<>();
        e.getJobParameters().parameters().forEach(p -> params.put(p.name(), String.valueOf(p.value())));
        out.put("params", params);
        out.put("steps", steps);
        out.put("failures", e.getAllFailureExceptions().stream().map(t -> truncate(rootMessage(t), 500)).toList());
        return ResponseEntity.ok(out);
    }

    /** 202 {executionId} at once; 409 while the same job runs; 400 for an unknown job or parameter. */
    @PostMapping("/etl/jobs/{name}/run")
    public ResponseEntity<?> start(@PathVariable String name, @RequestBody(required = false) RunRequest body) throws Exception {
        try {
            JobExecution e = runner.startAsync(name, body == null || body.params() == null ? Map.of() : body.params());
            return ResponseEntity.accepted().body(Map.of("executionId", e.getId()));
        } catch (EtlRunner.AlreadyRunningException e) {
            return ResponseEntity.status(HttpStatus.CONFLICT).body(Map.of("error", name + " 이(가) 이미 실행 중입니다"));
        } catch (IllegalArgumentException e) {
            return bad(e.getMessage());
        }
    }

    /** The live manifest exactly as the app downloads it (S3 packs/manifest/latest.json is the single source). */
    @GetMapping(value = "/packs/manifest", produces = MediaType.APPLICATION_JSON_VALUE)
    public ResponseEntity<byte[]> manifest() {
        return packs.get(PackPublisher.MANIFEST_PATH).map(ResponseEntity::ok).orElseGet(() -> ResponseEntity.notFound().build());
    }

    /** Today's (KST) data.go.kr calls counted by the local quota guard, per API. */
    @GetMapping("/quota")
    public Map<String, Object> quota() {
        String day = LocalDate.now(AstroCalculator.KST).format(DateTimeFormatter.BASIC_ISO_DATE);
        Map<String, Object> used = new LinkedHashMap<>();
        for (ApiSource s : ApiSource.values()) {
            String v = redis.opsForValue().get("quota:" + s.name().toLowerCase() + ":" + day);
            used.put(s.name(), v == null ? 0 : Long.parseLong(v));
        }
        return Map.of("day", day, "dailyQuota", dataGoKr.dailyQuota(), "used", used);
    }

    private static ResponseEntity<Map<String, String>> bad(String message) {
        return ResponseEntity.badRequest().body(Map.of("error", message));
    }

    private static boolean blank(String s) { return s == null || s.isBlank(); }

    private static String rootMessage(Throwable t) {
        Throwable r = t;
        while (r.getCause() != null && r.getCause() != r) r = r.getCause();
        return r.getMessage() != null ? r.getMessage() : r.toString();
    }

    private static String truncate(String s, int max) { return s == null || s.length() <= max ? s : s.substring(0, max) + "…"; }
}
