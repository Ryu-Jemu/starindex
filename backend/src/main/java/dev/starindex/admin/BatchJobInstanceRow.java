package dev.starindex.admin;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import org.hibernate.annotations.Immutable;

/** Read-only view of Spring Batch's BATCH_JOB_INSTANCE (Flyway V1 owns the table; Batch writes it). */
@Entity
@Immutable
@Table(name = "batch_job_instance")
public class BatchJobInstanceRow {
    @Id
    @Column(name = "job_instance_id")
    private Long id;

    @Column(name = "job_name")
    private String jobName;

    protected BatchJobInstanceRow() {}

    public Long getId() { return id; }
    public String getJobName() { return jobName; }
}
