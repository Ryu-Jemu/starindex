# DB-PLAN: 예보 2일 보관, 서비스에 필요한 데이터만 저장 (운영 DB: Neon Free, ADR-015)

> **2026-10-01 변경 (ADR-015):** 운영 DB는 **Neon Free**(PostgreSQL 18, 싱가포르)다. 1장의 "DB 위치·RDS 사용 기간·장기 비용", 4.4의 연결 풀 값, 5장(EC2 직접 설치), 6.2(메모리 모사), 9장의 단일 장애점 항목은 **11장으로 대체**됐고 기록으로만 남긴다(각 자리에 표시). 2~3장(저장·보관), 4장의 나머지 코드 변경, 6.1 테스트는 그대로 유효하다.

> **실행 기록 (2026-09-30 시작, 10-01 완료):** 사용자가 "작업을 구체화하고 완수하라"고 지시해, 8장 일정(M0 이후 수행)을 앞당겨 **C1~C8의 코드와 배포 산출물을 수행했다.** 결과, 검증, 계획과 달라진 점은 **10장**에 있다.
> - C9(관측소 스냅숏)는 관측소를 고른 뒤 R1 첫 주에 하고, 기한은 11/28이다.
> - EC2에 실제로 설치하는 일과 RDS→EC2 전환은 AWS 작업(W3) 때 한다.
> - 대신 설치 스크립트는 Amazon Linux 2023 컨테이너에서(`scripts/deploy-check.sh`, 47/47), 메모리 예산은 arm64 컨테이너 모사로(`scripts/ec2sim.sh`, 647/1,600MiB) 미리 검증했다.

작성일은 2026-09-30입니다. 대상 저장소는 `/Users/ryujemu/Desktop/Knowledge Graph/5주차/personal_project`입니다. 이 문서는 `docs/DB-PLAN.md`로 저장되고, 구현할 때 기준으로 씁니다. 검토 의견 20건을 어떻게 처리했는지는 부록 A에 정리했습니다.

표기 규칙은 다음과 같습니다.
- [확실]: 코드나 문서를 직접 읽었거나, URL을 직접 열어 확인한 것
- [가능성 높음]: 근거는 있지만 직접 확인하지 못한 것
- [불확실]: 실행하거나 확인해야 하는 것
- [추정]: 계산으로 얻은 값
- [해석]: 판단한 것

---

## 1. 결정 요약

| 항목 | 결정 |
|---|---|
| DB 위치 | 방안 ①을 택합니다. 앱과 같은 EC2(t4g.small 2GB, AL2023 arm64, 서울)에 PostgreSQL 18을 직접 설치합니다. AL2023 core 저장소의 `postgresql18` 계열 패키지를 씁니다. |
| RDS 호환 | `DB_URL`, `DB_USERNAME`, `DB_PASSWORD` 세 값만 바꾸면 RDS for PostgreSQL 18에서 그대로 돌아가야 합니다. 그래서 확장 기능, 슈퍼유저 권한이 필요한 SQL, 로컬 전용 문법을 쓰지 않습니다. 마이그레이션은 슈퍼유저가 아닌 소유자 계정으로 실행해도 통과해야 하고, 이것을 테스트로 보장합니다. |
| RDS 사용 기간 | (ADR-015로 대체: 시연에 필요할 때만 RDS, 이후 Neon. 전환은 11.9) M0 시연(10/20)까지는 기존 PLAN대로 RDS를 씁니다. 과제 요건인 "RDS"를 충족하기 위해서입니다. 10/20~10/25에 코드를 바꿔 RDS에서 먼저 확인하고, 전환 절차(5.7)로 EC2 PostgreSQL로 옮긴 뒤 최종 스냅샷을 만들고 RDS를 삭제합니다. |
| 보관 기간 | 기본은 **2일**입니다. 2일보다 길게 두는 것은 서비스상 근거가 있는 네 가지뿐입니다(2장). |
| 2일 예외 ① | 운영 이력 8일. G6의 "7일 연속" 판정과 관리자 이력 화면에 필요합니다. |
| 2일 예외 ② | 천문 달력은 지난달 1일부터. 월 달력과 이벤트 팩에 필요합니다. |
| 2일 예외 ③ | 적중률 스냅숏 32일. 공개 적중률의 30일 창에 필요합니다. |
| 2일 예외 ④ | 팩은 manifest가 가리키는 현재 팩, 종류별 최신 3개, 고정(pinned) 팩을 기간과 상관없이 남깁니다. |
| 저장 항목 | 예보는 (격자, 예보 시각)마다 1행, 6개 항목만 저장하는 새 테이블로 바꿉니다. 읽는 곳이 없는 테이블 4개와 컬럼 약 24개를 지웁니다. `star_index_nightly`는 공개 페이지 순위 쿼리에 쓰이므로 5개 컬럼만 남겨 유지합니다. |
| S3 원문(`raw/kma/`, 120일) | 폐기합니다. `collect-only` 프로필도 폐기합니다. DB가 EC2에 항상 떠 있어서 둘 다 필요 없어졌습니다. 적중률에 필요한 예보 쪽 값은 수집할 때 `forecast_verification`에 바로 기록합니다(2.2). |
| 앱과 팩 | 팩 스키마 2와 manifest는 바이트 단위로 바뀌지 않아야 하고, 이것을 합격 기준으로 둡니다. iOS 앱은 DB를 읽지 않습니다. |
| 예상 효과 | 로컬 실측(3일 보관, 6개 항목)은 205k행, 31MB, DB 전체 39MB였습니다. 변경 후 예보는 약 2.2k행, 1MB 미만이고 DB 전체는 약 10~15MB로 예상합니다. 대부분은 PostgreSQL 기본 카탈로그입니다 [추정]. |
| 장기 비용 | (ADR-015로 대체: DB가 EC2 밖이라 t4g.micro를 다시 검토, 11.6) 2027-01부터 t4g.small + EBS + IPv4로 월 약 $21입니다 [추정]. 앱과 DB를 한 대에 두면 메모리가 모자라 t4g.micro로 내려갈 수 없습니다(5.3). |

---

## 2. 저장·보관 정책

### 2.1 보관 기준을 정하는 방법

모든 기준값은 Java에서 `asOf`(Instant) 하나를 기준으로 계산해 SQL에 값으로 넘깁니다. SQL의 `now()`나 `current_date`는 쓰지 않습니다.
- `night`: `IndexService.nightDateOf(asOf)`. 밤 날짜는 KST 12시를 기준으로 바뀝니다.
- `B_cut`: `LocalDateTime.ofInstant(asOf − 8일, ZoneId.systemDefault())`. BATCH 테이블의 `TIMESTAMP` 컬럼에는 JVM 기준 `LocalDateTime`이 그대로 저장되므로, 같은 기준으로 계산합니다.

### 2.2 테이블별 정책

행 수는 17개 시·도 기준입니다. 예보 1회 발표는 격자 하나에 약 84시간을 담는다고 봤습니다(실측 205k행 ÷ (6항목 × 3일 × 8회 × 17격자)) [추정].

| 대상 | 판정 | 남기는 컬럼 | 보관(삭제 조건) | 2일보다 긴 근거 | 예상 행 수 |
|---|---|---|---|---|---|
| `kma_forecast` | **삭제** → `kma_forecast_hour`로 대체 | — | — | — | 0 |
| `kma_forecast_issue` | **삭제** | — | — | 완결성 기록은 `BATCH_STEP_EXECUTION`의 WRITE_COUNT(성공 격자)와 FILTER_COUNT(실패 격자)로 옮깁니다. 최신 발표 시각은 `MAX(kma_forecast_hour.base_at)`로 구합니다. | 0 |
| `kma_forecast_hour` | **신설** | nx, ny, fcst_at, base_at, sky, pty, tmp, reh, wsd, pop | `fcst_at < asOf − 2일` | — | 17 × (48 + 84) ≈ **2.2k행, 1MB 미만** [추정] |
| `region` | 유지 | 전부 | 영구(정적 데이터) | 서비스 기준 데이터 | 17 |
| `kasi_riseset` | 축소 | region_id, locdate, sunset, civile, naute, aste | `locdate < night − 2` | — | 약 120 |
| `astro_night` | **삭제** | — | — | Astronomy Engine으로 언제든 다시 계산할 수 있는 캐시입니다. | 0 |
| `astro_crosscheck` | 축소 | region_id, night_date, field, diff_seconds | `night_date < night − 8` | G6/T16 "교차검증 p95 ≤2분 7일 연속", 관리자 교차검증 차트 | 약 540 |
| `kasi_astro_event` | 축소 | locdate, month_feature, seq, astro_time, title, event, remarks | `locdate <` 지난달 1일(기준: `night`의 달) | 월 달력에서 이전 달로 넘겨 보는 경우, 1일 새벽 00:30에는 밤 날짜가 아직 전달 말일인 경우, R3 이벤트 팩 | 약 75 |
| `kasi_special_day` | 축소 | locdate, date_kind, date_name, is_holiday | 위와 같음 | 위와 같음 | 약 15 |
| `kasi_lunar_day` | 축소 | sol_date, lun_year, lun_month, lun_day, lun_leap | `sol_date <` 지난달 1일 | 위와 같음 | 약 90 |
| `star_index_hourly` | **삭제** | — | — | 읽는 곳이 없고 다시 계산할 수 있습니다. | 0 |
| `star_index_nightly` | **축소 후 유지** | region_id, night_date, base_at, score, grade | `night_date < night − 2` | — (공개 페이지 순위를 QueryDSL로 조회, SERVICE-PLAN:768·773) | 17 × 3 ≈ 51 |
| `data_pack`(행)과 팩 파일 | 축소 + 정리 신설 | id, kind, version, night_date, base_at, path, sha256, bytes, published_at, **pinned** | `published_at < asOf − 8일`이면서 보존 집합에 속하지 않을 때. 보존 집합은 manifest `packs.*`의 모든 현재 버전, 종류별 최신 3개, `pinned=true`입니다. | G6 신선도(≤3.5h/6h) 7일 판정, 롤백. 행이 파일을 가리키지 못하는 상태가 생기지 않도록 파일도 행과 같은 규칙을 따릅니다. 8일분 파일은 약 2MB입니다 [추정]. | 약 64행, 파일 약 64개 |
| `etl_api_call` | 축소 | id, source, operation, request_key, http_status, result_code, **result_msg(80자, OK·NO_DATA가 아닐 때만)**, duration_ms, outcome, called_at | `called_at < asOf − 8일` | G6 "오류 ≤2% 7일", 쿼터 화면. 오류 원인은 `result_msg`로만 알 수 있습니다. | 약 2.2k |
| `BATCH_*` 6개 | 유지 + 정리 신설 | Spring Batch 원래 스키마(V1) | 인스턴스의 가장 최근 실행 `CREATE_TIME < B_cut`이고, 실행 중인 것이 없을 때 | G6 "모든 Job 7일 연속 성공", 관리자 실행 이력 | 실행 약 80건, 1MB 미만 |
| `verify_station` | **R1에 신설**(C9) | station_id, name, nx, ny | 영구(10행, 정적) | 적중률 계산용 관측소-격자 매핑(SERVICE-PLAN 8.4) | 10 |
| `forecast_verification` | **R1에 신설**(C9, R3 설계를 앞당김) | 3.3 참고 | `night_date < night − 32` | 공개 적중률 30일 창과 n ≥ 30, T13. 예보의 과거 발표는 나중에 받을 수 없습니다 [가능성 높음]. | 10 × 2 × 33 ≈ 660 |
| S3 `raw/kma/`, `raw/kasi/` | **폐기**(계획 취소) | — | — | 적중률에 필요한 값은 위 스냅숏에 모두 들어 있습니다. | 0 |
| S3 `backup/db/` | 신설 | 전체 `pg_dump` | 수명주기 7일 | 복구용 | 7개, 각 약 1MB [추정] |

**적중률 스냅숏을 두는 이유 [해석]:** `kma_forecast_hour`는 시각마다 최신 값만 남깁니다. 그래서 17시 발표의 21~00시 값은 20시와 23시 발표에 덮입니다. 이 값을 나중에 되살릴 수 없으므로, 17시 발표와 전날 23시 발표를 수집하는 시점에 관측소 격자의 4개 시각 SKY/PTY를 `forecast_verification`에 바로 씁니다. ASOS 관측값은 과거 조회가 되므로 R3의 `forecastVerifyJob`(07:00)이 나중에 채웁니다 [가능성 높음, SERVICE-PLAN 8.1].

**관측소 수집 시작 기한:** 늦어도 **11/28**입니다. R3 공개 전에 30일 창을 채우려면 이때는 시작해야 합니다. 목표는 R1 첫 주(11/2~11/6)입니다.

---

## 3. 스키마 변경 (Flyway)

모든 마이그레이션은 표준 PostgreSQL만 씁니다. 슈퍼유저가 아닌 소유자 계정으로 적용할 수 있어야 합니다(6.1 `MigrationTest`).

### 3.1 `V5__forecast_hour.sql` (C3)

```sql
-- DB-PLAN 3.1: 단기예보는 (격자, 예보시각)당 1행에 서비스가 읽는 6개 항목만 둔다.
-- 각 값은 "가장 최근 발표의 결측 아닌 값"이다. base_at은 이 행에 값을 준 가장 최근 발표다.
CREATE TABLE kma_forecast_hour (
    nx       SMALLINT     NOT NULL,
    ny       SMALLINT     NOT NULL,
    fcst_at  TIMESTAMPTZ  NOT NULL,
    base_at  TIMESTAMPTZ  NOT NULL,
    sky      SMALLINT,          -- 1/3/4
    pty      SMALLINT,          -- 0~4
    tmp      NUMERIC(4,1),      -- °C. REAL을 쓰면 1.8이 1.7999…로 읽혀 팩 바이트가 바뀐다
    reh      SMALLINT,          -- %
    wsd      NUMERIC(4,1),      -- m/s. 연장 구간 코드값은 NULL(이전 발표 값 유지)
    pop      SMALLINT,          -- %
    PRIMARY KEY (nx, ny, fcst_at)
);

INSERT INTO kma_forecast_hour (nx, ny, fcst_at, base_at, sky, pty, tmp, reh, wsd, pop)
SELECT nx, ny, fcst_at, MAX(base_at),
  ((array_agg(value_num ORDER BY base_at DESC) FILTER (WHERE category = 'SKY' AND value_num IS NOT NULL))[1])::smallint,
  ((array_agg(value_num ORDER BY base_at DESC) FILTER (WHERE category = 'PTY' AND value_num IS NOT NULL))[1])::smallint,
  ((array_agg(value_num ORDER BY base_at DESC) FILTER (WHERE category = 'TMP' AND value_num IS NOT NULL))[1])::numeric(4,1),
  ((array_agg(value_num ORDER BY base_at DESC) FILTER (WHERE category = 'REH' AND value_num IS NOT NULL))[1])::smallint,
  ((array_agg(value_num ORDER BY base_at DESC) FILTER (WHERE category = 'WSD' AND value_num IS NOT NULL))[1])::numeric(4,1),
  ((array_agg(value_num ORDER BY base_at DESC) FILTER (WHERE category = 'POP' AND value_num IS NOT NULL))[1])::smallint
FROM kma_forecast
WHERE category IN ('SKY','PTY','TMP','REH','WSD','POP') AND fcst_at >= now() - interval '2 days'
GROUP BY nx, ny, fcst_at
HAVING bool_or(value_num IS NOT NULL);

DROP TABLE kma_forecast;          -- V3/V4 인덱스도 함께 삭제된다
DROP TABLE kma_forecast_issue;    -- 완결성은 BATCH_STEP_EXECUTION WRITE/FILTER_COUNT, 최신 발표는 MAX(base_at)
```

- 추가 인덱스는 두지 않습니다. 조회는 PK 범위 조회로 처리되고, 보존 정리는 수천 행을 순차로 훑으면 됩니다 [추정].

### 3.2 `V6__store_only_needed.sql` (C4)

```sql
-- DB-PLAN 2: 읽는 곳이 없는 테이블과 컬럼을 지운다. 값은 다시 계산하거나 KASI에서 다시 받을 수 있다.
DROP TABLE star_index_hourly;
DROP TABLE astro_night;

ALTER TABLE star_index_nightly
  DROP COLUMN best_from, DROP COLUMN best_to, DROP COLUMN contrib, DROP COLUMN reasons, DROP COLUMN computed_at;
ALTER TABLE kasi_riseset
  DROP COLUMN kasi_location, DROP COLUMN sunrise, DROP COLUMN suntransit, DROP COLUMN moonrise,
  DROP COLUMN moontransit, DROP COLUMN moonset, DROP COLUMN civilm, DROP COLUMN nautm, DROP COLUMN astm,
  DROP COLUMN fetched_at;
ALTER TABLE astro_crosscheck DROP COLUMN kasi_at, DROP COLUMN computed_at, DROP COLUMN checked_at;
ALTER TABLE kasi_astro_event DROP COLUMN fetched_at;
ALTER TABLE kasi_special_day DROP COLUMN kst, DROP COLUMN sun_longitude, DROP COLUMN fetched_at;
ALTER TABLE kasi_lunar_day   DROP COLUMN lun_iljin, DROP COLUMN fetched_at;
ALTER TABLE etl_api_call     DROP COLUMN item_count;
UPDATE etl_api_call SET result_msg = NULL WHERE outcome IN ('OK', 'NO_DATA');
ALTER TABLE etl_api_call     ALTER COLUMN result_msg TYPE VARCHAR(80) USING left(result_msg, 80);
ALTER TABLE data_pack        DROP COLUMN raw_bytes, DROP COLUMN region_count,
                             ADD COLUMN pinned BOOLEAN NOT NULL DEFAULT false;
```

- `DROP COLUMN`은 공간을 곧바로 돌려주지 않습니다. 테이블이 수백 KB 이하라서 무시합니다.
- 이 마이그레이션은 되돌릴 수 없습니다. KASI 값은 다시 받을 수 있고, 예보는 2일이면 새로 채워집니다.

### 3.3 `V7__forecast_verification.sql` (C9, R1 첫 주)

관측소 10곳의 번호와 격자는 R1 첫 주에 결측률을 조사한 뒤 정합니다(G13 선행 조건).

```sql
CREATE TABLE verify_station (
    station_id  INTEGER      PRIMARY KEY,     -- ASOS 지점번호
    name        VARCHAR(40)  NOT NULL,
    nx          SMALLINT     NOT NULL,
    ny          SMALLINT     NOT NULL
);
INSERT INTO verify_station VALUES (…);       -- 10행, regions.csv 매핑과 같아야 함(테스트)

-- binary-clear-v2(SERVICE-PLAN 8.4). 예보 쪽은 수집할 때 기록하고, 관측 쪽은 R3 forecastVerifyJob이 채운다.
CREATE TABLE forecast_verification (
    night_date            DATE         NOT NULL,
    station_id            INTEGER      NOT NULL REFERENCES verify_station (station_id),
    issue_kind            VARCHAR(3)   NOT NULL CHECK (issue_kind IN ('d17', 'p23')),  -- 당일 17시 / 전날 23시
    issued_at             TIMESTAMPTZ  NOT NULL,
    sky_codes             CHAR(4)      NOT NULL,   -- 21·22·23·00시 SKY, 결측은 '-'
    pty_codes             CHAR(4)      NOT NULL,
    forecast_clear        BOOLEAN      NOT NULL,   -- 4개 시각 모두 SKY=1, PTY=0
    observed_cloud_tenths NUMERIC(3,1),
    n_obs                 SMALLINT,
    hit                   BOOLEAN,
    PRIMARY KEY (night_date, station_id, issue_kind)
);
```

- SERVICE-PLAN 8.2의 `grid_id`와 `lead_hours`는 넣지 않습니다. 각각 `verify_station`과 `issue_kind`에서 구할 수 있기 때문입니다.
- 원래 SKY/PTY 코드를 그대로 남기므로, 판정 규칙이 바뀌어도 다시 계산할 수 있습니다.

---

## 4. 코드 변경

경로는 모두 `backend/src/main/java/dev/starindex/` 아래입니다.

### 4.1 수집: 필요한 항목만 저장 (C3)

**`etl/kma/KmaForecastClient.java`**
- 페이지 받기와 `items.size() == totalCount` 완결성 검사는 그대로 둡니다.
- 다음을 추가합니다.
  ```java
  public record Hour(Instant fcstAt, Short sky, Short pty, BigDecimal tmp, Short reh, BigDecimal wsd, Short pop)
  public static List<Hour> hours(List<Item> items)
  ```
  - SKY, PTY, TMP, REH, WSD, POP만 모아 `fcstAt` 순으로 정렬합니다.
  - 6개 값이 모두 null인 시각은 버립니다.
  - 정수 항목(SKY, PTY, REH, POP)은 `Math.round`로 바꿉니다.
  - TMP와 WSD는 `BigDecimal.valueOf(d).setScale(1, HALF_UP)`로 바꿉니다.
- 선택 정리: `NUMERIC`을 6개로 줄이고 `amount()`, PCP·SNO 처리를 지웁니다. 이 경우 `DataGoKrClientTest`의 PCP 단언을 WSD 연장 구간 단언으로 바꿉니다.

**`etl/EtlRepository.upsertForecast(Result r)`**
- `hours(r.items())`를 `batchUpdate`로 넣습니다.
  ```sql
  INSERT INTO kma_forecast_hour AS t (nx, ny, fcst_at, base_at, sky, pty, tmp, reh, wsd, pop)
  VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  ON CONFLICT (nx, ny, fcst_at) DO UPDATE SET
    sky = CASE WHEN EXCLUDED.base_at >= t.base_at THEN COALESCE(EXCLUDED.sky, t.sky) ELSE COALESCE(t.sky, EXCLUDED.sky) END,
    -- pty, tmp, reh, wsd, pop도 같은 형태
    base_at = GREATEST(t.base_at, EXCLUDED.base_at)
  ```
- 발표가 순서대로 들어오면 결과는 지금의 `DISTINCT ON … (value_num IS NULL), base_at DESC`와 같습니다. 늦게 들어온 옛 발표는 빈 칸만 채웁니다.
- `kma_forecast_issue` INSERT와 `countIssueCells`를 지웁니다.

**`etl/EtlJobsConfig.forecastFetchStep`**
- 완결성을 SQL과 QueryDSL로 집계할 수 있도록 숫자 컬럼에 남깁니다.
  ```java
  c.incrementWriteCount(report.ok());
  c.incrementFilterCount(report.cells() - report.ok());
  ```
- 관리자 품질 화면은 `WRITE_COUNT / (WRITE_COUNT + FILTER_COUNT)`로 완결성을 계산합니다. 이 정의를 ETL.md에 적습니다.

**`etl/ForecastIngestService.java`**: summary 문구를 "N행"에서 "시간대 N행"으로 바꿉니다.

### 4.2 조회와 저장 축소 (C3·C4)

**`EtlRepository.latestForecast(int nx, int ny, Instant from, Instant to)`**
- `categories` 인자를 지웁니다.
- `kma_forecast_hour`를 읽습니다.
- 반환 형식 `Map<Instant, Map<String, Double>>`와 키 "SKY"… 는 그대로 둡니다.
- smallint는 `getInt` + `wasNull`로, numeric은 `getBigDecimal().doubleValue()`로 읽고, null은 `put(c, null)`로 넣습니다.

**`EtlRepository.latestBaseAt`**: `SELECT MAX(base_at) FROM kma_forecast_hour WHERE nx=? AND ny=?`로 바꿉니다.

**`index/IndexService.persist`**
- 유지합니다.
- `upsertIndex(regionId, nightDate, base, score, grade)`로 5개 컬럼만 씁니다.
- `JsonMapper` 의존성을 지웁니다.

**`etl/AstroService`**
- `computeNights`를 지웁니다.
- `nightFor`는 DB 없이 `AstroCalculator.night(nightDate, lat, lon, 0)`만 부릅니다.
- `crosscheck`는 `upsertCrosscheck(regionId, date, field, diffSeconds)`를 부릅니다.

**`EtlRepository` 나머지**
- 지울 것: `upsertNight`, `findNight`, `inst`, `purge`
- 컬럼을 줄일 것: `upsertRiseSet`, `upsertCrosscheck`, `upsertAstroEvents`, `upsertSpecialDays`, `upsertLunar`, `insertPack`, `upsertIndex`

**기타**
- `pack/PackPublisher.java`: `insertPack` 인자 2개를 뺍니다. `Published`와 로그는 그대로 둡니다.
- `datagokr/DataGoKrConfig.jdbcApiCallRecorder`
  - `item_count`를 뺍니다.
  - `result_msg`는 outcome이 `OK`나 `NO_DATA`이면 null로, 그 밖에는 `truncate(…, 80)`으로 저장합니다.
- `EtlJobsConfig`
  - `astroComputeStep`을 지우고, `astroDailyJob`을 `retention → serviceKeyDecider → kasiRiseSet → crosscheck` 순서로 바꿉니다. javadoc 표도 고칩니다.
  - `indexPublishStep`의 실패 메시지에 "저장 예보는 2일만 보관하므로 이틀보다 이전 밤은 다시 만들 수 없습니다"를 추가합니다.

### 4.3 보존 정리 (C5)

**신규 `etl/RetentionService.java`**
- 의존성: `JdbcTemplate`, `TransactionTemplate`, `JobRepository`, `PackStore`, `JsonMapper`, `EtlProperties.Etl`
- 시그니처: `Result purge(Instant asOf)`. `Result(LinkedHashMap<String,Integer> deleted, List<String> warnings)`를 돌려줍니다.
- 각 항목은 **따로 try/catch**합니다. 한 항목이 실패해도 나머지는 진행하고, 실패 내용은 `warnings`에 남깁니다.

항목별 처리는 다음과 같습니다(기준값은 2.1).

1. `kma_forecast_hour`, `kasi_riseset`, `star_index_nightly`, `astro_crosscheck`, `etl_api_call`, `kasi_*` 3개, (C9 이후) `forecast_verification`: 2.2 표의 조건대로 `DELETE … WHERE col < ?`
2. **팩**
   - (a) 짧은 트랜잭션 안에서 `pg_advisory_xact_lock(PackPublisher.MANIFEST_LOCK)`을 겁니다. manifest를 읽어 `packs.*`의 모든 현재 버전을 모읍니다. 그다음 후보를 고르고 커밋합니다. 락 안에서는 네트워크 목록 조회나 삭제를 하지 않습니다. 후보 쿼리는 다음과 같습니다.
     ```sql
     SELECT id, kind, version, path FROM (
       SELECT *, row_number() OVER (PARTITION BY kind ORDER BY published_at DESC) rn FROM data_pack) p
     WHERE rn > :keepMin AND NOT pinned AND published_at < :cutoff8d AND NOT (version = ANY(:current))
     ```
   - (b) 락 밖에서 후보마다 `store.delete(path)`를 한 뒤 `DELETE FROM data_pack WHERE id=? AND NOT pinned`를 합니다. 파일 삭제가 실패하면 행이 남아 다음 날 다시 시도합니다.
   - (c) 고아 파일: `store.list("packs/")` 가운데 `packs/{index,events,spots}/`에 있고, `data_pack.path`에 없고, 현재 버전이 아니고, `lastModified < asOf − 8일`인 것만 지웁니다. 버전 이름의 날짜는 발행일이 아니라 밤 날짜이므로 기준으로 쓰지 않습니다.
   - (d) 경쟁 상태를 막기 위해 관리자 롤백(`packs/rollback`)은 "종류별 최신 3개와 pinned"로만 되돌릴 수 있게 제한합니다. 이 두 집합은 절대 삭제되지 않으므로, 삭제와 롤백이 부딪히지 않습니다.
3. **Batch 메타데이터**
   - 대상 인스턴스를 고릅니다.
     ```sql
     SELECT i.JOB_INSTANCE_ID FROM BATCH_JOB_INSTANCE i JOIN BATCH_JOB_EXECUTION e USING (JOB_INSTANCE_ID)
     GROUP BY i.JOB_INSTANCE_ID
     HAVING MAX(e.CREATE_TIME) < :B_cut AND bool_and(e.STATUS NOT IN ('STARTING','STARTED','STOPPING'))
     ```
   - 인스턴스마다 `jobRepository.deleteJobInstance(jobRepository.getJobInstance(id))`를 부릅니다. 표준 API를 쓰므로 FK 순서는 Spring Batch가 맞춥니다.
   - 이 메서드가 실행 기록까지 함께 지우는지는 테스트로 확인합니다 [가능성 높음]. 함께 지우지 않으면 `deleteJobExecution`(실행마다) → `deleteJobInstance` 순서로 부릅니다.

**`EtlJobsConfig.retentionStep`**
- `purge(Instant.now())`를 부릅니다.
- summary는 "보존 정리 {…} (예보 2일, 이력·발행 8일, 달력 지난달부터, 팩 현재·최신 3·고정 유지)"로 둡니다.
- `warnings`가 있으면 summary 뒤에 붙이고, 경고 로그를 남기고, `ExitStatus("COMPLETED_WITH_WARNINGS")`로 둡니다. 단계와 Job은 COMPLETED로 끝나므로 G6의 "7일 연속 성공"이 끊기지 않습니다.
- 흐름 전이가 이 exit status로도 다음 단계로 가는지 테스트합니다.

**`etl/EtlProperties.Etl`**

| 속성 | 기본값 | 하한 | 하한을 어기면 |
|---|---|---|---|
| `forecastRetentionDays` | 2 | 2(어젯밤 재발행에 필요) | `IllegalArgumentException` |
| `auditRetentionDays` | 8 | 8(G6 7일 + 1) | `IllegalArgumentException` |
| `packKeepMin` | 3 | — | — |
| `verifyRetentionDays`(C9) | 32 | — | — |

**`pack/PackStore`**
- `void delete(String path)`와 `List<Entry> list(String prefix)`를 추가합니다. `record Entry(String path, Instant lastModified)`입니다.
- W3의 S3 구현은 `DeleteObject`와 `ListObjectsV2`(`LastModified`)를 씁니다.
- `packs/`에는 S3 수명주기 만료를 걸지 않습니다. ETL이 멈춰 있을 때 현재 팩이 지워질 수 있기 때문입니다.

**`pack/LocalPackStore`**
- `delete`: `resolve()`로 경로 이탈을 검사한 뒤 `deleteIfExists`를 하고, 비어 있는 버전 디렉터리도 지웁니다.
- `list`: `Files.walk`로 찾고, 수정 시각은 `Files.getLastModifiedTime`으로 채웁니다.

**팩 고정(pin)**
- `scripts/etl.sh pin|unpin <version>`: 로컬에서 compose `psql`로 실행합니다.
- `deploy/postgres/pin.sh <version>`: EC2에서 실행합니다. 접속은 `DB_URL`(Neon, TLS)과 SSM 비밀번호를 씁니다.
- 데모 v1 팩(SERVICE-PLAN 5.9)은 **발행하는 즉시 pin**합니다.
- M0 기간에는 팩 삭제 코드가 아직 없으므로 파일은 안전합니다. 10/20 이후 C5를 배포하기 **전에** 데모 버전을 pin합니다.

### 4.4 설정 (C6)

> 연결 풀 값은 ADR-015로 바뀌었다: `minimum-idle: 0`, `idle-timeout: 60000`, `keepalive-time: 0`(11.2). 아래 블록은 당시 계획이다.

**`application.yml`**
```yaml
spring.datasource.hikari:
  maximum-pool-size: 5       # 배치 + 관리자 웹. PG max_connections=20
  minimum-idle: 1
  idle-timeout: 10m
starindex.etl:
  forecast-retention-days: 2   # kma_forecast_hour, kasi_riseset, star_index_nightly
  audit-retention-days: 8      # etl_api_call, astro_crosscheck, data_pack+파일, BATCH_*
  pack-keep-min: 3
```
- `forecast-retention-days`에 달린 주석 "raw copies go to S3 in W3"는 지웁니다(S3 원문 폐기).

**운영 JVM 옵션** (`deploy/app/app.env`)
```
JAVA_OPTS=-Xmx512m -Xss512k -XX:+UseSerialGC -XX:MaxMetaspaceSize=192m -XX:ReservedCodeCacheSize=64m -XX:MaxDirectMemorySize=64m -XX:+ExitOnOutOfMemoryError -Xlog:gc:file=/var/log/starindex/gc.log:time,uptime:filecount=3,filesize=5m
MALLOC_ARENA_MAX=2
```
- SerialGC를 명시하는 이유: vCPU 2개, 작은 힙, 배치와 관리자 위주라서 일시 정지 시간은 문제가 되지 않고, G1의 부가 메모리를 아낄 수 있습니다 [해석].

**`scripts/etl.sh`**
- `JAVA_OPTS`를 `java` 명령에 넘깁니다.
- `pin`과 `unpin`을 추가합니다.
- `publish` 설명에 "저장 예보 2일: 이틀보다 이전 밤은 만들 수 없음"을 추가합니다.
- `astro` 설명에서 "Astronomy Engine nights"를 지웁니다.

**신규 `scripts/ec2sim.sh`**: 6.2 참고

**로케일 통일**
- `IntegrationTestBase`에 `.withEnv("POSTGRES_INITDB_ARGS", "--locale=C --encoding=UTF8")`를 추가합니다.
- `backend/docker-compose.yml`의 postgres 서비스에도 같은 설정을 넣습니다. 새 볼륨부터 적용됩니다.
- R3 순위 쿼리는 동점일 때 `ORDER BY score DESC, region.id`로 순서를 정합니다.

### 4.5 적중률 스냅숏 (C9, R1 첫 주, SERVICE-PLAN 7.3의 "raw collect-only 1.0"을 대체)

- `ForecastIngestService`가 17시 발표와 23시 발표 때에만 `verify_station` 격자 10개를 추가로 받습니다. 쿼터는 하루 +20회입니다.
- 받은 결과는 `kma_forecast_hour`에 넣지 않습니다. 대상 밤의 21·22·23·00시 SKY/PTY만 뽑아 `forecast_verification`에 upsert합니다.
  - 17시 발표는 `d17`로 당일 밤에 씁니다.
  - 23시 발표는 `p23`으로 다음 날 밤에 씁니다.
- 관측소 격자의 성공과 실패는 지수 완결성 게이트에서 빼고, 별도 summary에 남깁니다.
- 폐기할 것: `collect-only` 프로필, S3 `raw/`, `StarIndex/RawCollectedAgeMinutes` 지표. R1~R2에도 EC2는 이미 켜 두기로 되어 있으므로, 대신 전체 ETL을 24/7로 돌립니다.

---

## 5. EC2 직접 설치 구성

> **ADR-015로 대체(2026-10-01).** 운영 DB는 Neon이고, 이 장의 서버 설치·튜닝·pg_hba·로컬 복구는 쓰지 않는다. 관련 파일(`deploy/postgres/install.sh`, `pg_hba.conf`, `tune.sql`)은 지웠다(git 이력 db5aeb4·78c8ffa). 백업(5.5)과 IAM(5.4 표)은 11장에서 그대로 쓴다.

### 5.1 설치 방식

| 선택지 | 판정 | 근거 |
|---|---|---|
| AL2023 core `postgresql18` | **채택** | 2023.10.20260330 릴리스 노트의 Core New Packages에 `postgresql18-18.3-1.amzn2023.0.1`이 있습니다 [확실, docs.aws.amazon.com/linux/al2023/release-notes/relnotes-2023.10.20260330.html]. |
| PGDG 저장소 | 제외 | Amazon Linux가 지원 목록에 없습니다 [가능성 높음, postgresql.org/download/linux/redhat]. |
| Docker `postgres:18` | 제외 | dockerd와 containerd가 메모리를 더 쓰고, 업데이트 경로가 하나 더 생깁니다. |

- 서브패키지 이름(`-server`), 단위 이름, 데이터 디렉터리, initdb 방법은 설치할 때 `dnf list 'postgresql18*'`와 `rpm -ql`로 확인합니다 [불확실].
- 보안 업데이트는 자동으로 오지 않습니다 [가능성 높음, AL2023 deterministic upgrades]. 월 1회, 또는 High·Critical ALAS가 나오면 다음을 실행합니다. 마이너 업데이트는 덤프와 복원이 필요 없습니다.
  ```bash
  sudo dnf check-release-update
  sudo dnf upgrade --releasever=<최신>
  sudo systemctl restart postgresql
  ```

### 5.2 설정 (`deploy/postgres/tune.sql`, `ALTER SYSTEM`)

| 설정 | 값 | 이유 |
|---|---|---|
| listen_addresses | `'localhost'` | 외부 접속 없음 |
| max_connections | 20 | |
| shared_buffers | 128MB | |
| effective_cache_size | 256MB | |
| work_mem | 4MB | |
| maintenance_work_mem | 32MB | |
| huge_pages | off | |
| max_wal_size / min_wal_size | 256MB / 64MB | |
| checkpoint_timeout | 15min | |
| password_encryption | scram-sha-256 | |
| timezone / log_timezone | `'UTC'` / `'Asia/Seoul'` | |
| idle_in_transaction_session_timeout | 5min | |
| log_min_duration_statement | 1s | |
| autovacuum | 기본값 | |

**역할과 DB 생성** (EC2와 RDS 공통, 관리자 계정으로 실행)
```sql
CREATE ROLE starindex LOGIN;                 -- 비밀번호는 아래처럼 stdin으로 설정
GRANT starindex TO CURRENT_USER;             -- RDS 마스터는 슈퍼유저가 아니므로 필요, EC2 postgres에서는 무해
CREATE DATABASE starindex OWNER starindex TEMPLATE template0 ENCODING 'UTF8' LOCALE 'C';
```
- 근거: "To create a database owned by another role, you must be able to SET ROLE to that role."입니다 [확실, postgresql.org/docs/18/sql-createdatabase.html]. CREATEROLE 사용자가 새 역할에 SET 권한을 자동으로 받지 않는다는 점(`createrole_self_grant` 기본값이 빈 문자열)은 [확실, PG 18.6에서 재현]입니다.
- **실행 결과(10-01):** 위 SQL 그대로는 RDS형 마스터(슈퍼유저 아님, CREATEROLE CREATEDB)에서 `must be able to SET ROLE "starindex"`로 실패했습니다. 역할을 만든 계정은 멤버(ADMIN)이지만 SET 권한이 없기 때문입니다. 실제 파일 `deploy/postgres/create-db.sql`은 `pg_has_role(current_user, 'starindex', 'SET')`이 거짓일 때만 `GRANT starindex TO CURRENT_USER WITH SET TRUE`를 실행하고, 역할·DB 생성도 `\gexec`로 멱등하게 합니다.
- 비밀번호는 명령행 인자로 넘기지 않고 `printf "ALTER ROLE starindex PASSWORD '%s';" "$PW" | psql -v ON_ERROR_STOP=1`처럼 stdin으로 넘깁니다.

**OOM 대비**
- 계획: drop-in(`OOMScoreAdjust=-900`, `PG_OOM_ADJUST_FILE`, `PG_OOM_ADJUST_VALUE=0`).
- **실행 결과(10-01): drop-in을 두지 않습니다.** AL2023의 `postgresql.service`에 이미 `OOMScoreAdjust=-1000`과 같은 `PG_OOM_ADJUST_*`가 들어 있습니다 [확실, 컨테이너에서 단위 파일 확인]. -900 drop-in은 보호를 오히려 약하게 만듭니다.
- 메모리가 부족하면 postmaster 대신 java가 먼저 종료되고, `Restart=on-failure`로 다시 뜹니다 [가능성 높음].

### 5.3 메모리 예산 (t4g.small, MemTotal 약 1,900MiB [가능성 높음])

| 구성 | 예산(MiB) | 내역 |
|---|---|---|
| OS, 커널, systemd, journald | 약 150 | [추정] |
| SSM 에이전트 + CodeDeploy 에이전트 | 약 120 | [추정] |
| JVM | 약 820~900 | 힙 512 + Metaspace 약 130 + 코드 캐시 약 50 + 스레드 약 40 + 다이렉트 메모리(Netty/Lettuce) 64 이하 + GC·malloc 약 40 [추정] |
| Valkey | 약 140 | `maxmemory 128mb`, `--save ""` |
| PostgreSQL | 약 200~250 | shared_buffers 128 + 백엔드 1~5개 × 약 8 + 보조 프로세스 약 40 [추정] |
| **여유(MemAvailable)** | **약 340~470** | 목표: 7일 동안 ≥300MiB, 스왑 사용이 거의 0 |
| 스왑 | 2GB 파일, `vm.swappiness=10` | |

- 힙 조정 기준: GC 로그에서 Full GC 직후 힙이 350MB를 넘으면 `-Xmx640m`으로 올리되, 여유 ≥300MiB 조건을 다시 확인합니다.
- Metaspace 조정 기준: NMT로 확인한 committed 값이 160MB를 넘으면 상한을 256m로 올립니다.
- PLAN 3.6의 t4g.micro 전환 조건은 폐지합니다.

### 5.4 보안

- **네트워크:** `listen_addresses='localhost'`로 둡니다. SG에는 5432 규칙이 없습니다.
- **`deploy/postgres/pg_hba.conf`로 기본 파일을 통째로 교체합니다.** RHEL 계열 기본 파일의 `ident`를 피하기 위해서입니다 [가능성 높음].
  ```
  local  all        postgres                   peer
  local  starindex  starindex                  scram-sha-256
  host   starindex  starindex  127.0.0.1/32    scram-sha-256
  host   starindex  starindex  ::1/128         scram-sha-256
  ```
- **비밀 값:** SSM SecureString(Standard 등급)을 씁니다.
  - `/starindex/db/password`: `openssl rand -base64 32`로 만듭니다.
  - `/starindex/data-go-kr/service-key`
- **앱 기동:** `deploy/app/start.sh`가 두 비밀을 읽어 `DB_PASSWORD`와 `DATA_GO_KR_SERVICE_KEY` 환경 변수로 넘긴 뒤 `exec java $JAVA_OPTS -jar /opt/starindex/app.jar`를 실행합니다.
- **비밀이 아닌 설정:** `DB_URL=jdbc:postgresql://127.0.0.1:5432/starindex`와 `DB_USERNAME=starindex`는 `/etc/starindex/app.env`(EnvironmentFile)에 둡니다. RDS로 바꿀 때는 이 파일의 `DB_URL` 한 줄만 고칩니다.

**IAM 인스턴스 역할** (`deploy/aws/iam-instance-db.json`, PLAN 3.4·3.5에도 같은 내용을 반영)

| 권한 | 범위 |
|---|---|
| `s3:PutObject`, `s3:GetObject` | `backup/db/*` |
| `s3:DeleteObject` | `packs/index/*`, `packs/events/*`, `packs/spots/*`만. manifest, legal, backup에는 주지 않습니다. |
| `s3:ListBucket` | Condition `s3:prefix` StringLike `["backup/db/*", "packs/*"]`. 기존 `raw/` 조건은 지웁니다. |
| `s3:PutObject` | `raw/*` 권한은 지웁니다. `packs/*` 쓰기는 기존대로 둡니다. |
| `ssm:GetParameter(s)` | `/starindex/*`(기존) |
| `kms:Decrypt` | `aws/ssm` 키. Condition `kms:ViaService=ssm.ap-northeast-2.amazonaws.com`. 필요한지는 [불확실]이지만 넣어도 해가 없습니다. |

### 5.5 백업 (전체 `pg_dump` → S3)

`deploy/postgres/backup.sh`와 `deploy/systemd/starindex-pgdump.{service,timer}`를 둡니다.
- 타이머: `OnCalendar=*-*-* 19:40:00 UTC`(KST 04:40)와 `Persistent=true`. 시간대 접미사 대신 UTC로 적어 systemd 버전 문제를 피합니다.
- 명령. 예보까지 포함해 전체를 덤프하고, 소유자 계정으로 접속하므로 EC2와 RDS에서 똑같이 동작합니다.
  ```bash
  PGPASSWORD="$(aws ssm get-parameter --with-decryption --name /starindex/db/password --query Parameter.Value --output text)" \
    pg_dump -Fc -h 127.0.0.1 -U starindex starindex > /var/tmp/starindex.dump
  aws s3 cp /var/tmp/starindex.dump s3://starindex-{acct}/backup/db/starindex-$(date -u +%F).dump
  ```
- `deploy/aws/s3-lifecycle.json`: `backup/db/`는 7일, `deploy/backend/`는 90일 뒤 만료시킵니다. `put-bucket-lifecycle-configuration`은 버킷 설정 전체를 바꾸므로 두 규칙을 한 파일에 둡니다.
- 버킷 정책은 CloudFront에 `packs/*`와 `legal/*`만 열어 두므로 백업은 공개되지 않습니다.

### 5.6 복구 (`deploy/postgres/restore.sh <날짜|latest> [대상DB]`)

1. 새 인스턴스라면 `install.sh`를 먼저 실행합니다.
2. `sudo systemctl stop starindex`
3. 관리자 계정으로 `dropdb` 후 5.2의 SQL로 DB를 다시 만듭니다.
4. `latest`이면 `aws s3 ls`로 최신 파일을 고른 뒤 받고(`ListBucket` 필요), 다음 명령으로 복원합니다.
   ```bash
   pg_restore --no-owner --no-privileges --exit-on-error -h 127.0.0.1 -U starindex -d <대상DB> r.dump
   ```
5. `sudo systemctl start starindex`. Flyway는 검증만 하고 끝납니다.

**합격 기준**
- `SELECT max(version::int) FROM flyway_schema_history` = 최신 버전
- `region` = 17행
- `BATCH_JOB_EXECUTION` 건수가 덤프 시점과 같음
- manifest `packs.*`의 모든 현재 version이 `data_pack`에 있음
- **같은 nightDate로 publish하면 덤프 시점의 최신 팩과 같은 version이 나옴**

**복구 리허설은 1회 필수입니다.** 같은 EC2의 `starindex_restoretest` DB에 복원하고, 그 DB를 가리켜 스케줄을 끈 상태로 publish를 실행해 봅니다. 결과는 6.3에 기록합니다.

### 5.7 DB 전환 절차 (RDS ↔ EC2, 방향에 상관없이 필수)

1. `sudo systemctl stop starindex`. ETL과 관리자 쓰기를 멈춥니다.
2. 원본 DB에서 5.5의 `pg_dump`를 실행합니다.
3. 대상 DB에 5.2의 SQL로 역할과 DB를 만들고 5.6의 `pg_restore`를 실행합니다.
   - RDS가 대상이면 db.t4g.micro, PG 18, Single-AZ, gp3 20GB, 퍼블릭 액세스 off로 만들고, SG는 EC2 SG에서 오는 5432만 허용합니다.
4. 5.6의 합격 기준 가운데 앞의 네 가지를 확인합니다.
5. `/etc/starindex/app.env`의 `DB_URL`을 바꿉니다. RDS이면 `jdbc:postgresql://<endpoint>:5432/starindex?sslmode=require`를 씁니다. RDS PG15 이상은 `rds.force_ssl=1`이 기본이라는 것은 [가능성 높음]입니다.
6. `sudo systemctl start starindex`를 한 뒤 파이프라인을 1회 실행해 확인합니다.
7. RDS를 떠날 때는 최종 스냅샷을 만든 뒤 **삭제**합니다. RDS는 정지해도 7일 뒤 자동으로 다시 시작하고, 정지 중에도 스토리지 요금이 나옵니다 [확실, docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_StopInstance.html].

### 5.8 산출물 파일

ADR-014 구현(10-01 오전) 기준의 파일입니다. 계획과 다른 점은 10장에 있습니다. ADR-015 이후의 실제 구성(`deploy/ec2/install.sh`, `bootstrap-db.sh`, 새 `restore.sh`, 서버 파일 삭제)은 11.3~11.5입니다.

| 파일 | 내용 |
|---|---|
| `deploy/postgres/install.sh` | 멱등 스크립트. app.env 확인 → 패키지 → 앱 사용자·디렉터리(app.env `root:starindex 0640`) → `daemon-reload` → initdb(locale C, UTF8) → pg_hba 교체 → `enable --now` → `tune.sql` → 재시작 → `create-db.sql` → SSM 비밀번호(stdin) → 운영 스크립트·유닛 설치 → 백업 타이머(S3_BUCKET이 있을 때) → 스왑 2GiB·swappiness 10 → 확인 출력. SQL 파일은 root가 열어 stdin으로 넘깁니다(체크아웃이 0700 홈에 있어도 동작). |
| `deploy/postgres/{create-db.sql,lib.sh}` | 역할·DB 생성(5.2, EC2·RDS 공통). `DB_URL`에서 `PG*` 도출, SSM 읽기, `as_postgres`(관리 명령은 앱의 `PG*`를 물려받지 않음) |
| `deploy/postgres/{pg_hba.conf,tune.sql,backup.sh,restore.sh,pin.sh}` | 5.2~5.6. `restore.sh`는 아카이브를 먼저 검증하고, 기존 DB를 `<db>_prev`로 남겨 두었다가 실패하면 되돌리고 앱을 다시 켭니다. 대상은 운영 DB와 `starindex_restoretest`만 허용합니다. |
| `deploy/systemd/starindex.service` | `Wants`(Requires 아님: DB가 RDS일 때도 시작)·`After=postgresql.service valkey.service network-online.target`, `EnvironmentFile=/etc/starindex/app.env`, `ExecStart=/opt/starindex/start.sh`, `Restart=on-failure`, `RestartSec=10`, `StateDirectory`·`LogsDirectory` |
| `deploy/systemd/starindex-pgdump.{service,timer}` | 5.5. 19:40 UTC(04:40 KST), `Persistent=true`, `User=starindex` |
| `deploy/app/{start.sh,app.env.example}` | 5.4, 4.4. 데이터 키가 SSM에 아직 없으면 경고만 하고 키 없이 시작 |
| `deploy/aws/{s3-lifecycle.json,iam-instance-db.json}` | 5.4, 5.5. 인스턴스 역할에는 CodeDeploy용 `deploy/backend/*` 읽기도 포함 |
| `deploy/test/{Dockerfile,al2023-harness.sh}`, `scripts/deploy-check.sh` | AL2023 컨테이너 검증(10장). `systemctl`·`aws`만 대역으로 바꾸고 실제 스크립트를 실행 |

---

## 6. 테스트와 검증

### 6.1 자동 테스트 (`./gradlew test`, Testcontainers `postgres:18`, 로케일 C)

**신규 테스트**

| 테스트 | 합격 기준 |
|---|---|
| 팩 골든 `packJsonIsUnchangedByStorageChanges`(C2, 현재 코드로 기록) | 고정 입력의 팩 JSON(gunzip 뒤) sha256이 기록한 상수와 같습니다. TMP는 `14.0`, WSD는 `1.8`로 정확히 찍힙니다. C3~C5 동안 계속 통과해야 합니다. |
| `ForecastHourStoreTest` | ① 최신 발표가 null이면 이전 값 유지 ② 최신 값이 있으면 덮어씀 ③ 늦게 온 옛 발표는 빈 칸만 채움 ④ `base_at`은 GREATEST ⑤ 같은 발표를 다시 넣어도 결과가 같음. 기존 `aMissingNewestValueFallsBackToTheOlderIssue`를 흡수합니다. |
| `KmaForecastClient.hours` 단위 테스트 | 6개 항목만 남고, 모두 null인 시각은 행을 만들지 않고, 반올림과 스케일 규칙을 지킵니다. |
| `MigrationTest` | ① 슈퍼유저가 아닌 역할(NOSUPERUSER NOCREATEDB)이 소유한 DB에서 V1~최신 적용이 성공합니다. ② 같은 방식으로 `target=4`까지 올리고, 옛 `kma_forecast`에 발표 2개(최신이 -999)를 넣은 뒤 최신까지 올리면 이전 값이 대신 옮겨집니다. |
| `SchemaGuardTest` | 앱 테이블마다 `information_schema.columns`가 2.2의 "남기는 컬럼"과 정확히 같고, 삭제한 테이블 4개는 없습니다. |
| `RetentionServiceTest`(`purge(asOf)`에 고정 시각 사용) | 테이블마다 기준 ±1초 또는 ±1일의 행을 넣어 확인합니다. 월 경계(KST 11/01 00:30 → 밤 날짜 10/31 → 기준 달은 10월, 지난달 1일인 9/1 행은 유지되고 8/31 행은 삭제. 2.2 표 기준이며, 처음 적은 "9월 1일 삭제"는 2.2와 모순이라 고쳤습니다. 테스트는 같은 경우를 03-01 00:30으로 확인합니다)와 밤 날짜 경계(KST 11:59와 12:00)를 포함합니다. |
| 팩 보존 | kind `index` 6개와 `events` 2개, 그중 하나는 pinned, manifest는 두 kind를 모두 가리킵니다. 9일 전 행 가운데 현재·최신 3·pinned는 행과 파일이 남고 나머지는 지워집니다. 고아 파일은 `lastModified` 기준으로 지워지고, 방금 만든 과거 밤 파일은 남습니다. `store.delete`가 예외를 내면 행이 남고, 단계는 `COMPLETED_WITH_WARNINGS`, Job은 COMPLETED이며 이후 단계(kasiRiseSet, crosscheck)도 실행됩니다. |
| Batch 정리 | `healthcheckJob`을 3번 실행하고 그중 2번의 `CREATE_TIME`을 9일 전으로 바꿉니다. 정리 후 그 2번의 실행, 단계, 컨텍스트, 파라미터, 인스턴스가 0이고, 나머지 1번과 실행 중인 `astroDailyJob`은 남습니다. |
| `LocalPackStoreTest` | `../` 경로를 거부하고, 빈 디렉터리를 지우고, `list`가 상대 경로와 수정 시각을 돌려줍니다. |
| 소스 grep(CI 한 줄) | `src/main/java`에 `kma_forecast\b`, `kma_forecast_issue`, `astro_night`, `star_index_hourly`가 0건입니다. |

**기존 테스트 수정**

| 대상 | 수정 |
|---|---|
| `EtlJobsIntegrationTest.clean()`(75~76행) | TRUNCATE 목록을 C3·C4에 맞춥니다. 예: `kma_forecast_hour`, `star_index_nightly`, `data_pack`… |
| `forecastPipelineIngestsScoresAndPublishesIdempotently`(109~112, 139행) | `kma_forecast_hour` = 17 × 60행, 다시 실행해도 같음. `kma_forecast_issue` 단언 대신 `forecastFetch` 단계의 WRITE_COUNT=17, FILTER_COUNT=0. `star_index_nightly` 17행은 유지 |
| `incompleteForecastFailsTheCompletenessGate`(218, 230행) | `COUNT(DISTINCT (nx,ny)) FROM kma_forecast_hour` = 15, WRITE_COUNT=15, FILTER_COUNT=2 |
| `cloudyForecastLowersTheIndex`(193~206행) | 준비 데이터를 `kma_forecast_hour` INSERT로 바꿉니다. `MAX(score)` 단언은 유지 |
| `astroDaily…`(240행) | `astro_night` 단언을 지웁니다. `kasi_riseset`과 `astro_crosscheck` 건수는 유지 |
| `EtlWithoutKeyTest` 31행 | TRUNCATE에서 `astro_night`을 뺍니다. |
| `EtlWithoutKeyTest` 53~61행 `dailyRetentionDropsOldForecastsAndAudit` | `kma_forecast_hour`로 다시 씁니다. 3일 전 fcst는 삭제, 1일 전은 유지 |
| `EtlWithoutKeyTest` 69행 | `astro_night` 단언을 지웁니다. 키가 없을 때 `astroDailyJob`은 COMPLETED이고 단계는 retention 1개 |
| `DataGoKrClientTest` | 4.1의 선택 정리를 하는 경우에만 PCP 단언을 바꿉니다. |

### 6.2 EC2 메모리 모사 (`scripts/ec2sim.sh`, C6)

> ADR-015 이후 모사는 DB를 EC2 밖에 둔다(postgres는 제한 없는 Neon 대역, Valkey만 제한). 합계는 JVM + Valkey + 270이고, 대기 중 연결 0 판정과 t4g.micro 참고 예산이 추가됐다. 최신 결과는 11.7이다. 아래는 ADR-014 당시의 절차다.

로컬 JVM(macOS, 코어 여러 개)은 EC2를 대표하지 못하므로 JVM도 Linux arm64 컨테이너에서 돌립니다.
- postgres와 valkey: `docker-compose.ec2sim.yml` override로 각각 `mem_limit` 320m와 160m를 겁니다. postgres `command`에는 5.2와 같은 `-c` 값을 줍니다.
- JVM: `docker run --platform linux/arm64 --cpus=2 --memory=1g -e MALLOC_ARENA_MAX=2 -e JAVA_OPTS="<4.4와 같음> -XX:NativeMemoryTracking=summary" --network <compose 네트워크> eclipse-temurin:21-jre java -jar …`
- `etl.sh`가 compose를 부를 때 `STARINDEX_EC2SIM=1`이면 override 파일을 함께 넘깁니다.
- 실행할 것
  - 서버 모드로 10분 대기(기준 RSS). **실행 결과에서 바꾼 점:** 운영과 같은 구성(웹 + 스케줄러 켬)으로 띄우고, 시작할 때 `forecastPipelineJob`을 같은 JVM 안에서 1회 실행합니다. 대기 뒤 서버가 살아 있는지 확인합니다.
  - CLI `pipeline` 3회, 이어서 `publish`, `astro`, `events`(한 번에 JVM 하나)
  - `pg_dump` 1회
  - data.go.kr 대신 `scripts/ec2sim_stub.py`가 응답하므로 키가 없어도 됩니다. DB는 같은 서버의 `starindex_ec2sim`을 쓰고 끝나면 지웁니다.

**합격 기준**
- 세 컨테이너 모두 `OOMKilled=false`
- 최대치(`docker stats`): postgres ≤250MiB, valkey ≤150MiB, JVM 컨테이너 ≤900MiB
- `jcmd VM.native_memory summary`의 Metaspace committed를 기록합니다.
- starindex 연결 ≤6
- 합계 + OS·에이전트 270 ≤ 1,600MiB
- 측정값이 비면(컨테이너가 일찍 죽는 등) 실패로 봅니다. 연결 수 기준도 결과에 반영합니다.

**실측 (2026-10-01, `scripts/ec2sim.sh 600`, PASS)**

| 항목 | 값 | 기준 |
|---|---|---|
| postgres 최대 | 54MiB | ≤250 |
| valkey 최대 | 13MiB | ≤150 |
| 서버 JVM 최대(웹 + 스케줄러 + 같은 JVM 안 파이프라인) | 310MiB | ≤900 |
| CLI JVM 최대(pipeline ×3, publish, astro, events) | 274MiB | ≤900 |
| 합계 + OS·에이전트 270 | 647MiB | ≤1,600 |
| starindex 연결 최대 | 4 | ≤6 |
| Metaspace committed(NMT) | 서버 107MiB, CLI 89~98MiB | 상한 192m, 조정 기준 160 |
| OOMKilled, 종료 코드 | 없음, 모두 0 | |

- 힙 512m 가운데 실제 사용은 작아서 RSS가 예산(820~900MiB)보다 훨씬 낮습니다. EC2 첫 주(6.3)에 GC 로그로 Full GC 뒤 힙을 다시 봅니다.

### 6.3 운영 측정 (EC2 첫 주)

```sql
SELECT relname, n_live_tup, pg_size_pretty(pg_total_relation_size(relid))
FROM pg_stat_user_tables ORDER BY pg_total_relation_size(relid) DESC;
SELECT pg_size_pretty(pg_database_size('starindex'));
```

| 지표 | 합격 기준 |
|---|---|
| `kma_forecast_hour` | ≤3,500행, ≤1MB |
| `etl_api_call` | ≤2,500행 |
| `astro_crosscheck` | ≤700행 |
| `data_pack` | ≤80행 |
| 팩 파일 | ≤80개 |
| `BATCH_JOB_EXECUTION` | ≤100건 |
| DB 전체 | ≤15MB |
| 7일 관찰 | `MemAvailable` ≥300MiB, `vmstat` si/so 거의 0, pg_dump 7회 성공, 복구 리허설 1회 성공 |

실측값은 날짜와 함께 이 절에 기록합니다. 비교 기준은 변경 전 205k행, 31MB, 39MB입니다.

---

## 7. 문서 갱신 (C1, C8)

| 파일 | 변경 |
|---|---|
| `docs/DB-PLAN.md` | 이 문서(C1) |
| `docs/adr/ADR-014-self-hosted-postgresql-retention.md` (C1) | 결정 ①, 보관 2일과 예외 4가지, 넓은 예보 테이블, RDS 호환 조건(DB_URL만 교체, 소유자 역할 GRANT, sslmode), S3 raw·collect-only 폐기, t4g.micro 경로 폐지, M0는 RDS·이후는 EC2 |
| `docs/adr/ADR-013-postgresql.md` | "결과"에 ADR-014 한 줄 |
| `docs/ETL.md` | §3 `astroDailyJob` 행. §5 테이블 표를 2.2 기준으로 다시 씀. 새 §7 "보존 정책"(요약 + DB-PLAN 링크). 완결성 = WRITE/(WRITE+FILTER). §2 `publish`에 "이틀보다 이전 밤은 불가"와 `pin` |
| `docs/PLAN.md` | §3.4: 테이블 목록에 "(ADR-013/014, 실제 스키마는 DB-PLAN)", `index_backtest` 삭제, S3 `raw/` 삭제·`backup/db/`(7일) 추가, IAM 반영(5.4) |
| `docs/PLAN.md` | §3.4 관리자: `backtest` = binary-clear-v2 혼동행렬(`forecast_verification`), 롤백은 최신 3·pinned만 |
| `docs/PLAN.md` | §3.5: CI "Testcontainers PostgreSQL 18" |
| `docs/PLAN.md` | §3.6: RDS 행 = "M0 시연까지, 이후 EC2 PG18", 원칙 2, 비용 표(R1~R2도 EC2 24/7, 2027~ small 약 $21), t4g.micro 조건 폐지 |
| `docs/PLAN.md` | 170·556·618행: collect-only와 raw 대신 `forecast_verification` |
| `docs/SERVICE-PLAN.md` | §7.3 R1 "raw collect-only 1.0"을 "C9 관측소 스냅숏 1.0(기한 11/28)"으로 |
| `docs/SERVICE-PLAN.md` | §8.1 "raw는 S3" 삭제 |
| `docs/SERVICE-PLAN.md` | §8.2 `forecast_verification` 정의를 3.3으로, `verify_station` 추가 |
| `docs/SERVICE-PLAN.md` | §8.6 "RDS MySQL 8.4"를 "PostgreSQL 18(M0 RDS, 이후 EC2)"로 |
| `docs/SERVICE-PLAN.md` | §8.7 collect-only 행 삭제, 비용 주석 |
| `docs/SERVICE-PLAN.md` | §11.1 "정리·회고" 행 비고에 "DB-PLAN C2~C8" |
| `README.md` 9행, `docs/cost-log.md` 11행, `backend/docker-compose.yml`·`IntegrationTestBase` 주석 | "RDS MySQL 8.4"와 "planned RDS"를 "PostgreSQL 18(EC2 직접 설치, M0는 RDS, ADR-014)"로 |

---

## 8. 작업 순서, 커밋, 일정

M0 동결 전 평일 여유는 약 2일입니다(SERVICE-PLAN 7.1). 그래서 **M0 전에는 문서만** 추가하고, 코드 변경은 시연(10/20) 다음 날부터 "정리·회고"(10/20~10/23, 계획 밖 버퍼 4일)와 주말(10/24~25)에 합니다. R0(AR 스파이크 5/5)는 건드리지 않습니다.

매 커밋마다 `./gradlew test`가 통과해야 하고, 메시지는 기존 한국어 형식을 따릅니다.

| # | 기간 | 커밋 | 내용 | 인일 [추정] |
|---|---|---|---|---|
| C1 | 9/30 | `docs: DB-PLAN + ADR-014 (EC2 PG18 직접 설치, 2일 보관)` | 7장의 신규 문서 2개 | 0.25 |
| — | M0 기간 | (코드 변경 없음) | 데모 v1 팩을 만들면 버전을 기록해 둡니다. 삭제 코드가 아직 없으므로 파일은 안전합니다. | 0 |
| C2 | 10/21 | `test: 팩 JSON 골든과 예보 대체 조회 특성 테스트` | **현재 코드 그대로** 골든 상수를 기록 | 0.5 |
| C3 | 10/21~22 | `DB: V5 kma_forecast_hour — 6개 항목, 격자·시각당 1행` | V5, 4.1, 4.2 예보 부분, `ForecastHourStoreTest`, `MigrationTest`, 기존 테스트 수정. C2 골든 통과 | 1.0 |
| C4 | 10/22 | `DB: V6 읽지 않는 테이블·컬럼 삭제` | V6, 4.2 나머지, `SchemaGuardTest` | 0.75 |
| C5 | 10/23 | `ETL: 보존 정리 — asOf 기준, 팩·pin, Batch API` | 4.3 전체, `RetentionServiceTest`, `LocalPackStoreTest`. **배포 전에 데모 팩을 pin** | 1.25 |
| C6 | 10/23 | `설정: Hikari 5/최소 1, JVM 옵션, EC2 메모리 모사` | 4.4, `ec2sim.sh`. 6.2 결과를 DB-PLAN에 기록. **여기까지 RDS 위에서 배포하고 확인**(실제 RDS에서 호환성 검증) | 0.5 |
| C7 | 10/24~25 | `운영: deploy/ — PG18 설치·튜닝·pg_hba·백업·복구·systemd` | 5.8 전체(`bash -n`, shellcheck). EC2에 설치 → 5.7로 RDS에서 EC2로 전환 → 백업·복구 리허설 → RDS 최종 스냅샷과 삭제 | 1.25 |
| C8 | 10/25 | `docs: ETL·PLAN·SERVICE-PLAN·README 갱신` | 7장의 나머지 | 0.5 |
| C9 | R1 첫 주(11/2~6), 기한 11/28 | `ETL: 관측소 10곳 17·23시 스냅숏(forecast_verification)` | V7, 4.5, 테스트. SERVICE-PLAN R1의 "raw collect-only 1.0"을 대체하므로 추가 공수는 0 | 1.0 |

- 10/20 이후 합계는 5.75인일이고, 가용일은 평일 4일 + 주말 2일입니다.
- 일정이 밀리면 C7·C8은 R1 첫 주로 넘깁니다. 그 사이 RDS 비용이 하루 약 $0.7 더 나오는 것 말고는 영향이 없습니다 [추정].

**EC2 적용 순서(C7)**
1. `install.sh`
2. SSM 파라미터
3. 스케줄 정지 → 5.7 전환
4. 앱 시작(Flyway 검증)
5. 백업 타이머
6. 첫 백업 확인
7. 복구 리허설
8. 7일 관찰(6.3)

---

## 9. 리스크와 미확인 사항

**사실 [확실]**
- 런타임에 DB에서 읽는 것은 region, 예보 6개 항목, 최신 발표 시각, KASI 저녁 4개 시각, Batch 메타데이터뿐입니다. 계획된 R3 공개 페이지와 관리자 화면은 추가로 `star_index_nightly`, `data_pack`, `etl_api_call`, `astro_crosscheck`, `forecast_verification`을 읽습니다(EtlRepository, IndexService, PackPublisher, SERVICE-PLAN:768·773, PLAN:185·233).
- 지금의 `purge`는 kma_forecast, kma_forecast_issue, etl_api_call, star_index_hourly만 정리합니다(EtlRepository:86-93).
- PostgreSQL 18은 AL2023 core 저장소에 있습니다(18.3).
- RDS는 정지해도 7일 뒤 다시 시작하고, 정지 중에도 스토리지 요금이 나옵니다.
- 다른 역할이 소유하는 DB를 만들려면 그 역할로 SET ROLE을 할 수 있어야 합니다.

**해석**
- 발표가 거꾸로 두 번 이상 백필되면 항목별 대체 값이 지금 방식과 다를 수 있습니다. 정상 운영에서는 결과가 같습니다.
- 2일 보관 때문에 이틀보다 이전 밤은 다시 발행할 수 없습니다. ETL이 2일 넘게 실패하면 현재 팩이 그대로 유지되고, 신선도 알람(PLAN 3.5 ②)이 이를 잡습니다.
- (ADR-015로 대체: DB는 Neon. EC2 장애에도 DB는 남고, Neon 정지·한도 초과의 위험은 11.8) 앱, DB, Valkey가 EC2 한 대와 EBS 하나에 모두 있어 단일 장애점입니다. 마지막 덤프 이후 최대 24시간의 이력을 잃을 수 있습니다. 팩은 S3에 있습니다(W3 이후).
- S3 원문을 폐기했으므로 21~00시 SKY/PTY 밖의 새 적중률 정의(예: 다른 시각대, TMP 기반)는 소급 계산할 수 없습니다. 지금 공개 지표와 T13은 스냅숏으로 충분합니다.
- 평가자가 "RDS가 상시 떠 있어야 한다"고 보면 월 약 $21이 더 듭니다 [불확실].

**확인됨으로 옮긴 것**
- `StepContribution.incrementWriteCount(long)`, `incrementFilterCount(long)`, `JobRepository.deleteJobInstance`/`deleteJobExecution`이 Spring Batch 6.0.5에 있다는 것. 검토 단계에서 javap로 확인했고 [가능성 높음], C3·C5 컴파일로 최종 확인합니다.

**미확인 [불확실]: 실행 전에 확인할 것**
- AL2023 서브패키지 이름(`postgresql18-server`), systemd 단위 이름, 데이터 디렉터리, initdb 방법
- `PG_OOM_ADJUST_*` 동작
- RDS PG18의 `rds.force_ssl` 기본값, 그리고 **서울 리전에서 db.t4g.micro로 PG18을 만들 수 있는지**
- RDS에서 `LOCALE 'C'`로 `CREATE DATABASE`가 되는지(RDS를 만들 때 확인)
- `deleteJobInstance`가 실행 기록까지 함께 지우는지(테스트로 확인)
- 기상청 getVilageFcst가 지난 발표를 며칠까지 돌려주는지(ETL.md §6). 장애가 약 1일을 넘으면 그 사이 발표가 영구히 빠질 수 있습니다.
- SSM `aws/ssm` 키에 `kms:Decrypt` IAM 권한이 필요한지
- 서울 리전의 gp3, 스냅샷, RDS 단가(제3자 자료)

**추정:** 2장의 행 수와 용량, 5.3 메모리 예산, 덤프 크기, DB 전체 10~15MB, 인일. 6.2와 6.3의 실측값으로 바꿉니다.

---

## 10. 실행 결과와 계획 대비 변경 (2026-10-01)

> ADR-014(EC2 직접 설치) 구현 기록이다. 같은 날 DB 위치는 ADR-015(Neon)로 바뀌었고, 그 구현과 검증은 11장에 있다. 아래의 `install.sh`, 로컬 복구, `tune.sql`, 서버 메모리 수치는 ADR-014 기준이다.

### 10.1 커밋

| # | 커밋 | 내용 |
|---|---|---|
| C1·C2 | b731684 | DB-PLAN, ADR-014, 팩 골든 테스트 |
| C3 | 6f28f2b | V5 `kma_forecast_hour` |
| C4 | 1263924 | V6 읽지 않는 테이블·컬럼 삭제 |
| C5 | f1f5ee0 | 보존 정리(`RetentionService`), pin |
| C6 | 0d99429 | Hikari, JVM 옵션, EC2 메모리 모사 |
| C7 | db5aeb4 | `deploy/` |
| C8 | (이 커밋) | 문서, CI, 적대적 리뷰 반영 |
| C9 | 미착수 | R1 첫 주, 기한 11/28 |

### 10.2 검증 결과

| 검증 | 결과 |
|---|---|
| `./gradlew test` | 57/57 통과. 팩 골든 해시(`e039f859…`)는 C3~C8 동안 바뀌지 않음 |
| `scripts/deploy-check.sh` (amazonlinux:2023 2023.12.20260918, postgresql18-server 18.6, Corretto 21.0.12, Valkey 9.0.6) | 47/47 통과. 설치 2회(두 번째는 0700 홈의 체크아웃에서), Flyway V1~V6을 슈퍼유저가 아닌 소유자로 적용, SCRAM 저장·argv 비노출, 백업 → 복원 리허설 → 같은 밤 재발행 시 같은 팩 버전, 운영 DB 복원 시 앱 정지·재시작, 잘못된 아카이브 거부, 복원 중 실패 시 이전 DB 복귀, RDS형 비슈퍼유저 마스터에서 `create-db.sql`과 전환 복원 |
| `scripts/ec2sim.sh 600` | PASS(10-01, 대기 600초). 최대: postgres 54MiB, valkey 13MiB, 서버 JVM(웹 + 스케줄러 + 파이프라인) 310MiB, CLI JVM 274MiB, 합계(+OS·에이전트 270) 647/1,600MiB. 연결 최대 4. Metaspace committed 87~107MiB(상한 192m). OOMKilled 없음, 작업 7개 모두 성공. postgres 값이 작은 것은 DB가 수십 KB라 `shared_buffers`를 거의 쓰지 않았기 때문이며, 실제 값은 6.3에서 다시 잽니다. |
| shellcheck(`--severity=warning`) | 경고 0 |
| 적대적 리뷰(5관점 × 반박 검증) | 16건 보고, 반박 2건, 나머지 14건 모두 반영(10.3) |

### 10.3 계획과 달라진 점

| 위치 | 계획 | 실제 | 이유 |
|---|---|---|---|
| 4.3(b) 팩 삭제 | 파일 삭제 → 행 삭제 | 한 트랜잭션 안에서 `SELECT … FOR UPDATE`로 pinned 재확인 → 행 삭제 → 파일 삭제. 파일 삭제가 실패하면 행이 되살아남 | 삭제 도중 pin이 들어오는 경쟁을 막음 |
| 4.3(c) 고아 파일 | `packs/` 전체 목록 | `packs/{index,events,spots}/`만 목록. 행이나 manifest가 가리키는 **버전 디렉터리** 전체를 보호. 목록 중 사라진 파일은 건너뜀 | manifest 임시 파일과 발행 중 파일 때문에 정리 전체가 실패하던 문제(리뷰 RET-1) |
| 4.3 manifest | — | manifest를 읽지 못하면 팩 삭제를 건너뛰고 경고 | 현재 팩을 모르면 무엇도 안전하지 않음 |
| 4.4 Hikari | `idle-timeout: 10m` | `600000` | Boot 4는 이 속성에 기간 표기를 받지 않아 시작이 실패(모사에서 발견) |
| 4.4 테스트 디렉터리 | — | 테스트 팩 디렉터리를 `build/test-packs`로 분리 | 보존 정리가 개발자의 `build/packs`를 지울 수 있었음 |
| 5.2 OOM | drop-in -900 | 두지 않음 | AL2023 단위 파일이 이미 -1000 |
| 5.2 create-db | `GRANT starindex TO CURRENT_USER` | `pg_has_role(…,'SET')` 검사 + `WITH SET TRUE` | PG16+ 생성자에게 SET 권한이 없음(RDS형 마스터에서 재현) |
| 5.1 설치 | — | initdb 전에 `daemon-reload` | `postgresql-setup`이 NeedDaemonReload를 검사 |
| 5.5 수명주기 | `s3-lifecycle-backup.json` | `s3-lifecycle.json`(backup/db 7일 + deploy/backend 90일) | 버킷 수명주기 설정은 통째로 교체됨 |
| 5.4 IAM | DB 관련 권한만 | `deploy/backend/*` 읽기 포함 | 이 파일이 인스턴스 역할 전체로 쓰이면 CodeDeploy가 리비전을 못 받음(리뷰 IAM-1) |
| 5.6 복구 | 중지 → dropdb → 생성 → 복원 | 아카이브 검증 → 중지 → 기존 DB를 `<db>_prev`로 이름 변경 → 생성 → 복원 → 확인. 실패하면 되돌리고 앱 재시작. 대상은 운영 DB와 `starindex_restoretest`만 | 잘못된 파일 하나로 운영 DB가 비고 앱이 멈춘 채 남던 문제(리뷰) |
| 5.8 유닛 | `Requires=postgresql.service` | `Wants` | DB가 RDS일 때 로컬 서버가 없어도 앱이 떠야 함 |
| 6.2 모사 | 서버 대기 + CLI | 서버는 운영 구성(웹 + 스케줄러 + 같은 JVM 안 파이프라인 1회)으로. 측정 누락·서버 조기 종료·연결 수도 실패로 판정 | 리뷰 SIM-1~3. 이를 위해 웹 서버로 띄운 잡 실행은 종료하지 않도록 `StarIndexApplication`을 바꿈(CLI는 그대로 종료 코드 반환) |
| 6.1 월 경계 | "9월 1일 삭제" | 9/1 유지, 8/31 삭제 | 2.2 표(밤 날짜가 속한 달의 지난달 1일부터)와 모순이던 문장 |

### 10.4 남은 것

- C9(관측소 스냅숏): R1 첫 주, 기한 11/28.
- 실제 EC2 설치와 RDS → EC2 전환(W3 이후, 8장 "EC2 적용 순서"), 6.3 운영 측정.
- Valkey: EC2(AL2023)는 9.0.6, 로컬·CI는 8입니다. 프로토콜은 호환되지만 CI 이미지를 9로 맞출지는 정하지 않았습니다.
- 개발 PC: Desktop 폴더 동기화가 `build/` 안에 `이름 2.class` 사본을 만들어 Gradle 테스트가 "wrong name"으로 실패한 적이 있습니다(사본을 지우면 해결). 저장소를 동기화 밖으로 옮기거나 `build`를 동기화에서 빼는 것을 권합니다.

---

## 11. Neon Free 운영 (ADR-015, 2026-10-01)

### 11.1 구성

| 항목 | 값 |
|---|---|
| 서비스 | Neon Free 프로젝트 1개, PostgreSQL 18, AWS ap-southeast-1(싱가포르). 서울·도쿄 리전은 없다 [확실] |
| 컴퓨트 | 자동 확장 상한 **0.25 CU 고정**(콘솔 → Compute). 2 CU까지 오르면 CU-시간을 8배 쓴다 |
| 연결 | 직접 엔드포인트(호스트에 `-pooler` 없음). Flyway, `pg_dump`, `pg_restore`는 직접 연결이 필요하다 [확실] |
| `DB_URL` | `jdbc:postgresql://<ep-…>.ap-southeast-1.aws.neon.tech/starindex?sslmode=require&channelBinding=require` |
| 역할 | 앱은 SQL로 만든 `starindex`(슈퍼유저 아님, CREATEDB 없음). 관리 작업만 `neondb_owner`(Neon 기본 관리 계정, CREATEDB·CREATEROLE) |
| 비밀 | `/starindex/db/password`(SSM SecureString). `neondb_owner` 비밀번호는 EC2에 두지 않고, 관리 작업 때 입력한다 |
| 쓸 수 없는 것 | `ALTER SYSTEM`(인스턴스 설정), 슈퍼유저, 테이블스페이스 [확실]. 기본값에서 `max_connections` 112(0.25 CU), `idle_in_transaction_session_timeout` 5분 |

### 11.2 Neon이 쉬도록 하는 설정 (CU-시간 예산)

- Neon은 실행 중인 쿼리가 5분 동안 없으면 정지한다. 열려 있기만 한 연결은 막지 않지만, 새 연결과 쿼리는 타이머를 다시 시작한다 [확실].
- HikariCP 7.0.2는 유휴 연결에 기본 2분마다 핑을 보낸다(6.2.1부터) [확실, HikariCP 소스]. 이전 설정(최소 1개 유지)이면 24시간 깨어 있어 월 약 180 CU-시간이 되고, 100 한도를 넘겨 약 16일째 정지한다 [추정].
- 그래서 다음처럼 둔다(`application.yml`, `DataSourcePoolTest`).
  - `minimum-idle: 0`
  - `idle-timeout: 60000`
  - `keepalive-time: 0`
  - `maximum-pool-size: 5`
  - `connection-timeout: 30000`
- 실측: 서버를 띄우고 마지막 쿼리 뒤 100초가 지나면 DB 연결이 0이다(`scripts/deploy-check.sh`). 10분 모사에서도 대기 중 연결이 0으로 내려간다(11.7).
- DB를 주기적으로 건드리는 것은 금지한다.
  - `/actuator/health`(db 지표가 연결을 연다)를 폴링하지 않는다.
  - 공개 `/api/health`(W3)는 DB를 읽지 않게 만든다.
  - 관리 화면 자동 새로고침도 DB를 읽지 않는 주기로 둔다.
  - 시작 실패 재시작 루프도 같은 효과다. `starindex.service`는 120초 간격, 시간당 5회까지만 재시작하고, 그 뒤에는 실패 상태로 멈춘다(고친 뒤 `systemctl reset-failed starindex && systemctl start starindex`). 신선도 알람(PackAgeMinutes)이 멈춘 것을 잡는다.
- 예상 사용량 [추정]
  - 하루 약 10번 깨어난다: 예보 8번, 00:30 astroDaily, 01:10 astroEvents. 백업은 05:20 KST로 옮겨 05:15 실행의 깨어 있는 시간에 붙였다.
  - 한 번에 실행 약 3분 + 풀 정리 약 1.5분 + 정지 대기 5분 ≈ 10분이다.
  - 하루 약 100분, 월 약 50시간이고, 0.25 CU면 **월 약 12 CU-시간**이다.
  - 첫 주에는 Neon 콘솔 Usage를 매일 확인하고, 실측을 11.7에 적는다.
- 그 밖의 한도 [추정]
  - 저장: 0.5GB 대비 수 MB
  - 전송: 5GB/월 대비 일일 덤프 수 MB × 30

### 11.3 설치 순서 (W3, 사용자 조치 포함)

1. Neon 콘솔에서 프로젝트를 만든다. 이름 `starindex`, Postgres 18, AWS Asia Pacific (Singapore). 그다음 Compute 자동 확장 상한을 0.25 CU로 둔다.
2. 연결 정보에서 **직접(pooled 끔) 호스트**를 복사한다. `neondb_owner` 비밀번호는 보관만 하고 EC2에는 저장하지 않는다.
3. SSM에 `/starindex/db/password`(`openssl rand -base64 32`, SecureString)를 만든다. Neon은 SQL로 정하는 비밀번호에 60비트 이상의 엔트로피를 요구한다 [확실]. 이 값은 그보다 훨씬 강하다.
4. EC2에서 `/etc/starindex/app.env`를 `deploy/app/app.env.example`로 만든다. `DB_URL`(11.1)과 `S3_BUCKET`을 채운다.
5. `sudo deploy/ec2/install.sh`: PostgreSQL 18 클라이언트, Valkey(로컬, 128MB, 저장 없음), 앱 사용자, 운영 스크립트·유닛, 백업 타이머, 스왑
6. `sudo /opt/starindex/postgres/bootstrap-db.sh`: `neondb_owner` 비밀번호를 묻는다.
   - `create-db.sql`로 `starindex` 역할과 DB를 만든다.
   - SSM 비밀번호를 stdin으로 설정한다.
   - 앱 역할로 TLS 접속을 확인한다.
7. `sudo systemctl enable --now starindex`: Flyway가 V1~V6을 적용한다.
8. 첫날 백업(`starindex-pgdump.timer`)과 복원 리허설(11.5)을 한 번씩 확인한다.

### 11.4 백업

- `backup.sh`는 그대로다. `DB_URL`에서 호스트, DB, `sslmode`, `channelBinding`을 읽어 `pg_dump -Fc --no-tablespaces`로 S3 `backup/db/`에 올린다(7일).
- 시각은 05:20 KST(20:20 UTC)다.
- 클라이언트는 AL2023 `postgresql18`(서버와 같은 메이저)다. `pg_dump`는 자기보다 새 메이저의 서버를 덤프하지 못한다 [확실].

### 11.5 복구

| 상황 | 방법 |
|---|---|
| 6시간 안에 알아챈 실수 | Neon 콘솔 → Backup & Restore → 즉시 복원(루트 브랜치 전체, 이전 상태는 `_old` 브랜치로 남음, 연결 문자열 그대로) [확실]. 확인 뒤 `_old` 브랜치를 지운다(브랜치 10개 한도) |
| 그보다 오래된 백업 | `restore.sh <날짜|latest> <새 DB 이름> [--switch]`. 운영 DB 옆에 새 DB를 만들어(관리 계정) 앱 역할로 복원하고, 확인한 뒤 `--switch`로 `app.env`의 `DB_URL`만 바꿔 앱을 다시 켠다. 이전 DB와 `app.env.bak-*`는 남는다 |
| 복원 리허설 | `restore.sh latest starindex_restoretest`(앱 정지 없음). 같은 밤을 재발행해 같은 팩 버전이 나오는지 본다 |

- `restore.sh`는 운영 DB를 대상으로 받지 않는다. 잘못된 아카이브는 아무것도 만들기 전에 거부한다. 복원이 중간에 실패하면 만들던 DB를 지운다.

### 11.6 EC2 크기

- DB가 EC2 밖으로 나가 EC2에는 JVM과 Valkey만 남는다. 11.7 실측으로 t4g.small(2GB)은 여유가 크다.
- t4g.micro(1GB)는 다시 후보다. 전환 조건(PLAN rev4의 조건을 되살림)은 다음과 같다.
  - `-Xmx384m`
  - Valkey `maxmemory 64mb`
  - 실제 EC2에서 7일 동안 MemAvailable ≥250MiB이고 스왑이 거의 0
- 무료 체험(t4g.small, 2026-12-31까지) 동안 측정하고 12월에 정한다. 2027년 월 비용은 약 $21(small) 또는 $13(micro)이다 [추정].

### 11.7 검증 결과 (2026-10-01)

| 검증 | 결과 |
|---|---|
| `./gradlew test` | 58/58 통과(`DataSourcePoolTest` 포함), 팩 골든 해시 불변 |
| `scripts/deploy-check.sh` (amazonlinux:2023, Neon 대역: TLS만 받는 PostgreSQL 18, 슈퍼유저 아닌 CREATEDB·CREATEROLE 관리 계정) | 72/72 통과. 설치 2회(두 번째는 0700 홈), Valkey 설정은 바뀔 때만 재시작, 재시작 횟수 제한, `bootstrap-db.sh` 2회(TLS true, superuser false, CREATEDB 없음, locale C), 비밀번호가 argv·로그에 없음, `start.sh`로 Flyway V1~V6(TLS + channel binding), **서버 유휴 100초 뒤 DB 연결 0**, 파이프라인, 백업, pin, 운영 DB 옆 복원 리허설 → 같은 팩 버전, 기존 DB(되돌리기용 사본) 덮어쓰기 거부, 잘못된 아카이브·복원 실패 처리, `--switch`(app.env 갱신·백업·권한·앱 재시작), 비밀번호 교체 뒤 앱 재시작, 빈 운영 DB 첫 채우기(11.9)와 두 번째 거부 |
| `scripts/ec2sim.sh 600` (DB는 EC2 밖, 로컬 postgres가 Neon 역할) | PASS. 최대: 서버 JVM(웹 + 스케줄러 + 파이프라인) 306MiB, CLI JVM 267MiB, Valkey 19MiB. EC2 합계(+OS·에이전트 270) **595/1,600MiB**. t4g.micro 참고 예산(약 900MiB, 가정)에도 들어간다. 연결 최대 2. **대기 중 122개 표본 모두 연결 0**. 작업 7개 성공, OOM 없음 |

### 11.8 위험

- Neon은 중단 없는 가용성이 필요한 운영에는 Free를 권하지 않는다 [확실].
  - DB가 멈춰도 앱은 S3·CloudFront의 마지막 팩으로 동작한다.
  - 그 사이의 새 발표는 수집되지 않는다. 신선도 알람(PackAgeMinutes)이 이를 잡는다.
- Free에서 상업적 이용이 허용되는지는 확인하지 못했다 [불확실]. 출시 전에 Master Cloud Services Agreement와 AUP를 확인한다.
- 미확인 사항 [불확실]
  - HikariCP의 `isValid()` 핑이 Neon 타이머를 다시 시작하는지는 문서에 없다. keepalive를 껐으므로 상관없다.
  - 기본 브랜치가 자동 보관(archive)에서 빠지는지는 확인하지 못했다. 매일 접속하므로 보관 조건(24시간 미접속)에 걸리지 않는다.
  - 0.5GB에 6시간 이력이 포함되는지도 확인하지 못했다. 우리 DB는 수 MB라 여유가 크다.
  - 싱가포르 지연은 측정하지 않았다. 첫 주 배치 실행 시간을 기록한다.
- 되돌리기: EC2 직접 설치(ADR-014) 또는 RDS. 둘 다 `DB_URL`만 바꾼다.

### 11.9 RDS → Neon 전환 (시연에 RDS를 쓴 경우)

1. 시연이 끝나면 스케줄 실행이 없는 시간에 `sudo systemctl stop starindex`
2. RDS에서 마지막 덤프: `sudo -u starindex /opt/starindex/postgres/backup.sh`(이때 `DB_URL`은 아직 RDS)
3. `/etc/starindex/app.env`의 `DB_URL`을 Neon 직접 엔드포인트로 바꾼다(DB 이름 `starindex`).
4. `sudo /opt/starindex/postgres/bootstrap-db.sh`: Neon에 역할과 **빈** DB를 만든다.
5. `/opt/starindex/postgres/restore.sh latest starindex`: 운영 DB가 **비어 있을 때만** 바로 채운다(`--single-transaction`이라 실패하면 다시 빈 상태). 표가 하나라도 있으면 거부한다.
6. `sudo systemctl start starindex` → 파이프라인 1회 확인
7. RDS 최종 스냅샷 → RDS 삭제(정지만 하면 7일 뒤 자동 시작) [확실]

---

## 부록 A. 검토 의견 처리

| # | 의견 | 처리 | 반영 위치 |
|---|---|---|---|
| 1 | `star_index_nightly` 유지 필요 | **수용.** 5개 컬럼만 남기고 2일 보관. 백테스트는 binary-clear-v2로 정의하고 `index_backtest`는 삭제 | 2.2, 3.2, 4.2, 7 |
| 2 | ExecutionContext는 집계할 수 없음 | **수용.** WRITE/FILTER_COUNT를 쓰고 `kma_forecast_issue`는 삭제 | 2.2, 4.1, 6.1 |
| 3 | RDS에서 역할 생성과 복원 실패 가능성 | **수용.** `GRANT starindex TO CURRENT_USER`, 복원은 `-U starindex`로 통일, 슈퍼유저가 아닌 소유자로 마이그레이션 테스트 | 5.2, 5.6, 6.1 |
| 4 | 팩 보존이 index만 고려 | **수용.** manifest의 모든 kind, `pinned` 컬럼, `pin` 명령, C5 배포 전 데모 팩 pin | 3.2, 4.3, 6.1 |
| 5 | S3 raw와 스냅숏 중 택일 | **(b)를 선택.** raw와 collect-only는 폐기하고 수집 시점 스냅숏만 둡니다. DB가 EC2에 항상 떠 있어 raw의 존재 이유가 사라졌습니다. C9는 R1 첫 주, 기한 11/28 | 1, 2.2, 3.3, 4.5, 8 |
| 6 | 발행 이력 2일로는 G6 신선도 판정 부족 | **수용(변형).** 행과 파일을 모두 8일로 둡니다. 파일만 따로 지우면 행이 없는 파일을 가리키게 되고, 8일분 파일은 약 2MB라서 같은 규칙으로 묶는 편이 단순합니다. 사용자의 "2일" 원칙에 대한 예외로 명시했습니다. | 1, 2.2 |
| 7 | 백업에서 예보를 빼는 이득이 없음 | **수용.** 전체 덤프, 복원 후 같은 version이 나오는지 합격 기준에 추가 | 5.5, 5.6 |
| 8 | IAM 권한 부족 | **수용.** ListBucket 조건(`backup/db/`, `packs/`), `packs/{index,events,spots}/*`에만 DeleteObject, raw 권한 삭제 | 5.4 |
| 9 | 보존 정리 실패가 G6를 깸 | **수용.** 항목별 try/catch와 `COMPLETED_WITH_WARNINGS`, 락 밖에서 I/O, 롤백 대상 제한으로 경쟁 상태 제거. 별도 Job 분리는 스케줄 항목만 늘어 채택하지 않음 | 4.3 |
| 10 | 달력 월말 문제 | **수용.** 기준을 "밤 날짜가 속한 달의 지난달 1일부터"로 | 2.2 |
| 11 | 기준 시각이 섞여 있음 | **수용.** `purge(Instant asOf)`, Java에서 바인딩, 경계 테스트 | 2.1, 4.3, 6.1 |
| 12 | 메모리 모사가 EC2를 대표하지 못함 | **수용.** arm64 temurin 컨테이너에 `--cpus=2`, MaxDirectMemorySize, MALLOC_ARENA_MAX, SerialGC, NMT. 예산을 다시 계산해 `-Xmx512m`으로 시작 | 4.4, 5.3, 6.2 |
| 13 | RDS에서 돌아올 때 이력이 갈라짐 | **수용.** 5.7 전환 절차를 필수로, manifest 현재 버전이 `data_pack`에 있는지 확인 | 5.7 |
| 14 | 테스트 누락 | **수용.** 수정 대상 행 번호와 함께 모두 목록에 넣음 | 6.1 |
| 15 | Batch 정리는 표준 API로 | **수용.** `JobRepository.deleteJobInstance`. 시각 근거 문구도 고침 | 2.1, 4.3 |
| 16 | `result_msg`, `kst` 재검토 | **`result_msg`는 수용**(80자, 비정상 호출만). **`kst`는 기각**: KASI에서 언제든 다시 받을 수 있고, events v1 스키마에 절기 시각 필드가 없습니다. 필요해지면 그때 컬럼을 추가하고 다시 받습니다. | 3.2 |
| 17 | 로케일 차이 | **수용.** `POSTGRES_INITDB_ARGS=--locale=C`, 순위 쿼리 동점 처리 | 4.4 |
| 18 | 고아 파일을 버전 날짜로 판정 | **수용.** `lastModified` 기준 | 4.3 |
| 19 | 근거 표기 | **수용.** 릴리스 노트는 직접 열어 `postgresql18-18.3` 확인. 서브패키지 이름과 서울 RDS PG18 가능 여부는 미확인 목록으로 | 5.1, 9 |
| 20 | 작업량과 M0 일정 | **수용(변형).** 검토 의견은 C1~C5를 M0 첫 주에 넣자고 했지만, M0 여유가 약 2일뿐이라 **M0 전에는 문서만** 하고 C2~C8은 10/20~10/25에 합니다. M0 시연은 기존 계획대로 RDS를 쓰고, C6까지 실제 RDS에서 검증한 뒤 EC2로 전환합니다. | 8 |

---

### Critical Files for Implementation
- /Users/ryujemu/Desktop/Knowledge Graph/5주차/personal_project/backend/src/main/java/dev/starindex/etl/EtlRepository.java
- /Users/ryujemu/Desktop/Knowledge Graph/5주차/personal_project/backend/src/main/java/dev/starindex/etl/EtlJobsConfig.java (+ 신규 etl/RetentionService.java, etl/EtlProperties.java)
- /Users/ryujemu/Desktop/Knowledge Graph/5주차/personal_project/backend/src/main/java/dev/starindex/etl/kma/KmaForecastClient.java
- /Users/ryujemu/Desktop/Knowledge Graph/5주차/personal_project/backend/src/main/java/dev/starindex/pack/PackPublisher.java (+ PackStore.java, LocalPackStore.java)
- /Users/ryujemu/Desktop/Knowledge Graph/5주차/personal_project/backend/src/test/java/dev/starindex/etl/EtlJobsIntegrationTest.java (+ EtlWithoutKeyTest.java, IntegrationTestBase.java, backend/src/main/resources/db/migration/V5~V7)
