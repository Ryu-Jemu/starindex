package dev.starindex.etl;

import dev.starindex.astro.AstroCalculator;
import dev.starindex.datagokr.DataGoKrException;
import dev.starindex.datagokr.DataGoKrProperties;
import dev.starindex.etl.kma.KmaBaseTime;
import dev.starindex.index.IndexService;
import dev.starindex.pack.LocalPackStore;
import dev.starindex.pack.PackPublisher;
import dev.starindex.pack.PackStore;
import org.springframework.batch.core.ExitStatus;
import org.springframework.batch.core.job.Job;
import org.springframework.batch.core.job.builder.JobBuilder;
import org.springframework.batch.core.job.flow.FlowExecutionStatus;
import org.springframework.batch.core.job.flow.JobExecutionDecider;
import org.springframework.batch.core.job.parameters.JobParameters;
import org.springframework.batch.core.repository.JobRepository;
import org.springframework.batch.core.step.Step;
import org.springframework.batch.core.step.StepContribution;
import org.springframework.batch.core.step.builder.StepBuilder;
import org.springframework.batch.infrastructure.repeat.RepeatStatus;
import org.springframework.batch.infrastructure.support.transaction.ResourcelessTransactionManager;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.transaction.PlatformTransactionManager;

import java.nio.file.Path;
import java.time.LocalDate;
import java.time.YearMonth;
import java.time.ZonedDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.stream.Collectors;

/**
 * ETL jobs (PLAN 3.4). Steps that call external APIs run under a resourceless transaction manager so no DB
 * connection is held during HTTP calls; their DB writes use their own short transactions.
 *
 * <pre>
 * forecastIngestJob    serviceKeyRequired → forecastFetch
 * starIndexPublishJob  indexPublish
 * forecastPipelineJob  serviceKeyRequired → forecastFetch → indexPublish      (scheduler, after every issue)
 * astroDailyJob        astroCompute → [key?] → kasiRiseSet → crosscheck        (no key: Astronomy Engine only)
 * astroEventsJob       serviceKeyRequired → astroEvents → specialDays? → lunar? (? = skipped if not approved)
 * apiKeyCheckJob       serviceKeyRequired → apiKeyCheck                         (one call per API)
 * </pre>
 * Parameters (all optional, strings): base=yyyyMMddHHmm, nightDate=yyyy-MM-dd, from=yyyy-MM-dd, month=yyyy-MM.
 * Jobs have no incrementer on purpose: in Spring Batch 6, {@code JobOperator.start(job, params)} ignores the given
 * parameters when the job defines one. Every launch passes a unique {@code run.at} instead (scheduler, scripts/etl.sh).
 */
@Configuration
@EnableConfigurationProperties({EtlProperties.Etl.class, EtlProperties.Pack.class})
public class EtlJobsConfig {
    private final PlatformTransactionManager noTx = new ResourcelessTransactionManager();

    @Bean
    PackStore packStore(EtlProperties.Pack pack) {
        return new LocalPackStore(Path.of(pack.localDir()));
    }

    @Bean
    EtlJobListener etlJobListener() { return new EtlJobListener(); }

    @Bean
    JobExecutionDecider serviceKeyDecider(DataGoKrProperties props) {
        return (job, step) -> new FlowExecutionStatus(props.hasServiceKey() ? "KEY" : "NO_KEY");
    }

    // ------------------------------------------------------------------ steps

    @Bean
    Step serviceKeyRequiredStep(JobRepository repo, DataGoKrProperties props) {
        return new StepBuilder("serviceKeyRequired", repo).tasklet((c, ctx) -> {
            if (!props.hasServiceKey())
                throw new EtlStopException(new DataGoKrException(null, DataGoKrException.Kind.KEY_MISSING, null, 0, "no key").guidance());
            summary(c, props.looksPercentEncoded() ? "키 있음(주의: Encoding 키로 보임 → Decoding 키 권장)" : "키 있음");
            return RepeatStatus.FINISHED;
        }, noTx).build();
    }

    @Bean
    Step forecastFetchStep(JobRepository repo, ForecastIngestService ingest, EtlProperties.Etl etl) {
        return new StepBuilder("forecastFetch", repo).tasklet((c, ctx) -> {
            JobParameters p = c.getStepExecution().getJobParameters();
            String b = p.getString("base");
            KmaBaseTime base = b == null || b.isBlank()
                    ? KmaBaseTime.latestAvailable(ZonedDateTime.now(AstroCalculator.KST), etl.kmaAvailabilityDelay())
                    : KmaBaseTime.parse(b.substring(0, 8), b.substring(8, 12));
            var report = ingest.ingest(base);
            c.getStepExecution().getJobExecution().getExecutionContext().putString("forecast.base", base.dateParam() + base.timeParam());
            summary(c, report.summary());
            if (report.completeness() < etl.forecastMinCompleteness())
                throw new EtlStopException(String.format("완결성 미달 %.0f%% (기준 %.0f%%): %s", report.completeness() * 100,
                        etl.forecastMinCompleteness() * 100, report.summary()));
            return RepeatStatus.FINISHED;
        }, noTx).build();
    }

    @Bean
    Step indexPublishStep(JobRepository repo, IndexService index, PackPublisher publisher, EtlProperties.Pack pack) {
        return new StepBuilder("indexPublish", repo).tasklet((c, ctx) -> {
            String nd = c.getStepExecution().getJobParameters().getString("nightDate");
            LocalDate nightDate = nd == null || nd.isBlank() ? IndexService.nightDateOf(ZonedDateTime.now(AstroCalculator.KST)) : LocalDate.parse(nd);
            var nights = index.compute(nightDate, pack.hourlySlots(), 1.0);
            int scored = index.persist(nightDate, nights);
            if (scored == 0)
                throw new EtlStopException(nightDate + " 밤: 예보가 있는 천문박명 시간대가 없어 지수를 만들 수 없습니다. "
                        + "forecastIngestJob을 먼저 실행하세요(예보는 발표 후 약 5일치만 있습니다).");
            var published = publisher.publishIndex(nightDate, nights, pack.hourlySlots());
            summary(c, nightDate + " 밤 지수 " + scored + "/" + nights.size() + "개 지점, 팩 " + published.version()
                    + " (" + published.bytes() + " B gz" + (published.newVersion() ? ", 새 버전" : ", 변경 없음") + ")");
            return RepeatStatus.FINISHED;
        }, noTx).build();
    }

    @Bean
    Step astroComputeStep(JobRepository repo, AstroService astro, EtlProperties.Etl etl) {
        return new StepBuilder("astroCompute", repo).tasklet((c, ctx) -> {
            LocalDate from = fromParam(c);
            int n = astro.computeNights(from, etl.astroDaysAhead() + 1);
            summary(c, "Astronomy Engine 밤 " + n + "건(" + from + "부터 " + (etl.astroDaysAhead() + 1) + "일)");
            return RepeatStatus.FINISHED;
        }, noTx).build();
    }

    @Bean
    Step kasiRiseSetStep(JobRepository repo, AstroService astro, EtlProperties.Etl etl) {
        return new StepBuilder("kasiRiseSet", repo).tasklet((c, ctx) -> {
            var report = astro.fetchRiseSet(fromParam(c), etl.astroDaysAhead() + 1);
            summary(c, report.summary());
            if (report.stored() == 0 && report.requested() > 0) throw new EtlStopException("천문연 출몰시각을 하나도 받지 못했습니다: " + report.summary());
            return RepeatStatus.FINISHED;
        }, noTx).build();
    }

    @Bean
    Step crosscheckStep(JobRepository repo, AstroService astro, EtlProperties.Etl etl) {
        return new StepBuilder("crosscheck", repo).tasklet((c, ctx) -> {
            var report = astro.crosscheck(fromParam(c), etl.astroDaysAhead() + 1);
            summary(c, report.summary());
            return RepeatStatus.FINISHED;
        }, noTx).build();
    }

    @Bean
    Step astroEventsStep(JobRepository repo, AstroService astro) {
        return new StepBuilder("astroEvents", repo).tasklet((c, ctx) -> {
            List<String> parts = new ArrayList<>();
            for (YearMonth ym : months(c)) {
                try {
                    parts.add(ym + " " + astro.fetchAstroEvents(ym) + "건");
                } catch (DataGoKrException e) {
                    throw new EtlStopException(e.guidance(), e);
                }
            }
            summary(c, "천문현상 " + String.join(", ", parts));
            return RepeatStatus.FINISHED;
        }, noTx).build();
    }

    @Bean
    Step specialDaysStep(JobRepository repo, AstroService astro) {
        return optionalMonthly(repo, "specialDays", "특일", ym -> astro.fetchSpecialDays(ym));
    }

    @Bean
    Step lunarStep(JobRepository repo, AstroService astro) {
        return optionalMonthly(repo, "lunar", "음양력", ym -> astro.fetchLunar(ym));
    }

    @Bean
    Step apiKeyCheckStep(JobRepository repo, ApiKeyCheckService check) {
        return new StepBuilder("apiKeyCheck", repo).tasklet((c, ctx) -> {
            var results = check.checkAll();
            String report = results.stream().map(ApiKeyCheckService.Check::line).collect(Collectors.joining("\n    "));
            summary(c, "\n    " + report);
            String failedRequired = results.stream().filter(r -> !r.ok() && r.source().requiredForM0())
                    .map(r -> r.source().titleKo()).collect(Collectors.joining(", "));
            if (!failedRequired.isEmpty()) throw new EtlStopException("필수 API 실패: " + failedRequired + " (위 보고서 참고)");
            return RepeatStatus.FINISHED;
        }, noTx).build();
    }

    // ------------------------------------------------------------------ jobs

    @Bean
    Job forecastIngestJob(JobRepository repo, Step serviceKeyRequiredStep, Step forecastFetchStep, EtlJobListener l) {
        return new JobBuilder("forecastIngestJob", repo).listener(l)
                .start(serviceKeyRequiredStep).next(forecastFetchStep).build();
    }

    @Bean
    Job starIndexPublishJob(JobRepository repo, Step indexPublishStep, EtlJobListener l) {
        return new JobBuilder("starIndexPublishJob", repo).listener(l)
                .start(indexPublishStep).build();
    }

    @Bean
    Job forecastPipelineJob(JobRepository repo, Step serviceKeyRequiredStep, Step forecastFetchStep, Step indexPublishStep,
                            EtlJobListener l) {
        return new JobBuilder("forecastPipelineJob", repo).listener(l)
                .start(serviceKeyRequiredStep).next(forecastFetchStep).next(indexPublishStep).build();
    }

    @Bean
    Job astroDailyJob(JobRepository repo, Step astroComputeStep, JobExecutionDecider serviceKeyDecider, Step kasiRiseSetStep,
                      Step crosscheckStep, EtlJobListener l) {
        return new JobBuilder("astroDailyJob", repo).listener(l)
                .start(astroComputeStep).next(serviceKeyDecider).on("NO_KEY").end()
                .from(serviceKeyDecider).on("KEY").to(kasiRiseSetStep).next(crosscheckStep)
                .end().build();
    }

    @Bean
    Job astroEventsJob(JobRepository repo, Step serviceKeyRequiredStep, Step astroEventsStep, Step specialDaysStep,
                       Step lunarStep, EtlJobListener l) {
        return new JobBuilder("astroEventsJob", repo).listener(l)
                .start(serviceKeyRequiredStep).next(astroEventsStep).next(specialDaysStep).next(lunarStep).build();
    }

    @Bean
    Job apiKeyCheckJob(JobRepository repo, Step serviceKeyRequiredStep, Step apiKeyCheckStep, EtlJobListener l) {
        return new JobBuilder("apiKeyCheckJob", repo).listener(l)
                .start(serviceKeyRequiredStep).next(apiKeyCheckStep).build();
    }

    // ------------------------------------------------------------------ helpers

    interface MonthlyFetch { int fetch(YearMonth ym); }

    /** Monthly KASI data whose 활용신청 is optional: a rejected key skips the step instead of failing the job. */
    private Step optionalMonthly(JobRepository repo, String name, String label, MonthlyFetch fetch) {
        return new StepBuilder(name, repo).tasklet((c, ctx) -> {
            List<String> parts = new ArrayList<>();
            for (YearMonth ym : months(c)) {
                try {
                    parts.add(ym + " " + fetch.fetch(ym) + "건");
                } catch (DataGoKrException e) {
                    if (e.kind() == DataGoKrException.Kind.KEY_REJECTED) {
                        summary(c, label + " 건너뜀: " + e.guidance());
                        c.setExitStatus(new ExitStatus("SKIPPED", e.guidance()));
                        return RepeatStatus.FINISHED;
                    }
                    throw new EtlStopException(e.guidance(), e);
                }
            }
            summary(c, label + " " + String.join(", ", parts));
            return RepeatStatus.FINISHED;
        }, noTx).build();
    }

    private static LocalDate fromParam(StepContribution c) {
        String from = c.getStepExecution().getJobParameters().getString("from");
        return from == null || from.isBlank() ? LocalDate.now(AstroCalculator.KST) : LocalDate.parse(from);
    }

    /** The given month, or this month and the next (events are announced ahead). */
    private static List<YearMonth> months(StepContribution c) {
        String m = c.getStepExecution().getJobParameters().getString("month");
        if (m != null && !m.isBlank()) return List.of(YearMonth.parse(m));
        YearMonth now = YearMonth.now(AstroCalculator.KST);
        return List.of(now, now.plusMonths(1));
    }

    static void summary(StepContribution c, String text) {
        c.getStepExecution().getJobExecution().getExecutionContext()
                .putString("summary." + c.getStepExecution().getStepName(), text);
    }
}
