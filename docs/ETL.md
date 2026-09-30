# ETL 운영 안내

인증키를 넣으면 바로 돌아가도록 만든 ETL의 사용법이다. DB는 PostgreSQL 18(ADR-013), 캐시와 호출 한도는 Valkey 8, 배치는 Spring Batch 6이다.

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
scripts/etl.sh astro           # 오늘부터 4일: Astronomy Engine 박명 + 천문연 출몰시각 + 교차검증
scripts/etl.sh events          # 이번 달과 다음 달 천문현상 (+ 특일·음양력, 승인된 경우)
```

- 결과 팩: `backend/build/packs/packs/index/<version>/index.json.gz`
- manifest: `backend/build/packs/packs/manifest/latest.json`
- 종료 코드: 0이면 COMPLETED, 0이 아니면 FAILED. 마지막 `[ETL]` 블록에 단계별 요약과 실패 이유가 나온다.

파라미터(선택, `key=value`)

| 명령 | 파라미터 | 예 |
|---|---|---|
| `forecast`, `pipeline` | `base=yyyyMMddHHmm` (발표 시각. 없으면 지금 받을 수 있는 최신 발표) | `base=202610121700` |
| `publish`, `pipeline` | `nightDate=yyyy-MM-dd` (없으면 12시 기준 오늘 밤) | `nightDate=2026-10-12` |
| `astro` | `from=yyyy-MM-dd` | `from=2026-10-12` |
| `events` | `month=yyyy-MM` (없으면 이번 달과 다음 달) | `month=2026-10` |

## 3. Job 구성

| Job | 단계 | 키가 없을 때 |
|---|---|---|
| `forecastIngestJob` | 키 확인 → 격자 17개 수집(격자마다 트랜잭션, 1000행씩 페이지 넘김) → 완결성 90% 검사 | 안내 메시지와 함께 중단 |
| `starIndexPublishJob` | 지수 계산(천문박명 시간대 × 구름·강수·달) → 저장 → 팩(gzip, 압축본 sha256) → manifest → Redis 알림 | 예보가 없으면 중단 |
| `forecastPipelineJob` | 위 두 Job을 이어서 실행(스케줄러용) | 중단 |
| `astroDailyJob` | Astronomy Engine 계산 → 키 판정 → 천문연 출몰시각 → 교차검증 | 계산만 하고 COMPLETED |
| `astroEventsJob` | 키 확인 → 천문현상 → 특일(선택) → 음양력(선택) | 중단 |
| `apiKeyCheckJob` | 키 확인 → API별 1회 호출 보고 | 중단 |

오류 처리

| 오류 | 동작 |
|---|---|
| 인증키 거부(20·21·30~33), 호출 한도(22·23) | 즉시 중단. 나머지 격자도 같은 이유로 실패하므로 호출을 낭비하지 않는다. |
| 통신·제공기관 오류 | 2회 재시도(1초, 3초). 그래도 실패하면 기록하고 다음 격자로 넘어간다. 완결성이 90% 미만이면 Job 실패. |
| 자료 없음(03) | 오류가 아니다. 발표 직후나 아직 공개되지 않은 날짜다. |

## 4. 스케줄 (운영)

`ETL_SCHEDULE_ENABLED=true`일 때만 켜진다. 모두 KST이고, 같은 Job은 겹쳐 돌지 않는다.

- 단기예보 파이프라인: 매 발표 15분 뒤(02:15, 05:15, … 23:15). 발표 10분 뒤부터 제공된다.
- 출몰시각: 매일 00:30
- 천문현상·특일: 매일 01:10. 대체공휴일은 늦게 공표되기 때문이다.

호출량은 하루 기상청 약 136회(17 × 8), 천문연 약 70회다. 개발계정 한도(API마다 하루 10,000회)의 2% 이하다. 앱은 Redis `quota:{api}:{날짜}`로 70%에서 경고하고 90%에서 멈춘다.

## 5. 데이터와 출처

| 테이블 | 내용 |
|---|---|
| `region` | 기상청 격자 시트(2026-07-01) 1단계 16개 시·도 + 광주 서구(추가 지점) |
| `kma_forecast`, `kma_forecast_issue` | 단기예보 원값과 수치. 결측(±900 이상)과 연장 구간 코드값을 구분한다. |
| `kasi_riseset`, `astro_night`, `astro_crosscheck` | 천문연 시각, Astronomy Engine 시각, 두 값의 차(초) |
| `kasi_astro_event`, `kasi_special_day`, `kasi_lunar_day` | 월 단위 천문 달력 |
| `star_index_hourly`, `star_index_nightly` | 시간별 계수와 점수, 밤 점수·최적 2시간·기여도(JSONB) |
| `data_pack`, `etl_api_call` | 발행 이력과 외부 호출 감사. 키와 사용자 좌표는 기록하지 않는다. |

출처 표시(공공누리 제1유형): 팩의 `attribution`에 "기상청 단기예보 조회서비스(출처: 기상청)", 한국천문연구원, Astronomy Engine(MIT)을 넣는다.

## 6. 확인된 것과 남은 것

- 확인됨
  - 가짜 키로 실제 게이트웨이를 호출했을 때(2026-09-30) API 5개가 모두 코드 30(키 미등록)을 돌려줬다. 서비스 경로와 오퍼레이션 이름이 맞다는 뜻이다. 경로가 틀리면 코드 12가 온다.
  - 테스트: 순수 로직, 클라이언트(WireMock), PostgreSQL 18 통합 테스트
- 키를 받은 뒤 확인할 것
  - 천문연 실제 응답의 시각 형식(`HHmm` 뒤 공백으로 예상)
  - 월출이 없는 날의 표기
  - 단기예보 과거 발표를 얼마나 거슬러 받을 수 있는지
