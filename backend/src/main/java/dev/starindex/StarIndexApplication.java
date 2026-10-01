package dev.starindex;

import dev.starindex.etl.EtlJobListener;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

@SpringBootApplication
public class StarIndexApplication {
    public static void main(String[] args) {
        var ctx = SpringApplication.run(StarIndexApplication.class, args);
        // One-shot CLI job runs (scripts/etl.sh, .github/workflows/etl-attempt.yml: spring.batch.job.enabled=true, no
        // web server): exit with the job's result (0 = COMPLETED, non-zero = FAILED) so shells can react, and with 75
        // when it failed because data.go.kr was unreachable (the workflow then retries on a fresh runner). A web server
        // started with a job runs it once and keeps serving.
        var env = ctx.getEnvironment();
        if (env.getProperty("spring.batch.job.enabled", Boolean.class, false)
                && "none".equalsIgnoreCase(env.getProperty("spring.main.web-application-type", ""))) {
            var listener = ctx.getBeanProvider(EtlJobListener.class).getIfAvailable();
            boolean unreachable = listener != null && listener.sawUnreachable();
            System.exit(exitCode(SpringApplication.exit(ctx), unreachable));
        }
    }

    static int exitCode(int batchExitCode, boolean unreachable) {
        return batchExitCode != 0 && unreachable ? EtlJobListener.EXIT_UNREACHABLE : batchExitCode;
    }
}
