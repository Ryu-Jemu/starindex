package dev.starindex.admin;

import com.querydsl.core.BooleanBuilder;
import com.querydsl.core.types.Projections;
import com.querydsl.jpa.impl.JPAQueryFactory;
import jakarta.persistence.EntityManager;
import org.springframework.batch.core.BatchStatus;
import org.springframework.stereotype.Repository;
import org.springframework.transaction.annotation.Transactional;

import java.time.LocalDateTime;
import java.util.List;

import static dev.starindex.admin.QBatchJobExecutionRow.batchJobExecutionRow;
import static dev.starindex.admin.QBatchJobInstanceRow.batchJobInstanceRow;

/**
 * Admin run history (PLAN 3.4 {@code etl/runs}; cut line ④ keeps exactly this table with a QueryDSL filter).
 * Every filter and the sort order arrive as typed values or enums, never as column names or expressions from the
 * request (CVE-2024-49203 mitigation, ADR-004).
 */
@Repository
@Transactional(readOnly = true)
public class EtlRunQueryRepository {
    public enum SortKey { NEWEST, OLDEST }

    /** @param jobName must be one of the server's job names (checked by the caller) or null */
    public record Filter(String jobName, BatchStatus status, LocalDateTime since) {}

    public record Run(Long id, String jobName, String status, String exitCode, String exitMessage,
                      LocalDateTime createTime, LocalDateTime startTime, LocalDateTime endTime) {}

    public record Page(List<Run> runs, long total, int page, int size) {}

    private final JPAQueryFactory query;

    public EtlRunQueryRepository(EntityManager em) {
        this.query = new JPAQueryFactory(em);
    }

    public Page find(Filter f, SortKey sort, int page, int size) {
        var e = batchJobExecutionRow;
        var i = batchJobInstanceRow;
        BooleanBuilder where = new BooleanBuilder();
        if (f.jobName() != null) where.and(i.jobName.eq(f.jobName()));
        if (f.status() != null) where.and(e.status.eq(f.status().name()));
        if (f.since() != null) where.and(e.createTime.goe(f.since()));
        List<Run> runs = query.select(Projections.constructor(Run.class, e.id, i.jobName, e.status, e.exitCode,
                        e.exitMessage, e.createTime, e.startTime, e.endTime))
                .from(e).join(e.instance, i)
                .where(where)
                .orderBy(switch (sort) {
                    case NEWEST -> e.id.desc();
                    case OLDEST -> e.id.asc();
                })
                .offset((long) page * size).limit(size)
                .fetch();
        Long total = query.select(e.count()).from(e).join(e.instance, i).where(where).fetchOne();
        return new Page(runs, total == null ? 0 : total, page, size);
    }
}
