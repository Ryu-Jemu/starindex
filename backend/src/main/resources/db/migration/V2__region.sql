-- Regions and their KMA short-range forecast grid (nx, ny).
-- M0 seeds only Seoul (grid (60,127) verified against KMA's LCC formula, test T11).
-- The 17 시·도 set comes from the KMA 단기예보 활용가이드 grid spreadsheet (공공누리 1유형) in W3.
CREATE TABLE region (
    id       BIGINT       NOT NULL PRIMARY KEY,
    sido     VARCHAR(20)  NOT NULL,
    sigungu  VARCHAR(30)  NULL,
    name_ko  VARCHAR(40)  NOT NULL,
    lat      DOUBLE       NOT NULL,
    lon      DOUBLE       NOT NULL,
    kma_nx   INT          NOT NULL,
    kma_ny   INT          NOT NULL,
    INDEX idx_region_sido (sido),
    INDEX idx_region_grid (kma_nx, kma_ny)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

INSERT INTO region (id, sido, sigungu, name_ko, lat, lon, kma_nx, kma_ny)
VALUES (1100000000, '서울특별시', NULL, '서울', 37.5665, 126.9780, 60, 127);
