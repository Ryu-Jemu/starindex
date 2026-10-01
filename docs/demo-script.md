# M0 시연 대본 (발표 10/20 기준, PLAN 5장·SERVICE-PLAN 7.1)

발표 일자·형식·필수 평가 항목은 아직 확인되지 않았다(PLAN 8장 0번). 아래 시각은 10/20 서울 기준이다. 날짜가 바뀌면 "천체 시각표"의 계산을 다시 돌린다.

## 천체 시각표 (계산값, Astronomy Engine v2.1.19, 서울 시청 37.5665°N 126.9780°E)

| 항목 | 10/20 |
|---|---|
| 일몰 | 17:48 |
| 천문박명 끝 | 19:16 |
| 토성 | 17:11 뜸, 19:00 고도 21°·방위 105°(동남동), 20:00 32°·116°, **23:17 남중(고도 54°)**, 0.3등 |
| 달 | 14:43 뜸, 19:54 남중(고도 35°), 20:00 밝은 면 67% |
| 목성·화성·금성 | 저녁에는 지평선 아래 |

- 토성은 19:00 이후 고도 15°를 넘는다. 해가 진 뒤 발표면 실제 하늘에서 토성을 가리킬 수 있다.
- 낮이나 실내 발표면 '해질녘 재생'과 수동 모드(드래그)로 같은 장면을 보여 준다.
- 계산 코드: 스크래치 Java(`Astronomy.searchRiseSet`, `searchHourAngle`, `equator`→`horizon`, 굴절 Normal). 앱의 상세 시트 '뜸·남중·짐'도 같은 엔진을 쓴다.

## D-1 준비 (체크리스트)

- [ ] `curl -s https://<CloudFront 도메인>/api/health` → `{"status":"UP"}` (docs/AWS.md W3 ①)
- [ ] 관리자 화면에서 '발행 중인 팩'의 발표 시각이 6시간 이내인지 확인(CloudWatch `PackAgeMinutes` < 360)
- [ ] SSM 터널을 한 번 열어 본다: `aws ssm start-session --target <instance> --document-name AWS-StartPortForwardingSession --parameters portNumber=8080,localPortNumber=18080` → `http://localhost:18080/admin`
- [ ] 실기기(iPhone 14 Pro)에 Release 빌드 설치. `STARINDEX_PACK_BASE_URL`이 CloudFront 도메인인지 확인
- [ ] GitHub Actions의 최근 `backend` 실행이 deploy 잡까지 초록색인지 확인
- [ ] 배포 동결(10/17 12:00 또는 D-2 12:00) 뒤 24시간 무인 수집·발행 성공(관리자 실행 이력 8회, PLAN W3 ④)
- [ ] 실제 날씨가 시연에 맞지 않을 때 쓸 **저장 예보 팩** 버전을 정해 둔다(`scripts/etl.sh pin <version>`; 앱에는 '저장된 예보 · MM/DD HH시 발표'로 표시된다)

## 시나리오 (약 7분)

| # | 화면 | 말할 것 | 실패 시 |
|---|---|---|---|
| 1 | 앱 실행 → 첫 화면이 바로 하늘 | 번들 카탈로그(BSC5P)와 마지막 위치로 즉시 그린다. 위치는 기기 밖으로 나가지 않는다(D4) | 위치 거부 상태면 '서울(기본 위치)' 칩이 보인다. 그대로 진행 |
| 2 | 폰을 돌린다 | CoreMotion 진북 프레임 60Hz, 방위 배지(진북 기준) | 실내 자기 교란이면 배지가 노랑·빨강 → '수동' 버튼으로 드래그 |
| 3 | '해질녘 재생'(약 20초) | 일몰 17:48 → 시민·항해박명 → 천문박명 끝 19:16. 밝은 별부터 나타난다(m_tw) | 프레임이 끊기면 재생 대신 '지금' 버튼으로 실시간 하늘 |
| 4 | 상단 지수 칩 '오늘 밤 NN · 17시 발표' | ETL(기상청 단기예보 → 지수) → S3 팩 → CloudFront → 앱. 앱은 manifest만 2분마다 확인한다 | 칩이 '저장된 예보'면 그대로 설명. '지수 서버 미설정'이면 Release 빌드 설정 누락 |
| 5 | 칩을 눌러 시트 | 최적 2시간 창, 이유(구름·달), 천문박명 시각(천문연 또는 계산), 출처 | — |
| 6 | 토성을 탭 | 상세: 고도·방위·등급과 '뜸 17:11 · 남중 23:17 · 짐' | 화면에 없으면 수동 모드로 동남동(105°)을 향한다 |
| 7 | 노트북: SSM 터널 → `/admin` | JWT 로그인, 실행 이력(QueryDSL 필터: Job·상태·날짜), 실행 상세의 단계별 요약, '지금 실행'(202, 실행 중이면 409) | 터널이 안 열리면 실행 이력 스크린샷 |
| 8 | GitHub Actions → CodeDeploy | main 푸시 → 테스트 → S3 `deploy/backend/<sha>.zip` → CodeDeploy(검증 훅: 8081 actuator + 8080 `/api/health`) | 최근 성공한 실행 화면 |
| 9 | 아키텍처 한 장 | GitHub Actions → S3 → CodeDeploy → EC2(Spring Boot, Valkey(Redis), JWT, WebSocket, QueryDSL) / DB: Neon PostgreSQL 18(RDS 대신, ADR-016) / CloudFront + S3 팩 / Bootstrap 관리자 | — |
| 10 | 로드맵 | 결정 홈, 적중률, 명소, AR 스파이크 10/26 | — |

## 질문 대비

- **왜 RDS가 아닌가**: 무과금 원칙(ADR-016). 운영·시연 모두 Neon Free PostgreSQL 18이다. `DB_URL`만 바꾸면 RDS for PostgreSQL 18로 옮길 수 있게 마이그레이션은 슈퍼유저 아닌 소유자로 실행하고 테스트로 보장한다.
- **앱이 서버 DB를 직접 읽는가**: 아니다. 앱은 CloudFront의 정적 팩만 받는다. EC2·DB가 멈춰도 마지막 팩으로 동작한다(D8).
- **관리자 화면은 어떻게 보호되나**: CloudFront 경유 요청은 `/api/health`·`/api/v1/**`·`/ws/v1/**`만 통과한다(X-Origin-Verify). 관리자 경로는 SSM 터널(루프백)에서만 열리고, API는 JWT가 필요하다.
