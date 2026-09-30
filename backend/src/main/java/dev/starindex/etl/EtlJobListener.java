package dev.starindex.etl;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.batch.core.job.JobExecution;
import org.springframework.batch.core.listener.JobExecutionListener;
import org.springframework.batch.core.step.StepExecution;

/** Prints one readable block per job run: each step's status and summary, and the reason when it failed. */
public class EtlJobListener implements JobExecutionListener {
    private static final Logger log = LoggerFactory.getLogger("ETL");

    @Override
    public void afterJob(JobExecution je) {
        StringBuilder sb = new StringBuilder();
        sb.append("\n[ETL] ").append(je.getJobInstance().getJobName()).append(" → ").append(je.getStatus());
        for (StepExecution se : je.getStepExecutions()) {
            sb.append("\n  - ").append(se.getStepName()).append(": ").append(se.getExitStatus().getExitCode());
            String summary = je.getExecutionContext().getString("summary." + se.getStepName(), null);
            if (summary != null) sb.append(" | ").append(summary);
        }
        for (Throwable t : je.getAllFailureExceptions()) {
            Throwable root = t;
            while (!(root instanceof EtlStopException) && root.getCause() != null) root = root.getCause();
            sb.append("\n  ! ").append(root instanceof EtlStopException ? root.getMessage() : t.toString());
        }
        if (je.getStatus().isUnsuccessful()) log.warn(sb.toString());
        else log.info(sb.toString());
    }
}
