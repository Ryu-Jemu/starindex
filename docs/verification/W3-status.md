# M0-W3 진행 현황 (2026-10-01)

W3 작업 중 같은 날 사용자 결정 세 가지가 들어와 구성이 바뀌었다.
- DB는 Neon Free만 쓰고 RDS는 시연에도 쓰지 않는다(ADR-016).
- AWS를 프로젝트에서 뺀다(ADR-017).
- 별 보기는 모바일에서 동작하고 전부 무과금이어야 한다. ETL은 사용자가 고른 GitHub Actions 예약 실행이 맡는다.

AWS용으로 먼저 만든 코드(CloudFront 출처 필터, CloudWatch 지표, CodeDeploy 훅·CI 배포 잡, EC2 설치)는 커밋 445a063에서 걷어 냈다. CloudFormation 초안은 커밋하지 않았다.

## 완료

| 항목 | 결과 | 근거 |
|---|---|---|
| 백엔드 W3 | 공개 헬스(DB 미조회), 관리자 JWT(bcrypt, 5회 실패 15분 잠금, 로그아웃 거부 목록), 실행 이력 QueryDSL(필터·정렬 enum 화이트리스트), 실행 상세, 수동 실행 202/409, manifest·쿼터 조회, Bootstrap 관리자 화면(CSP, SRI), 라이브 WS(로컬), 루프백 전용 필터, Neon Object Storage 팩 저장소 | d343329, 445a063 |
| 계약 파일 | `contracts/golden/`: 지수 팩·manifest. 백엔드 골든 테스트와 iOS 디코더 테스트가 같은 파일을 검사 | d343329 |
| iOS W3 | 팩 클라이언트(조건부 GET, sha256, gzip, 캐시, 120초 폴링), 지수 칩 7상태, 지수 시트(출처·박명·D4 문구), 상세의 뜸·남중·짐, M0-a(1×1 frame 오염) 수정 | b923ab1 |
| 무과금 운영 | `.github/workflows/etl.yml`(3시간마다 + 매일, jar 캐시, 미설정 시 즉시 종료, 공개 팩 검사, `pg_dump` 아티팩트), `ops/neon/`(bootstrap·restore·pin), `scripts/check-public-pack.py`, `scripts/etl-local-e2e.sh` | 445a063 이후 |
| 문서 | ADR-016·017, PLAN·DB-PLAN·SERVICE-PLAN 대체 표시, ETL.md 8절(운영 절차), demo-script, cost-log | 이 커밋 |

## 검증 결과

| 검증 | 결과 |
|---|---|
| 백엔드 `./gradlew test` (Testcontainers PostgreSQL 18·Valkey 8, WireMock, S3Mock) | **92/92** + catalog-builder 6/6(10-01 재검증 반영 후). CI는 커밋마다 통과 |
| SkyCore `scripts/test-skycore.sh` | **75/75**(골든 계약 파일 디코딩, gzip 손상 입력, 지역 선택, 밤 날짜, 뜸·남중·짐: 토성·시리우스·북극성 지지 않음·아케르나르 뜨지 않음) |
| iOS 빌드 | Debug 시뮬레이터, Release 기기(서명 없이) 경고 0 |
| `scripts/neon-ops-check.sh` (TLS 전용·비슈퍼유저 관리자 Neon 대역) | **35/35**(최초 설정 2회와 비밀번호 교체, 풀러·평문 URL 거부, `--save-local` 0600, 새 DB 복원과 실패 시 정리, 기존·운영 DB 거부, pin/unpin, 인자·로그에 비밀번호 없음) |
| `scripts/etl-local-e2e.sh` | 가짜 data.go.kr → 워크플로와 같은 jar 실행 → S3 호환 버킷 → 익명 읽기 검사 통과(17개 지역). data.go.kr에 닿지 못하면 jar 종료 코드 **75**, `retentionJob` 단독 실행 COMPLETED |
| 시뮬레이터 끝단 | 같은 버킷에서 칩 "오늘 밤 75 · 좋음 · 11시 발표"([w3-e2e-bucket-chip](screens/w3-e2e-bucket-chip.png)). 새 팩 발행 뒤 **117초** 만에 칩 갱신([w3-index-chip-updated](screens/w3-index-chip-updated.png)) |
| 워크플로 | actionlint 1.7.12, shellcheck 통과 |
| **실제 Neon Object Storage**(시험 버킷 `starindex-check`, 검증 뒤 삭제) | `etl-local-e2e.sh`로 jar가 path-style·체크섬 `WHEN_REQUIRED`로 발행 → `check-public-pack.py` 통과. 익명 GET에 `Cache-Control: max-age=60, must-revalidate`, `ETag`, `Last-Modified`가 있음, `If-None-Match` → **304**, 익명 PUT·DELETE → **403**. 엔드포인트 `br-plain-rain-b3ncmzca.storage.c-4.ap-southeast-1.aws.neon.tech`(DB와 같은 셀 c-4. 다른 셀은 NoSuchBucket) |
| **운영 설정**(사용자 승인 A안) | 버킷 `starindex-packs`(public_read), 쓰기 자격 증명 `starindex-etl`, `ops/neon/bootstrap.sh --github --save-local`(starindex: 슈퍼유저 아님·DB 생성 권한 없음, TLS 1.3 + channel binding), 시크릿 4개·변수 4개 |
| **Actions → Neon 첫 실행**(`gh workflow run etl -f job=astroDailyJob`, 132초, jar 빌드 포함) | COMPLETED. Flyway V1~V6을 starindex가 적용, 지역 17, 표 소유자 전부 starindex. 비밀 값은 로그에서 `***` |
| iOS Release | `STARINDEX_PACK_BASE_URL` = 운영 버킷(https), 서명 없는 기기 빌드 성공, Info.plist 확인 |

스크린샷: [칩](screens/w3-index-chip.png), [지수 시트](screens/w3-index-sheet.png), [토성 뜸·남중·짐](screens/w3-detail-riseset.png), [북극성 지지 않음](screens/w3-detail-riseset-polaris.png), [저장된 예보](screens/w3-index-chip-stored.png), [오프라인](screens/w3-index-chip-offline.png), [미설정](screens/w3-index-chip-unconfigured.png).

## W3 완료 기준(PLAN 5장, ADR-017 반영) 상태

| 기준 | 상태 | 남은 일 |
|---|---|---|
| ① 공개 팩 검사 통과 | **통과**(운영 버킷, Actions와 Mac 양쪽, 10-01) | — |
| ② 버킷은 자격 증명으로만 쓰기, 서버는 루프백만 | **통과**(익명 PUT·DELETE 403, `LocalOnlyFilter` 테스트) | — |
| ③ T19(발행 뒤 5분 안에 실기기 갱신) | 시뮬레이터 117초 | 실기기와 실제 버킷 |
| ④ 24시간(발표 8회) 무인 수집·발행 | **막힘**: 예약 실행이 한 번도 일어나지 않음(아래) | 예약 실행 대안(사용자 결정) |
| ⑤ 비용 0원 | 설계상 0원(ADR-017 표). 10-01 Actions 약 85분 | 첫 주 Actions 분·Neon Usage 확인 |
| ⑥ AWS·RDS 자원 0개 | 만든 적 없음 | — |

## 데이터 수명 주기 (ADR-018, 10-01 추가)

- 수집 데이터 12시간(예보는 예보 시각 기준, 밤·날짜 데이터는 지난 뒤), 이력 2일, 매 수집 끝과 매일 정리, 밤 경계 06시(백엔드·앱 함께)
- 검증: 백엔드 86/86(당시), SkyCore 75/75, 로컬 끝단에서 파이프라인 끝 정리 단계 동작

## 실데이터 검증과 수정 (10-01 오후)

첫 실데이터 팩(14시 발표) 뒤 독립 검증 워크플로 두 번을 돌렸다. 운영에는 읽기만 했다(Neon 읽기 전용 트랜잭션, 버킷 익명 GET).

**1차 검증(5개 관점, 모두 통과)**

| 관점 | 결과 |
|---|---|
| 지수 재계산 | Python(astronomy-engine 2.1.19, PyEphem 교차 확인)으로 17/17 일치, 72시간 배열 7,344칸 DB와 차이 0 |
| DB 수명 주기 | 예보 1,122행·17격자, 12시간 지난 행 0, 밤·날짜 표에 지난 날 없음, DB 9.0 MB(512 MiB의 1.7%) |
| 백업 복원 | 일일 백업 아티팩트를 로컬 PostgreSQL 18에 복원(오류 0, 소유자 전부 starindex, Flyway V1~V6 체크섬 일치) |
| 앱(시뮬레이터, 운영 버킷) | 칩·시트 값이 팩·DB와 일치([수정 전 칩](screens/w3-live-chip.png), [시트](screens/w3-live-sheet.png)) |
| 비밀·로그 | 로그의 비밀값은 모두 `***`, 팩·로그에 좌표·키 없음 |

- 찾은 결함(중 1, 하 여러 건)은 커밋 e645316에서 고쳤다(ADR-019).
  - 달을 매시 정각에만 계산해서, 월출이 낀 최적 창을 '달빛 영향 없음'으로 표시했다. 서울 10/1은 73% 달이 20:53에 뜬다.
  - 점수를 두 번 반올림했다.
  - 예보가 빈 시간이 있어도 창으로 묶었다.
  - 박명 시각의 초를 버렸다.
  - 매일 지난 날짜 달력을 다시 저장했다.
  - 상태 바가 보였다.
- 수정 팩: 수동 실행 36833129245가 `20261001-1400-3742d5d8`을 발행했다. 15개 지역이 MOON_NONE에서 MOON_SOME으로 바뀌었고 점수는 92~94점이다(서울 98→93). 전남광주는 82점, 제주는 83점이다.

**data.go.kr 해외 IP 차단(실측)**: 16:3x~16:4x에 러너 2대(실행 36831086988, 36832136117)에서 `apis.data.go.kr` 연결이 모두 시간 초과였다. 같은 시각 다른 러너와 이 Mac은 정상이었다. 그래서 막힌 러너면 새 러너로 최대 3번 시도하게 했다(ae1a6b5, ADR-017 위험 표).

**2차 검증(수정 재검증, 6개 에이전트)**

- 운영 팩 3742d5d8을 서면 규칙만으로 다시 계산했다. score·grade·best·reasons·contrib 17/17, 계산 박명 102/102, 천문연 박명 68/68이 일치한다. 수정 전 팩과의 차이 85개는 모두 수정으로 설명된다.
- 앱: 시뮬레이터가 실행 9초 안에 옛 캐시를 새 팩으로 바꿨다. 칩은 '오늘 밤 93 · 매우 좋음 · 14시 발표', 시트 이유는 '맑음 · 달빛 조금'이다. 상태 바는 없다([칩](screens/w3-live-chip-fixed.png), [시트](screens/w3-live-sheet-fixed.png)).
- 새로 찾은 결함(반박 검토로 확인)은 이 커밋에서 고쳤다.
  - [중] 새벽 경계: 마지막 어두운 칸이 최대 59분 박명이었다. 달이 새벽 전에 지는 밤에는 최적 창이 박명 속으로 이어지고 등급이 부풀었다. 서울 10/22 맑음이면 04:00–06:00 100점이었다(10/1 운영 팩은 영향 없음). 이제 어두운 시간은 칸 전체가 천문학적 밤 안에 드는 정각만이다(ADR-019 결정 6).
  - [중] 재시도는 curl 접속 확인만 보고 정해졌다. 그래서 jar가 수집 중에 닿지 못하면 새 러너로 다시 시도하지 않았다. 이제 jar가 종료 코드 75를 내고, 워크플로는 이를 막힘으로 본다.
  - [하] 접속 확인이 data.go.kr이 필요 없는 일까지 막았다. 이제 그런 Job은 확인하지 않는다. 마지막 시도가 막히면 `retentionJob`으로 보존 정리를 하고 실패로 끝난다.
  - [하] 시계를 고정한 통합 테스트 한 곳이 실제 시각으로 픽스처를 만들어, 10/19부터 실패할 예정이었다.
  - 고친 워크플로의 첫 실행(36838305459, 6ec290a)은 1번째 시도에서 끝났다. 접속 확인을 통과했고(HTTP 403), 17시 발표 17/17 격자 1,479행을 받아 팩 `20261001-1700-fba8e5ef`(4,307 B)를 발행했다. 공개 팩 검사를 통과했고 2·3번째 시도는 생략됐다. 17개 지역 점수·창·이유는 14시 발표와 같다(맑음, 달빛 조금).
  - [문서] Actions 사용량을 월 약 600분에서 약 900분으로 고쳤다. Job마다 분 단위로 올려 세기 때문이다(예보 실행 약 3분, 매일 실행 약 5분). 10월 1일 하루 동안 CI를 포함해 약 85분을 썼다.

## 사용자 조치가 필요한 것

1. ~~data.go.kr 인증키~~: **완료(10-01 15:21 KST, 컷 기한 18:00 전)**. GitHub 시크릿 `DATA_GO_KR_SERVICE_KEY` 등록.
   - `apiKeyCheckJob`: 필수 3개(단기예보·출몰시각·천문현상)와 선택 2개(특일·음양력)가 모두 OK다.
   - 실제 데이터 첫 발행(`forecastPipelineJob`, 14시 발표): 17개 지점 저장, 팩 `20261001-1400-728917d8`(4,031 B). 공개 팩 검사는 Actions와 Mac 양쪽에서 통과했다.
   - 서울 98점, 최적 20~22시. 천문연 박명 시각은 매일 00:40 실행(`astroDailyJob`) 뒤 팩에 들어간다.
2. ~~Neon 버킷·자격 증명·GitHub 시크릿·변수~~: **완료**(10-01, 사용자 승인). 시크릿 5개와 변수 4개가 모두 있다.
3. 발표 일자·형식·평가 항목. AWS·RDS 제외가 평가에 미치는 영향은 [불확실]이다(ADR-016·017).
4. **예약 실행 대안**(아래 '아직 확인하지 못한 것' 첫 항목): 외부 무료 cron이 `workflow_dispatch`를 부르게 할지, 저장소를 공개할지, 더 기다릴지.
5. **비밀 교체 여부**: 지금 쓰는 DB 비밀번호와 Neon 스토리지 키는 실행 36818627089(비밀 범위를 단계로 좁히기 전)에서 서드파티 액션과 Gradle 빌드 환경 변수에 노출됐다. 로그에는 `***`로 가려졌다. 위험은 낮다고 본다. 교체하려면 `ops/neon/bootstrap.sh --github --save-local`과 새 storage credential이 필요하다.

## 아직 확인하지 못한 것

- **GitHub 예약 실행이 한 번도 일어나지 않았다.** 워크플로는 14:01 KST에 등록됐고 상태는 active다. 14:20과 17:20 KST 회차가 모두 없었다. 17:55까지 관찰했고, GitHub API의 schedule 실행 수는 0이다.
  - 같은 시각 `workflow_dispatch`는 정상이었고, GitHub 상태 페이지에 Actions 장애는 없었다.
  - 2026년 7~9월 커뮤니티에 같은 증상이 여럿 보고됐다. 비공개 저장소나 새 계정·저장소에서 예약 실행이 전혀 일어나지 않았다는 내용이다(discussions #202602, #205984 등). GitHub 직원의 답이나 확인된 원인은 없다.
  - 'Free 비공개 저장소는 예약 실행이 막힌다'는 주장도 있다. 공식 문서에는 그런 제한이 없어서 [불확실]이다.
  - 그동안 운영 팩은 수동 실행으로만 갱신된다. manifest가 6시간을 넘기면 앱에 'N시간 전 발표 기준'이 붙는다. 06시에 밤이 바뀐 뒤에는 칩이 '저장된 예보 · 10/1 14시 발표'로 바뀐다(오늘 밤 지수 없음).
- 실기기에서 칩을 탭할 때 하늘 탭으로 새지 않는지. 헤드리스 시뮬레이터에서는 탭을 주입할 수 없었다.
- iOS 에이전트가 알린 확인 사항
  - 광주 시내는 '전남광주'(SIDO)가 아니라 추가 지점 '광주'로 선택된다. 의도한 동작인지 확인이 필요하다.
  - 위치 권한 문구 "위치는 기기 밖으로 전송되지 않습니다"는 SERVICE-PLAN 8.5-5가 피하라고 한 표현이다.
  - ~~`INFOPLIST_KEY_UIStatusBarHidden`이 적용되지 않는다~~: Info.plist 속성으로 옮겨 해결했다(e645316, 화면에서 확인).
