package dev.starindex;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

@SpringBootApplication
public class StarIndexApplication {
    public static void main(String[] args) {
        var ctx = SpringApplication.run(StarIndexApplication.class, args);
        // One-shot CLI job runs (scripts/etl.sh: spring.batch.job.enabled=true, no web server): exit with the job's
        // result (0 = COMPLETED, non-zero = FAILED) so shells and CodeDeploy hooks can react. A web server started
        // with a job runs it once and keeps serving (scripts/ec2sim.sh measures that production-like JVM).
        var env = ctx.getEnvironment();
        if (env.getProperty("spring.batch.job.enabled", Boolean.class, false)
                && "none".equalsIgnoreCase(env.getProperty("spring.main.web-application-type", "")))
            System.exit(SpringApplication.exit(ctx));
    }
}
