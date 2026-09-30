-- ETL tables (SERVICE-PLAN 8, PLAN 3.4). Instants are TIMESTAMPTZ; KST wall times from KASI are TIME + DATE.

-- Every external call, for quality metrics and the admin page. Never stores the key or user coordinates.
CREATE TABLE etl_api_call (
    id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source       VARCHAR(20)  NOT NULL,
    operation    VARCHAR(40)  NOT NULL,
    request_key  VARCHAR(80)  NOT NULL,
    http_status  INTEGER,
    result_code  VARCHAR(10),
    result_msg   VARCHAR(160),
    item_count   INTEGER,
    duration_ms  INTEGER      NOT NULL,
    outcome      VARCHAR(20)  NOT NULL,
    called_at    TIMESTAMPTZ  NOT NULL DEFAULT now()
);
CREATE INDEX idx_etl_api_call_time ON etl_api_call (called_at DESC);
CREATE INDEX idx_etl_api_call_source ON etl_api_call (source, called_at DESC);

-- KMA 단기예보, one row per (grid cell, issue, forecast time, category). Raw text is kept; value_num is NULL for
-- missing values (|v| >= 900) and for the extended-period code values of PCP/SNO/WSD (value_is_code).
CREATE TABLE kma_forecast (
    nx             SMALLINT     NOT NULL,
    ny             SMALLINT     NOT NULL,
    base_at        TIMESTAMPTZ  NOT NULL,
    fcst_at        TIMESTAMPTZ  NOT NULL,
    category       VARCHAR(4)   NOT NULL,
    value_text     VARCHAR(40)  NOT NULL,
    value_num      DOUBLE PRECISION,
    value_is_code  BOOLEAN      NOT NULL DEFAULT FALSE,
    ingested_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),
    PRIMARY KEY (nx, ny, base_at, fcst_at, category)
);
CREATE INDEX idx_kma_forecast_lookup ON kma_forecast (nx, ny, fcst_at, base_at DESC);

-- One row per successfully stored (grid cell, issue): completeness check and "latest issue" lookup.
CREATE TABLE kma_forecast_issue (
    nx           SMALLINT     NOT NULL,
    ny           SMALLINT     NOT NULL,
    base_at      TIMESTAMPTZ  NOT NULL,
    row_count    INTEGER      NOT NULL,
    total_count  INTEGER      NOT NULL,
    fetched_at   TIMESTAMPTZ  NOT NULL DEFAULT now(),
    PRIMARY KEY (nx, ny, base_at)
);

-- KASI 출몰시각 (getLCRiseSetInfo) per point and date, KST wall-clock times.
CREATE TABLE kasi_riseset (
    region_id      BIGINT       NOT NULL REFERENCES region (id),
    locdate        DATE         NOT NULL,
    kasi_location  VARCHAR(40),
    sunrise TIME, suntransit TIME, sunset TIME,
    moonrise TIME, moontransit TIME, moonset TIME,
    civilm TIME, civile TIME, nautm TIME, naute TIME, astm TIME, aste TIME,
    fetched_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),
    PRIMARY KEY (region_id, locdate)
);

-- Astronomy Engine values for the same nights: fallback when KASI is unavailable and the cross-check reference.
CREATE TABLE astro_night (
    region_id          BIGINT       NOT NULL REFERENCES region (id),
    night_date         DATE         NOT NULL,
    sunset             TIMESTAMPTZ,
    civil_dusk         TIMESTAMPTZ,
    nautical_dusk      TIMESTAMPTZ,
    astronomical_dusk  TIMESTAMPTZ,
    astronomical_dawn  TIMESTAMPTZ,
    nautical_dawn      TIMESTAMPTZ,
    civil_dawn         TIMESTAMPTZ,
    sunrise            TIMESTAMPTZ,
    computed_at        TIMESTAMPTZ  NOT NULL DEFAULT now(),
    PRIMARY KEY (region_id, night_date)
);

-- KASI vs Astronomy Engine for the evening events (T16: |Δ| within about 2 min).
CREATE TABLE astro_crosscheck (
    region_id     BIGINT       NOT NULL REFERENCES region (id),
    night_date    DATE         NOT NULL,
    field         VARCHAR(12)  NOT NULL CHECK (field IN ('sunset', 'civile', 'naute', 'aste')),
    kasi_at       TIMESTAMPTZ  NOT NULL,
    computed_at   TIMESTAMPTZ  NOT NULL,
    diff_seconds  INTEGER      NOT NULL,
    checked_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),
    PRIMARY KEY (region_id, night_date, field)
);

-- KASI 천문현상. Monthly feature articles come with a YYYYMM locdate: stored as day 1 with month_feature = TRUE.
CREATE TABLE kasi_astro_event (
    locdate        DATE         NOT NULL,
    month_feature  BOOLEAN      NOT NULL DEFAULT FALSE,
    seq            INTEGER      NOT NULL,
    astro_time     TIME,
    title          VARCHAR(200),
    event          TEXT         NOT NULL,
    remarks        TEXT,
    fetched_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),
    PRIMARY KEY (locdate, month_feature, seq)
);

-- KASI 특일 (공휴일 getRestDeInfo, 24절기 get24DivisionsInfo).
CREATE TABLE kasi_special_day (
    locdate        DATE         NOT NULL,
    date_kind      VARCHAR(2)   NOT NULL,
    date_name      VARCHAR(60)  NOT NULL,
    is_holiday     BOOLEAN      NOT NULL,
    kst            TIME,
    sun_longitude  INTEGER,
    fetched_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),
    PRIMARY KEY (locdate, date_kind, date_name)
);

-- KASI 음양력 (getLunCalInfo, one row per solar date).
CREATE TABLE kasi_lunar_day (
    sol_date     DATE         NOT NULL PRIMARY KEY,
    lun_year     INTEGER      NOT NULL,
    lun_month    INTEGER      NOT NULL,
    lun_day      INTEGER      NOT NULL,
    lun_leap     BOOLEAN      NOT NULL,
    lun_iljin    VARCHAR(20),
    fetched_at   TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- Star index v1 per point and dark hour, from the latest forecast issue at publish time.
CREATE TABLE star_index_hourly (
    region_id   BIGINT       NOT NULL REFERENCES region (id),
    night_date  DATE         NOT NULL,
    hour_at     TIMESTAMPTZ  NOT NULL,
    base_at     TIMESTAMPTZ  NOT NULL,
    sky         SMALLINT     NOT NULL,
    pty         SMALLINT     NOT NULL,
    f_cloud     REAL         NOT NULL,
    f_precip    REAL         NOT NULL,
    f_moon      REAL         NOT NULL,
    f_light     REAL         NOT NULL,
    score       SMALLINT     NOT NULL CHECK (score BETWEEN 0 AND 100),
    PRIMARY KEY (region_id, hour_at)
);
CREATE INDEX idx_star_index_hourly_night ON star_index_hourly (night_date, region_id);

CREATE TABLE star_index_nightly (
    region_id    BIGINT       NOT NULL REFERENCES region (id),
    night_date   DATE         NOT NULL,
    base_at      TIMESTAMPTZ  NOT NULL,
    score        SMALLINT     NOT NULL CHECK (score BETWEEN 0 AND 100),
    grade        VARCHAR(10)  NOT NULL,
    best_from    TIMESTAMPTZ  NOT NULL,
    best_to      TIMESTAMPTZ  NOT NULL,
    contrib      JSONB        NOT NULL,
    reasons      JSONB        NOT NULL,
    computed_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),
    PRIMARY KEY (region_id, night_date)
);

-- Published static packs (history + rollback). The manifest in the pack store is the single source of truth.
CREATE TABLE data_pack (
    id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    kind          VARCHAR(20)  NOT NULL,
    version       VARCHAR(40)  NOT NULL,
    night_date    DATE,
    base_at       TIMESTAMPTZ,
    path          VARCHAR(200) NOT NULL,
    sha256        CHAR(64)     NOT NULL,
    bytes         INTEGER      NOT NULL,
    raw_bytes     INTEGER      NOT NULL,
    region_count  INTEGER      NOT NULL,
    published_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),
    UNIQUE (kind, version)
);
