package dev.starindex.region;

import com.querydsl.jpa.impl.JPAQueryFactory;
import jakarta.persistence.EntityManager;
import org.springframework.stereotype.Repository;

import java.util.List;

import static dev.starindex.region.QRegion.region;

/** QueryDSL repository. Sort/filter keys are enums only (whitelist; CVE-2024-49203 mitigation, ADR-004). */
@Repository
public class RegionQueryRepository {
    public enum SortKey { ID, NAME }

    private final JPAQueryFactory query;

    public RegionQueryRepository(EntityManager em) {
        this.query = new JPAQueryFactory(em);
    }

    /** Distinct KMA grid points to fetch (used by forecastIngestJob). */
    public List<Region> findAll(SortKey sort) {
        var q = query.selectFrom(region);
        return switch (sort) {
            case ID -> q.orderBy(region.id.asc()).fetch();
            case NAME -> q.orderBy(region.nameKo.asc()).fetch();
        };
    }

    public List<Region> findBySido(String sido) {
        return query.selectFrom(region).where(region.sido.eq(sido)).orderBy(region.id.asc()).fetch();
    }
}
