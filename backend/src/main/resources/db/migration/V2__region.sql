-- Forecast points and their KMA 단기예보 grid (nx, ny).
-- Source: 기상청41_단기예보 조회서비스_오픈API활용가이드_격자_위경도(2607).xlsx, sheet '최종 업데이트 파일_20260701'
-- (공공누리 제1유형, 출처: 기상청). Rows are the 1단계 시·도 rows (16 since 광주+전남 became
-- 전남광주통합특별시 on the 2026-07-01 sheet) plus one EXTRA point for the former 광주광역시 (서구),
-- kept as a product choice for big-city users. Every (nx, ny) was recomputed from the listed lat/lon with the
-- guide's LCC formula (KmaGrid) and matches the sheet.
CREATE TABLE region (
    id       BIGINT           NOT NULL PRIMARY KEY,           -- 10-digit 행정구역코드
    kind     VARCHAR(8)       NOT NULL CHECK (kind IN ('SIDO', 'EXTRA')),
    sido     VARCHAR(30)      NOT NULL,
    sigungu  VARCHAR(30),
    name_ko  VARCHAR(40)      NOT NULL,
    lat      DOUBLE PRECISION NOT NULL,
    lon      DOUBLE PRECISION NOT NULL,
    kma_nx   INTEGER          NOT NULL CHECK (kma_nx BETWEEN 1 AND 149),
    kma_ny   INTEGER          NOT NULL CHECK (kma_ny BETWEEN 1 AND 253),
    active   BOOLEAN          NOT NULL DEFAULT TRUE
);

CREATE INDEX idx_region_sido ON region (sido);
CREATE INDEX idx_region_grid ON region (kma_nx, kma_ny);

INSERT INTO region (id, kind, sido, sigungu, name_ko, lat, lon, kma_nx, kma_ny) VALUES
    (1100000000, 'SIDO',  '서울특별시',         NULL,   '서울',   37.5635694444444, 126.980008333333,  60, 127),
    (1200000000, 'SIDO',  '전남광주통합특별시', NULL,   '전남광주', 34.8130444444444, 126.465,           51,  67),
    (1224000000, 'EXTRA', '전남광주통합특별시', '서구', '광주',   35.1494833333333, 126.893411111111,  59,  74),
    (2600000000, 'SIDO',  '부산광역시',         NULL,   '부산',   35.1770194444444, 129.076952777777,  98,  76),
    (2700000000, 'SIDO',  '대구광역시',         NULL,   '대구',   35.8685416666666, 128.603552777777,  89,  90),
    (2800000000, 'SIDO',  '인천광역시',         NULL,   '인천',   37.4532333333333, 126.707352777777,  55, 124),
    (3000000000, 'SIDO',  '대전광역시',         NULL,   '대전',   36.3471194444444, 127.386566666666,  67, 100),
    (3100000000, 'SIDO',  '울산광역시',         NULL,   '울산',   35.5354083333333, 129.313688888888, 102,  84),
    (3600000000, 'SIDO',  '세종특별자치시',     NULL,   '세종',   36.4800121,       127.2890691,       66, 103),
    (4100000000, 'SIDO',  '경기도',             NULL,   '경기',   37.2718444444444, 127.011688888888,  60, 120),
    (4300000000, 'SIDO',  '충청북도',           NULL,   '충북',   36.6325,          127.493586111111,  69, 107),
    (4400000000, 'SIDO',  '충청남도',           NULL,   '충남',   36.6588148937733, 126.672797505435,  55, 107),
    (4700000000, 'SIDO',  '경상북도',           NULL,   '경북',   36.5759985118295, 128.505832256098,  87, 106),
    (4800000000, 'SIDO',  '경상남도',           NULL,   '경남',   35.2347361111111, 128.694166666666,  91,  77),
    (5000000000, 'SIDO',  '제주특별자치도',     NULL,   '제주',   33.4856944444444, 126.500333333333,  52,  38),
    (5100000000, 'SIDO',  '강원특별자치도',     NULL,   '강원',   37.8826916666666, 127.731975,        73, 134),
    (5200000000, 'SIDO',  '전북특별자치도',     NULL,   '전북',   35.817275,        127.111052777777,  63,  89);
