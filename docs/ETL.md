# ETL 운영 안내

인증키를 넣으면 바로 돌아가도록 만든 ETL의 사용법이다.
- 운영: **GitHub Actions 예약 실행**(`.github/workflows/etl.yml`)이 Neon Free PostgreSQL 18에 수집하고, 앱 팩을 Neon Object Storage 공개 버킷에 올린다. AWS는 쓰지 않는다(ADR-017). 설정은 8절.
- DB: PostgreSQL 18. 운영은 Neon Free(싱가포르, TLS, 직접 엔드포인트)다(ADR-013, ADR-015, ADR-016). 로컬은 docker compose다.
- 캐시와 호출 한도: Valkey 8(로컬 compose, Actions 서비스 컨테이너)
- 배치: Spring Batch 6
- 보관(데이터 수명 주기, ADR-018): 수집 데이터 12시간, 이력 2일, 매 수집 끝에 정리(7절)

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
| `publish`, `pipeline` | `nightDate=yyyy-MM-dd` (없으면 06시 기준 오늘 밤). 이미 더 최신 밤이나 발표가 발행돼 있으면 팩만 저장하고 manifest는 그대로 둔다(과거 밤 재계산이 앱을 되돌리지 않음). 예보는 예보 시각부터 12시간만 남으므로 지난 밤은 다시 만들 수 없다(ADR-018). | `nightDate=2026-10-12` |
| `astro` | `from=yyyy-MM-dd` | `from=2026-10-12` |
| `events` | `month=yyyy-MM` (없으면 이번 달과 다음 달) | `month=2026-10` |

## 3. Job 구성

| Job | 단계 | 키가 없을 때 |
|---|---|---|
| `forecastIngestJob` | 키 확인 → 격자 17개 수집(격자마다 트랜잭션, 1000행씩 페이지 넘김) → 6개 항목만 시간대별 1행으로 병합 → 완결성 90% 검사 | 안내 메시지와 함께 중단 |
| `starIndexPublishJob` | 지수 계산(천문박명 시간대 × 구름·강수·달) → 저장 → 팩(gzip, 압축본 sha256) → manifest → Redis 알림 | 예보가 없으면 중단 |
| `forecastPipelineJob` | 위 두 Job을 이어서 실행한 뒤 데이터 수명 정리(7절). 예약 실행용 | 중단 |
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

운영 스케줄은 `.github/workflows/etl.yml`이다(ADR-017). 모두 KST이고, 같은 워크플로는 겹쳐 돌지 않는다(concurrency `etl`).

- 단기예보 파이프라인: 매 발표 20분 뒤(02:20, 05:20, … 23:20). 발표 10분 뒤부터 제공되고, GitHub는 정각 무렵 예약 실행을 가장 많이 늦춘다.
- 매일 00:40: 보존 정리 + 출몰시각(`astroDailyJob`), 천문현상·특일(`astroEventsJob`. 대체공휴일은 늦게 공표된다), DB 백업
- 인증키 시크릿이 없으면 키가 필요한 Job은 건너뛰고(알림만), 보존 정리와 지수 재발행만 한다.
- 서버 안의 스케줄러(`ETL_SCHEDULE_ENABLED=true`)는 Mac에서 로컬 서버를 오래 켜 둘 때만 쓴다. 운영과 함께 켜면 같은 DB에 두 번 수집하므로 켜지 않는다.

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

## 7. 데이터 수명 주기 (ADR-018)

매 수집 실행의 끝(`forecastPipelineJob`의 마지막 단계, 3시간마다)과 매일 `astroDailyJob`의 첫 단계에서 정리한다. 기준 시각 하나(asOf)에서 모든 기준을 계산하고, 밤 날짜는 **KST 06시**에 바뀐다(06시부터 '오늘 밤'은 다가오는 밤).

| 대상 | 수명 |
|---|---|
| `kma_forecast_hour` | **12시간**: 예보 시각이 12시간 지난 행. 수집이 끊겨도 앞으로의 예보는 남는다 |
| `kasi_riseset`, `star_index_nightly`, 천문 달력 3종 | 그 밤·그날이 지나면 |
| `etl_api_call`, `astro_crosscheck`, `BATCH_*` 메타데이터 | **2일** |
| `data_pack` 행과 팩 파일 | 2일. 단 manifest가 가리키는 현재 팩, 종류별 최신 3개, `pinned` 팩은 지우지 않는다 |

- 설정: `starindex.etl.data-retention`(기본 `12h`, 최소 12시간: 05:20 실행이 어제 저녁 예보를 읽어야 함), `history-retention`(기본 `2d`, 최소 1일), `pack-keep-min`(기본 3). 최소보다 작으면 앱이 시작하지 않는다.
- 06시 이후에는 어젯밤 지수를 다시 만들 수 없다. 그 밤의 마지막 팩은 버킷에 남는다.
- 팩 고정: 로컬 `scripts/etl.sh pin|unpin <version>`, 운영(Neon) `ops/neon/pin.sh <version> [--unpin]`.
- 운영 백업: 매일 00:40 KST 워크플로가 전체 `pg_dump`(PostgreSQL 18 클라이언트)를 GitHub 아티팩트 `starindex-db-<날짜>`로 7일 보관한다. Neon Free의 복원 기간은 6시간뿐이라 이것이 실제 백업이다. 복구는 6시간 안이면 Neon 즉시 복원, 그보다 오래됐으면 `ops/neon/restore.sh`(운영 DB 옆 새 DB에 복원한 뒤 `DB_URL` 시크릿만 바꾼다).
- 연결 풀은 유휴 연결을 남기지 않는다(최소 0, 60초, keepalive 끔). Neon이 5분 뒤 쉬어야 월 100 CU-시간 안에 든다. `/actuator/health`를 주기적으로 호출하지 않는다.

## 8. 무과금 운영 설정 (GitHub Actions + Neon, ADR-017)

모두 무료 한도 안에서 돈다. GitHub와 Neon 모두 결제 수단이 없으면 한도를 넘어도 과금되지 않고 멈춘다. 시크릿과 변수가 갖춰지기 전에는 예약 실행이 몇 초 만에 "not configured" 알림을 남기고 끝난다.

| 순서 | 할 일 | 명령 |
|---|---|---|
| 1 | Neon 접속 정보 파일. 직접 엔드포인트(`-pooler` 없음), DB 이름 `starindex` | `cp ops/neon/neon.env.example ops/neon/neon.env` 후 `DB_URL` 편집 |
| 2 | 앱 역할·DB 만들기, 시크릿 `DB_URL`·`DB_PASSWORD`, 로컬 관리자용 `ops/neon/app.env` | `ops/neon/bootstrap.sh --github --save-local` (neondb_owner 비밀번호를 묻는다) |
| 3 | 공개 읽기 버킷 | `neon bucket create starindex-packs --project-id holy-mountain-03233485 --branch production --access-level public_read` |
| 4 | 쓰기 자격 증명 → 시크릿 | `neon credentials create --project-id holy-mountain-03233485 --branch production --name starindex-etl --scope storage:read --scope storage:write -o json` → `token_id`를 `gh secret set NEON_STORAGE_KEY_ID`, `s3_secret_access_key`를 `gh secret set NEON_STORAGE_SECRET`(둘 다 표준 입력으로) |
| 5 | 변수 4개. 엔드포인트는 Console → Connect → Storage(또는 4의 출력)의 `https://br-….storage.c-N.<region>.aws.neon.tech` | `gh variable set PACK_BUCKET -b starindex-packs`, `PACK_S3_ENDPOINT -b <엔드포인트>`, `PACK_S3_REGION -b ap-southeast-1`, `PACK_PUBLIC_URL -b <엔드포인트>/starindex-packs` |
| 6 | 인증키 | `gh secret set DATA_GO_KR_SERVICE_KEY` (Decoding 키를 붙여 넣는다) |
| 7 | 첫 실행과 확인. 첫 실행에서 Flyway가 표를 만든다 | `gh workflow run etl -f job=forecastPipelineJob` → `gh run watch` → `python3 scripts/check-public-pack.py "<PACK_PUBLIC_URL>"` |
| 8 | 앱 Release 빌드가 버킷을 읽게 한다 | `ios/project.yml`의 Release `STARINDEX_PACK_BASE_URL`에 `PACK_PUBLIC_URL`(https)을 넣고 `cd ios && xcodegen generate` |

- 관리자 화면(운영 데이터): Docker Desktop을 켜고 `scripts/admin-neon.sh`를 실행한 뒤 `http://localhost:8080/admin`을 연다.
  - DB 정보는 2가 만든 `ops/neon/app.env`에서 읽는다. 운영 접속 정보를 `backend/.env`에 두지 않는 이유는 로컬 개발(`scripts/etl.sh`)이 운영 DB에 쓰지 않게 하기 위해서다.
  - 관리자 비밀번호 해시는 `backend/.env`의 `ADMIN_PASSWORD_HASH`다(README 참고).
  - 버킷의 manifest까지 보려면 `ops/neon/app.env`에 `PACK_BUCKET`, `AWS_ENDPOINT_URL_S3`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`를 더한다.
  - '지금 실행'은 Mac에서 Job을 돌린다. 운영 실행은 `gh workflow run etl -f job=<Job> -f params="nightDate=2026-10-12"`.
- 감시: 실행이 실패하면 GitHub가 메일을 보낸다(공개 팩의 발표가 6시간보다 오래되면 실패). 첫 주에 Neon Usage(CU-시간, 전송량)와 Actions 사용 분을 확인한다.
- 복원: `gh run download <run-id> -n starindex-db-<날짜> -D /tmp/r && ops/neon/restore.sh /tmp/r/starindex.dump starindex_<날짜>`. 출력에 나오는 `gh secret set DB_URL` 명령으로 전환한다.
- 로컬 재현(키·계정 없이): `scripts/etl-local-e2e.sh`. 가짜 data.go.kr → 워크플로와 같은 jar 실행 → S3 호환 버킷(S3Mock) → 익명 읽기 검사 순서로 돈다. 운영 스크립트 검증은 `scripts/neon-ops-check.sh`다.
