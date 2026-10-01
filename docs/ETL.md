# ETL 운영 안내

인증키를 넣으면 바로 돌아가도록 만든 ETL의 사용법이다.
- DB: PostgreSQL 18. 운영은 Neon Free(싱가포르, TLS, 직접 엔드포인트)다(ADR-013, ADR-015, 세부는 `docs/DB-PLAN.md` 11장). 로컬은 docker compose다.
- 캐시와 호출 한도: Valkey(로컬 8, EC2 AL2023 패키지 9)
- 배치: Spring Batch 6
- 보관: 서비스에 필요한 것만, 기본 2일(7절)

## 1. 인증키를 넣고 확인하기 (1분)

1. data.go.kr → 마이페이지 → 개발계정에서 **일반 인증키(Decoding)**를 복사한다.
   - Encoding 키를 넣으면 한 번 더 인코딩돼 코드 30이 난다. 앱이 경고를 띄운다.
2. `backend/.env.example`을 `backend/.env`로 복사하고 `DATA_GO_KR_SERVICE_KEY=`에 붙여 넣는다.
   - `.env`는 git에 올라가지 않는다.
3. Docker Desktop을 켜고 다음을 실행한다.
   ```
   scripts/etl.sh check
   ```
   API마다 1번씩, 모두 5번 호출하고 결과를 한 줄씩 보여 준다.
   - `OK`: 승인되어 동작한다.
   - `FAIL … 키가 거부됐습니다(30 …)`: 그 API의 활용신청이 아직 승인되지 않았거나, 승인 직후라 키가 아직 활성화되지 않았다(1~2시간). 시간을 두고 다시 실행한다.
   - `[선택]`이 붙은 특일·음양력은 실패해도 된다. 이 둘은 R1 첫 주에 따로 신청한다.

## 2. 데이터 채우기

```
scripts/etl.sh pipeline        # 최신 단기예보 발표 → 17개 지점 저장 → 오늘 밤 지수 → 팩 + manifest
scripts/etl.sh astro           # 보존 정리 + 오늘부터 4일 천문연 출몰시각 + Astronomy Engine 교차검증
scripts/etl.sh events          # 이번 달과 다음 달 천문현상 (+ 특일·음양력, 승인된 경우)
scripts/etl.sh pin <version>   # 이 팩 버전은 보존 정리에서 지우지 않는다(데모·롤백용). 해제는 unpin
```

- 결과 팩: `backend/build/packs/packs/index/<version>/index.json.gz`
- manifest: `backend/build/packs/packs/manifest/latest.json`
- 종료 코드: 0이면 COMPLETED, 0이 아니면 FAILED. 마지막 `[ETL]` 블록에 단계별 요약과 실패 이유가 나온다.

파라미터(선택, `key=value`)

| 명령 | 파라미터 | 예 |
|---|---|---|
| `forecast`, `pipeline` | `base=yyyyMMddHHmm` (발표 시각. 없으면 지금 받을 수 있는 최신 발표) | `base=202610121700` |
| `publish`, `pipeline` | `nightDate=yyyy-MM-dd` (없으면 12시 기준 오늘 밤). 이미 더 최신 밤이나 발표가 발행돼 있으면 팩만 저장하고 manifest는 그대로 둔다(과거 밤 재계산이 앱을 되돌리지 않음). 예보는 2일만 보관하므로 이틀보다 이전 밤은 다시 만들 수 없다. | `nightDate=2026-10-12` |
| `astro` | `from=yyyy-MM-dd` | `from=2026-10-12` |
| `events` | `month=yyyy-MM` (없으면 이번 달과 다음 달) | `month=2026-10` |

## 3. Job 구성

| Job | 단계 | 키가 없을 때 |
|---|---|---|
| `forecastIngestJob` | 키 확인 → 격자 17개 수집(격자마다 트랜잭션, 1000행씩 페이지 넘김) → 6개 항목만 시간대별 1행으로 병합 → 완결성 90% 검사 | 안내 메시지와 함께 중단 |
| `starIndexPublishJob` | 지수 계산(천문박명 시간대 × 구름·강수·달) → 저장 → 팩(gzip, 압축본 sha256) → manifest → Redis 알림 | 예보가 없으면 중단 |
| `forecastPipelineJob` | 위 두 Job을 이어서 실행(스케줄러용) | 중단 |
| `astroDailyJob` | 보존 정리(7절) → 키 판정 → 천문연 출몰시각 → 교차검증(Astronomy Engine은 그때그때 계산) | 보존 정리만 하고 COMPLETED |
| `astroEventsJob` | 키 확인 → 천문현상 → 특일(선택) → 음양력(선택) | 중단 |
| `apiKeyCheckJob` | 키 확인 → API별 1회 호출 보고 | 중단 |

오류 처리

| 오류 | 동작 |
|---|---|
| 인증키 거부(20·21·30~33), 일일 한도(22) | 즉시 중단. 나머지 격자도 같은 이유로 실패하므로 호출을 낭비하지 않는다. |
| 요청 형식 오류(10·11·12) | 즉시 중단. 코드나 API 사양 문제라 모든 호출에서 반복된다. |
| 초당 한도(23), 통신·제공기관 오류 | 2회 재시도(1초, 3초). 그래도 실패하면 기록하고 다음 격자로 넘어간다. 완결성이 90% 미만이면 Job 실패. |
| 자료 없음(03) | 오류가 아니다. 발표 직후나 아직 공개되지 않은 날짜다. |
| 보존 정리 일부 실패 | 경고만 남긴다. 단계 종료 코드는 `COMPLETED_WITH_WARNINGS`, Job은 COMPLETED이고 다음 단계도 실행한다. 실패한 항목은 다음 날 다시 시도한다. |

완결성: `forecastFetch` 단계의 `WRITE_COUNT`(저장한 격자)와 `FILTER_COUNT`(실패한 격자)로 남긴다. 관리자 화면의 완결성 = WRITE / (WRITE + FILTER).

## 4. 스케줄 (운영)

`ETL_SCHEDULE_ENABLED=true`일 때만 켜진다. 모두 KST이고, 같은 Job은 겹쳐 돌지 않는다.

- 단기예보 파이프라인: 매 발표 15분 뒤(02:15, 05:15, … 23:15). 발표 10분 뒤부터 제공된다.
- 출몰시각: 매일 00:30
- 천문현상·특일: 매일 01:10. 대체공휴일은 늦게 공표되기 때문이다.

호출량은 하루 기상청 약 187회다(17개 격자 × (1페이지 발표 5회 + 2페이지 발표 3회). 17·20·23시 발표는 1,000행을 넘어 2페이지를 받는다). 천문연은 약 70회다. 개발계정 한도(API마다 하루 10,000회)의 2% 이하다. 앱은 Redis `quota:{api}:{날짜}`로 70%에서 경고하고 90%에서 멈춘다.

## 5. 데이터와 출처

서비스가 읽는 것만 저장한다(ADR-014). 컬럼 목록은 `SchemaGuardTest`가 지킨다.

| 테이블 | 내용 |
|---|---|
| `region` | 기상청 격자 시트(2026-07-01) 1단계 16개 시·도 + 광주 서구(추가 지점) |
| `kma_forecast_hour` | (격자, 예보 시각)마다 1행. SKY, PTY, TMP, REH, WSD, POP 6개 항목의 가장 최근 발표 값. 새 발표에 결측(±900 이상)이 있으면 이전 값을 유지하고, 연장 구간 풍속 코드값은 저장하지 않는다. |
| `kasi_riseset` | 천문연 저녁 시각 4개(일몰, 시민·항해·천문박명 종료). 팩에 "(천문연)"으로 표시한다. |
| `astro_crosscheck` | 천문연 시각과 Astronomy Engine 시각의 차(초) |
| `kasi_astro_event`, `kasi_special_day`, `kasi_lunar_day` | 월 단위 천문 달력 |
| `star_index_nightly` | 밤 점수와 등급(R3 공개 순위용). 시간별 값과 기여도는 팩에만 있다. |
| `data_pack` | 발행 이력. `pinned`이면 보존 정리에서 지우지 않는다. |
| `etl_api_call` | 외부 호출 감사. 오류 문구는 실패한 호출만 80자까지. 키와 사용자 좌표는 기록하지 않는다. |

출처 표시(공공누리 제1유형): 팩의 `attribution`에 "기상청 단기예보 조회서비스(출처: 기상청)", 한국천문연구원, Astronomy Engine(MIT)을 넣는다.

## 6. 확인된 것과 남은 것

- 확인됨
  - 가짜 키로 실제 게이트웨이를 호출했을 때(2026-09-30) API 5개가 모두 코드 30(키 미등록)을 돌려줬다. 서비스 경로와 오퍼레이션 이름이 맞다는 뜻이다. 경로가 틀리면 코드 12가 온다.
  - 테스트: 순수 로직, 클라이언트(WireMock), PostgreSQL 18 통합 테스트
- 키를 받은 뒤 확인할 것
  - 천문연 실제 응답의 시각 형식(`HHmm` 뒤 공백으로 예상)
  - 월출이 없는 날의 표기
  - 단기예보 과거 발표를 얼마나 거슬러 받을 수 있는지

## 7. 보존 정책

매일 `astroDailyJob`의 첫 단계에서 정리한다. 기준 시각 하나(asOf)에서 모든 기준을 계산하고, 밤 날짜는 KST 12시에 바뀐다. 세부와 근거는 `docs/DB-PLAN.md` 2절이다.

| 대상 | 보관 |
|---|---|
| `kma_forecast_hour`, `kasi_riseset`, `star_index_nightly` | 2일(어젯밤 재발행에 필요한 최소) |
| `etl_api_call`, `astro_crosscheck`, `BATCH_*` 메타데이터 | 8일(G6 "7일 연속" 판정 + 1일) |
| `data_pack` 행과 팩 파일 | 8일. 단 manifest가 가리키는 현재 팩, 종류별 최신 3개, `pinned` 팩은 지우지 않는다. |
| 천문 달력 3종 | 밤 날짜가 속한 달의 지난달 1일부터 |

- 설정: `starindex.etl.forecast-retention-days`(기본 2, 최소 2), `audit-retention-days`(기본 8, 최소 8), `pack-keep-min`(기본 3). 최소보다 작으면 앱이 시작하지 않는다.
- 팩 고정: 로컬 `scripts/etl.sh pin|unpin <version>`, EC2 `/opt/starindex/postgres/pin.sh <version> [--unpin]`.
- 운영 백업: 매일 05:20 KST 전체 `pg_dump`를 S3 `backup/db/`에 올리고 7일 뒤 지운다(`deploy/postgres/backup.sh`). Neon Free의 복원 기간은 6시간뿐이라 이것이 실제 백업이다. 복구는 6시간 안이면 Neon 즉시 복원, 그보다 오래됐으면 `restore.sh`(운영 DB 옆 새 DB에 복원한 뒤 `--switch`).
- 연결 풀은 유휴 연결을 남기지 않는다(최소 0, 60초, keepalive 끔). Neon이 5분 뒤 쉬어야 월 100 CU-시간 안에 든다. `/actuator/health`를 주기적으로 호출하지 않는다.
