package dev.starindex.etl;

import dev.starindex.datagokr.DataGoKrException;
import dev.starindex.etl.kma.KmaBaseTime;
import dev.starindex.etl.kma.KmaForecastClient;
import dev.starindex.region.Region;
import dev.starindex.region.RegionQueryRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.support.TransactionTemplate;

import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

/**
 * Fetches one 단기예보 issue for every distinct grid cell of the active points. One transaction per cell. Key and quota
 * errors stop the whole run (every other cell would fail the same way); other errors are recorded and the run goes on,
 * then completeness decides.
 * <p>Fail fast when data.go.kr cannot be reached at all: if the first {@link #UNREACHABLE_AFTER} cells all fail with a
 * connection error and none has succeeded, the run stops. data.go.kr refuses some overseas addresses (GitHub-hosted
 * runners), and without this a blocked runner spends ~5 minutes retrying 17 cells; the workflow retries on a fresh
 * runner instead (ADR-017).
 */
@Service
public class ForecastIngestService {
    private static final Logger log = LoggerFactory.getLogger(ForecastIngestService.class);
    static final int UNREACHABLE_AFTER = 2;

    public record Report(KmaBaseTime base, int cells, int ok, int rows, List<String> failures) {
        public double completeness() { return cells == 0 ? 0 : (double) ok / cells; }

        public String summary() {
            return "단기예보 " + base + " 발표: 격자 " + ok + "/" + cells + " 저장, 시간대 " + rows + "행"
                    + (failures.isEmpty() ? "" : ", 실패 " + failures.size() + "건 " + failures);
        }
    }

    public record Cell(int nx, int ny) {}

    private final RegionQueryRepository regions;
    private final KmaForecastClient kma;
    private final EtlRepository repo;
    private final TransactionTemplate tx;

    public ForecastIngestService(RegionQueryRepository regions, KmaForecastClient kma, EtlRepository repo, TransactionTemplate tx) {
        this.regions = regions;
        this.kma = kma;
        this.repo = repo;
        this.tx = tx;
    }

    public List<Cell> cells() {
        Set<Cell> cells = new LinkedHashSet<>();
        for (Region r : regions.findActive()) cells.add(new Cell(r.getKmaNx(), r.getKmaNy()));
        return new ArrayList<>(cells);
    }

    public Report ingest(KmaBaseTime base) {
        List<Cell> cells = cells();
        int ok = 0, rows = 0;
        List<String> failures = new ArrayList<>();
        for (Cell c : cells) {
            try {
                var result = kma.fetch(c.nx(), c.ny(), base);
                if (result.items().isEmpty()) {
                    failures.add(c.nx() + "," + c.ny() + " NO_DATA");
                    continue;
                }
                Integer n = tx.execute(s -> repo.upsertForecast(result));
                rows += n == null ? 0 : n;
                ok++;
            } catch (DataGoKrException e) {
                if (e.kind().stopsRun()) throw new EtlStopException(e.guidance(), e);
                log.warn("forecast {} {} failed: {}", c, base, e.guidance());
                failures.add(c.nx() + "," + c.ny() + " " + e.kind() + (e.code() == null ? "" : " " + e.code()));
                if (ok == 0 && failures.size() >= UNREACHABLE_AFTER
                        && failures.stream().allMatch(f -> f.endsWith(" " + DataGoKrException.Kind.IO.name())))
                    throw new EtlStopException("data.go.kr에 연결할 수 없습니다(처음 " + failures.size()
                            + "개 격자 모두 통신 오류). 이 실행 환경의 IP가 막혔을 수 있습니다: " + failures, e);
            }
        }
        return new Report(base, cells.size(), ok, rows, failures);
    }
}
