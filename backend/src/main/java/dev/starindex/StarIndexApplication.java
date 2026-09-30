package dev.starindex;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

@SpringBootApplication
public class StarIndexApplication {
    public static void main(String[] args) {
        var ctx = SpringApplication.run(StarIndexApplication.class, args);
        // One-shot job runs (scripts/etl.sh sets spring.batch.job.enabled=true): exit with the job's result
        // (0 = COMPLETED, non-zero = FAILED) so shells and CodeDeploy hooks can react.
        if (ctx.getEnvironment().getProperty("spring.batch.job.enabled", Boolean.class, false))
            System.exit(SpringApplication.exit(ctx));
    }
}
