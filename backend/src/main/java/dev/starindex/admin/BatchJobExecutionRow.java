package dev.starindex.admin;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.FetchType;
import jakarta.persistence.Id;
import jakarta.persistence.JoinColumn;
import jakarta.persistence.ManyToOne;
import jakarta.persistence.Table;
import org.hibernate.annotations.Immutable;

import java.time.LocalDateTime;

/**
 * Read-only view of BATCH_JOB_EXECUTION for the admin run history (QueryDSL). Times are the JVM's local time, as
 * Spring Batch writes them (the server runs in UTC on EC2; the page converts for display).
 */
@Entity
@Immutable
@Table(name = "batch_job_execution")
public class BatchJobExecutionRow {
    @Id
    @Column(name = "job_execution_id")
    private Long id;

    @ManyToOne(fetch = FetchType.LAZY, optional = false)
    @JoinColumn(name = "job_instance_id")
    private BatchJobInstanceRow instance;

    @Column(name = "create_time")
    private LocalDateTime createTime;

    @Column(name = "start_time")
    private LocalDateTime startTime;

    @Column(name = "end_time")
    private LocalDateTime endTime;

    @Column(name = "status")
    private String status;

    @Column(name = "exit_code")
    private String exitCode;

    @Column(name = "exit_message")
    private String exitMessage;

    protected BatchJobExecutionRow() {}

    public Long getId() { return id; }
    public BatchJobInstanceRow getInstance() { return instance; }
    public LocalDateTime getCreateTime() { return createTime; }
    public LocalDateTime getStartTime() { return startTime; }
    public LocalDateTime getEndTime() { return endTime; }
    public String getStatus() { return status; }
    public String getExitCode() { return exitCode; }
    public String getExitMessage() { return exitMessage; }
}
