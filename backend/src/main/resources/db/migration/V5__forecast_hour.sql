-- DB-PLAN 3.1 / ADR-014: 단기예보는 (격자, 예보 시각)당 1행, 서비스가 읽는 6개 항목만 둔다.
-- 각 값은 "가장 최근 발표의 결측 아닌 값"이다. base_at은 이 행에 값을 준 가장 최근 발표다.
CREATE TABLE kma_forecast_hour (
    nx       SMALLINT     NOT NULL,
    ny       SMALLINT     NOT NULL,
    fcst_at  TIMESTAMPTZ  NOT NULL,
    base_at  TIMESTAMPTZ  NOT NULL,
    sky      SMALLINT,          -- 1/3/4
    pty      SMALLINT,          -- 0~4
    tmp      NUMERIC(4,1),      -- °C, one decimal exactly (REAL would print 1.7999… and change the pack bytes)
    reh      SMALLINT,          -- %
    wsd      NUMERIC(4,1),      -- m/s; extended-period code values are not amounts → NULL
    pop      SMALLINT,          -- %
    PRIMARY KEY (nx, ny, fcst_at)
);

-- Carry over what is still useful (last 2 days), newest non-missing value per item.
INSERT INTO kma_forecast_hour (nx, ny, fcst_at, base_at, sky, pty, tmp, reh, wsd, pop)
SELECT nx, ny, fcst_at, MAX(base_at),
  ((array_agg(value_num ORDER BY base_at DESC) FILTER (WHERE category = 'SKY' AND value_num IS NOT NULL))[1])::smallint,
  ((array_agg(value_num ORDER BY base_at DESC) FILTER (WHERE category = 'PTY' AND value_num IS NOT NULL))[1])::smallint,
  ((array_agg(value_num ORDER BY base_at DESC) FILTER (WHERE category = 'TMP' AND value_num IS NOT NULL))[1])::numeric(4,1),
  ((array_agg(value_num ORDER BY base_at DESC) FILTER (WHERE category = 'REH' AND value_num IS NOT NULL))[1])::smallint,
  ((array_agg(value_num ORDER BY base_at DESC) FILTER (WHERE category = 'WSD' AND value_num IS NOT NULL AND NOT value_is_code))[1])::numeric(4,1),
  ((array_agg(value_num ORDER BY base_at DESC) FILTER (WHERE category = 'POP' AND value_num IS NOT NULL))[1])::smallint
FROM kma_forecast
WHERE category IN ('SKY', 'PTY', 'TMP', 'REH', 'WSD', 'POP') AND fcst_at >= now() - interval '2 days'
GROUP BY nx, ny, fcst_at
HAVING bool_or(value_num IS NOT NULL);

DROP TABLE kma_forecast;          -- its V3/V4 indexes go with it
DROP TABLE kma_forecast_issue;    -- completeness → BATCH_STEP_EXECUTION WRITE/FILTER_COUNT; latest issue → MAX(base_at)
