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
| 백엔드 `./gradlew test` (Testcontainers PostgreSQL 18·Valkey 8, WireMock, S3Mock) | **83/83**, CI 통과(445a063) |
| SkyCore `scripts/test-skycore.sh` | **75/75**(골든 계약 파일 디코딩, gzip 손상 입력, 지역 선택, 밤 날짜, 뜸·남중·짐: 토성·시리우스·북극성 지지 않음·아케르나르 뜨지 않음) |
| iOS 빌드 | Debug 시뮬레이터, Release 기기(서명 없이) 경고 0 |
| `scripts/neon-ops-check.sh` (TLS 전용·비슈퍼유저 관리자 Neon 대역) | **35/35**(최초 설정 2회와 비밀번호 교체, 풀러·평문 URL 거부, `--save-local` 0600, 새 DB 복원과 실패 시 정리, 기존·운영 DB 거부, pin/unpin, 인자·로그에 비밀번호 없음) |
| `scripts/etl-local-e2e.sh` | 가짜 data.go.kr → 워크플로와 같은 jar 실행 → S3 호환 버킷 → 익명 읽기 검사 통과(17개 지역, 1,426 B, 발표 180분 전) |
| 시뮬레이터 끝단 | 같은 버킷에서 칩 "오늘 밤 75 · 좋음 · 11시 발표"([w3-e2e-bucket-chip](screens/w3-e2e-bucket-chip.png)). 새 팩 발행 뒤 **117초** 만에 칩 갱신([w3-index-chip-updated](screens/w3-index-chip-updated.png)) |
| 워크플로 | actionlint, shellcheck 통과 |
| **실제 Neon Object Storage**(시험 버킷 `starindex-check`, 검증 뒤 삭제) | `etl-local-e2e.sh`로 jar가 path-style·체크섬 `WHEN_REQUIRED`로 발행 → `check-public-pack.py` 통과. 익명 GET에 `Cache-Control: max-age=60, must-revalidate`, `ETag`, `Last-Modified`가 있음, `If-None-Match` → **304**, 익명 PUT·DELETE → **403**. 엔드포인트 `br-plain-rain-b3ncmzca.storage.c-4.ap-southeast-1.aws.neon.tech`(DB와 같은 셀 c-4. 다른 셀은 NoSuchBucket) |
| **운영 설정**(사용자 승인 A안) | 버킷 `starindex-packs`(public_read), 쓰기 자격 증명 `starindex-etl`, `ops/neon/bootstrap.sh --github --save-local`(starindex: 슈퍼유저 아님·DB 생성 권한 없음, TLS 1.3 + channel binding), 시크릿 4개·변수 4개 |
| **Actions → Neon 첫 실행**(`gh workflow run etl -f job=astroDailyJob`, 132초, jar 빌드 포함) | COMPLETED. Flyway V1~V6을 starindex가 적용, 지역 17, 표 소유자 전부 starindex. 비밀 값은 로그에서 `***` |
| iOS Release | `STARINDEX_PACK_BASE_URL` = 운영 버킷(https), 서명 없는 기기 빌드 성공, Info.plist 확인 |

스크린샷: [칩](screens/w3-index-chip.png), [지수 시트](screens/w3-index-sheet.png), [토성 뜸·남중·짐](screens/w3-detail-riseset.png), [북극성 지지 않음](screens/w3-detail-riseset-polaris.png), [저장된 예보](screens/w3-index-chip-stored.png), [오프라인](screens/w3-index-chip-offline.png), [미설정](screens/w3-index-chip-unconfigured.png).

## W3 완료 기준(PLAN 5장, ADR-017 반영) 상태

| 기준 | 상태 | 남은 일 |
|---|---|---|
| ① 공개 팩 검사 통과 | 실제 Neon 시험 버킷에서 통과 | 인증키가 들어오면 운영 버킷 첫 발행 뒤 워크플로가 자동 검사 |
| ② 버킷은 자격 증명으로만 쓰기, 서버는 루프백만 | **통과**(익명 PUT·DELETE 403, `LocalOnlyFilter` 테스트) | — |
| ③ T19(발행 뒤 5분 안에 실기기 갱신) | 시뮬레이터 117초 | 실기기와 실제 버킷 |
| ④ 24시간(발표 8회) 무인 수집·발행 | 미시작 | 인증키와 시크릿 설정 뒤 |
| ⑤ 비용 0원 | 설계상 0원(ADR-017 표) | 첫 주 Actions 분·Neon Usage 확인 |
| ⑥ AWS·RDS 자원 0개 | 만든 적 없음 | — |

## 데이터 수명 주기 (ADR-018, 10-01 추가)

- 수집 데이터 12시간(예보는 예보 시각 기준, 밤·날짜 데이터는 지난 뒤), 이력 2일, 매 수집 끝과 매일 정리, 밤 경계 06시(백엔드·앱 함께)
- 검증: 백엔드 86/86, SkyCore 75/75, 로컬 끝단에서 파이프라인 끝 정리 단계 동작

## 사용자 조치가 필요한 것

1. **data.go.kr 인증키**: SERVICE-PLAN 7.1의 컷 규칙은 "10/1 18:00까지 3건을 확보하지 못하면 M0-b·M0-c를 컷한다"이다.
2. ~~Neon 버킷·자격 증명·GitHub 시크릿·변수~~: **완료**(10-01, 사용자 승인). 남은 시크릿은 인증키 하나다: `gh secret set DATA_GO_KR_SERVICE_KEY`.
3. 발표 일자·형식·평가 항목. AWS·RDS 제외가 평가에 미치는 영향은 [불확실]이다(ADR-016·017).

## 아직 확인하지 못한 것

- GitHub 예약 실행의 실제 지연. :20분 실행이 몇 분 늦는지는 첫 주 기록으로 본다.
- 실기기에서 칩을 탭할 때 하늘 탭으로 새지 않는지. 헤드리스 시뮬레이터에서는 탭을 주입할 수 없었다.
- iOS 에이전트가 알린 확인 사항
  - 광주 시내는 '전남광주'(SIDO)가 아니라 추가 지점 '광주'로 선택된다. 의도한 동작인지 확인이 필요하다.
  - 위치 권한 문구 "위치는 기기 밖으로 전송되지 않습니다"는 SERVICE-PLAN 8.5-5가 피하라고 한 표현이다.
  - `INFOPLIST_KEY_UIStatusBarHidden`이 커스텀 Info.plist 때문에 적용되지 않는다.
