# ADR-017: AWS를 쓰지 않는다 — GitHub Actions 예약 ETL + Neon(DB·Object Storage), 무과금

- 상태: 채택 (2026-10-01, 사용자 결정)
- 대체: PLAN 3.5(CloudFront, CI/CD의 CodeDeploy, IAM, CloudWatch 알람), 3.6의 AWS 비용, W3의 "AWS 일괄"과 완료 기준 ①②⑤, 8장의 AWS 사용자 조치, ADR-015 결정 4·7(EC2·S3 백업), DB-PLAN 11.3~11.6의 EC2 절차, D8·D10·D11·D12의 AWS 부분
- 유지: Neon Free PostgreSQL 18(ADR-015·016), 보관 2일(ADR-014), 팩 스키마·경로(PLAN 3.4), 앱 D4(위치는 기기 밖으로 나가지 않음)

## 배경

- 10/1 사용자 지시
  - "AWS는 작업하지 않는다." 범위를 물었더니 **프로젝트에서 AWS를 제거**하는 쪽을 골랐다. 이미 커밋한 AWS 코드도 걷어 낸다.
  - "밤하늘 별 보는 작업을 모바일에서 진행 가능하도록 하며 무과금으로 충분히 수행할 수 있도록 해야 한다."
- 별 보기(스카이뷰, 해질녘 재생, 천체 상세와 뜸·남중·짐)는 처음부터 기기 안에서만 계산한다. 서버가 필요한 것은 '오늘 밤 지수' 칩 하나다.
- 지수 ETL을 어디서 돌릴지 세 안(GitHub Actions 예약 실행 / Mac / 지수 칩 제외)을 비교했고, 사용자는 **GitHub Actions 예약 실행**을 골랐다.

## 결정

1. AWS 계정의 자원(EC2, S3, CloudFront, CodeDeploy, IAM, CloudWatch, SSM, Budgets)을 만들지 않는다. 관련 코드·스크립트·워크플로를 저장소에서 지웠다(커밋 445a063).
2. ETL은 `.github/workflows/etl.yml`이 GitHub 호스트 러너에서 돌린다.
   - 단기예보 발표 +20분(02·05·…·23시 KST): `forecastPipelineJob`
   - 매일 00:40 KST: `astroDailyJob`(보존 정리 + 천문연 출몰), `astroEventsJob`(천문현상), `pg_dump` 백업(아티팩트 7일)
   - 실행마다 백엔드 jar를 배치 모드로 한 번 띄운다. jar는 백엔드가 바뀔 때만 다시 빌드한다(캐시).
3. DB는 Neon Free PostgreSQL 18(`star_index`, 싱가포르)이다.
4. 앱 팩은 **Neon Object Storage `public_read` 버킷**에 둔다(같은 Neon 프로젝트·브랜치).
   - 서버는 S3 호환 API로 쓴다. 쓰기는 path-style이고, 체크섬은 필요할 때만 붙인다.
   - 앱은 익명 HTTPS로 `packs/manifest/latest.json`과 팩을 받는다.
   - 경로·Cache-Control·sha256 규칙은 PLAN 3.4 그대로다.
5. 상시 서버가 없다. Spring Boot 웹 서버는 운영자의 Mac에서만 띄우는 관리 도구다. 루프백 요청만 받고(`LocalOnlyFilter`), 관리자 화면은 `http://localhost:8080/admin`이다.
6. 공개 WebSocket 실시간 알림은 없다. 앱은 manifest를 활성화 시와 120초마다 확인한다(T19 5분 안). `/ws/v1/live`와 Redis Pub/Sub 코드는 로컬 서버용으로 남긴다.
7. 비밀은 GitHub Actions secrets에 둔다: `DB_URL`, `DB_PASSWORD`, `DATA_GO_KR_SERVICE_KEY`, `NEON_STORAGE_KEY_ID`, `NEON_STORAGE_SECRET`, `BACKUP_KEY`(10-01 추가). 버킷 이름·엔드포인트·공개 URL은 variables에 둔다.
   - S3 SDK의 변수 이름(`AWS_ACCESS_KEY_ID` 등)을 쓰지만 값은 Neon storage credential이다. AWS 계정은 관여하지 않는다.

## 비용 (모두 0원, 한도를 넘어도 과금되지 않는 조건)

| 자원 | 무료 한도 [확실, 공식 문서 2026-10-01] | 예상 사용 [추정] | 넘으면 |
|---|---|---|---|
| GitHub Actions(**공개 저장소**, 10-01 전환) | 표준 러너 무료, 분 한도 없음 | ETL 약 900분 + CI. Job마다 분 단위로 올려 센다: 예보 실행 약 3분 × 하루 8번, 매일 실행 약 5분(10-01 실측). 막힌 시도는 1분씩 더 든다 | 해당 없음. 비공개였다면 월 2,000분 한도 안이다 |
| GitHub 아티팩트·캐시 저장 | 아티팩트 500MB, 캐시 저장소당 10GB | 덤프 수 MB × 7일, jar 캐시 약 90MB | 결제 수단이 없으면 막힌다(과금 없음) |
| Neon PostgreSQL | 월 100 CU-시간, 0.5GB | 실행당 약 6분 깨어 있음 → 월 약 7 CU-시간 | 다음 달까지 컴퓨트 정지(앱은 마지막 팩으로 동작) |
| Neon Object Storage | 5GB, 전송은 **프로젝트 단위로 DB·Object Storage가 함께** 월 5GB [확실] | 팩 1.5KB, manifest 0.4KB, 앱이 2분마다 조건부 GET(대개 304) | **그달 말까지 DB 컴퓨트 정지**(Neon plans FAQ) → 아래 위험 표 |

- 출처: GitHub Actions 과금(docs.github.com/en/billing/concepts/product-billing/github-actions), schedule 이벤트(docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows), Neon 플랜(neon.com/docs/introduction/plans), Object Storage(neon.com/docs/storage/overview, buckets, s3-compatibility, authentication)

## 결과

- 좋아지는 점: 고정 비용 0원, 상시 서버 운영 없음, 앱은 DB·서버가 멈춰도 마지막 팩과 기기 계산으로 동작한다.
- 잃는 것과 위험

| 항목 | 내용 | 대응 |
|---|---|---|
| 과제 고정 스택 | GitHub Actions → S3 → CodeDeploy → EC2, RDS, Redis, WebSocket이 운영 경로에서 빠진다. GitHub Actions, Spring Boot(배치), Redis 호환(Valkey), JWT·QueryDSL·Bootstrap(로컬 관리자), WebSocket(로컬)은 남는다 | 평가 기준이 AWS 배포를 요구하면 감점될 수 있다 [불확실]. 발표에서 무과금 원칙과 대체 구성을 설명한다 |
| 예약 실행 지연 | GitHub는 부하가 클 때 schedule을 늦출 수 있다(정각이 가장 심함). 그래서 :20에 돌린다 | 공개 팩 검사가 6시간(발표 2번)을 넘으면 실패하고, 실패하면 GitHub가 메일을 보낸다 |
| **data.go.kr의 해외 IP 차단(10-01 실측)** | GitHub 러너는 해외에 있다. 10-01 16:3x~16:4x에 러너 2대는 `apis.data.go.kr` 연결이 5초 제한 시간을 넘겨 모두 실패했다. 같은 시각 다른 러너와 이 Mac(국내 IP)은 정상이었다. 같은 증상의 사례가 여럿 보고돼 있다 [가능성 높음] | 막힌 러너면 **새 러너로 최대 3번** 다시 시도한다(`etl-attempt.yml`). 막힘은 두 곳에서 잡는다: 빌드 전 접속 확인(몇 초)과, 확인을 통과했는데 수집 처음 2개 격자가 모두 통신 오류인 경우(jar 종료 코드 75). 3번 다 막히면 마지막 시도가 보존 정리(`retentionJob`, Neon만 씀)를 하고 실패로 끝나 메일이 간다. 앱은 마지막 팩을 쓴다. 계속 막히면 국내 실행 환경(이 Mac의 self-hosted runner 등)이 대안이다(미적용) |
| 저장소 공개(10-01 사용자 결정) | 비공개 저장소에서 예약 실행이 한 번도 일어나지 않았다(W3 현황). 공개 저장소는 Actions 분이 무료다. 대신 코드, 실행 로그, 아티팩트를 누구나 볼 수 있다. 60일 동안 커밋이 없으면 예약 실행이 꺼진다 | 공개 전 점검: gitleaks로 이력 45커밋 비밀 0건, 작성자 이메일은 이미 공개 프로필에 있음. 노출 가능성이 있던 DB 비밀번호와 스토리지 키를 교체했다. 백업 아티팩트는 암호화한다(`BACKUP_KEY`). 60일 비활성은 7일 전 메일이 오면 커밋으로 막고, 이미 꺼졌으면 `gh workflow enable etl` |
| Neon Object Storage | 공개 URL에 CDN이 없다(싱가포르에서 직접 받음). 수명주기 규칙은 저장만 되고 적용되지 않는다 | 팩이 작아 지연이 문제되지 않는다(추정). 오래된 팩은 보존 정리 Job이 직접 지운다 |
| 백업 | S3 대신 GitHub 아티팩트(7일). 공개 저장소라 암호화한다(AES-256, 키 `BACKUP_KEY`) | 복원은 `ops/neon/restore.sh`로 새 DB에 한다(`.enc`를 풀어서). ETL이 실패한 날에도 백업은 돈다. 키는 `ops/neon/app.env`와 사용자의 암호 관리자에 둔다 |
| 전송 한도 공유 | 누군가 공개 팩 URL을 수백만 번 받으면 5GB가 소진되어 DB가 그달 말까지 멈춘다(앱은 마지막 팩으로 동작) | 정상 사용량은 매우 작다(추정). 대안: 버킷을 **별도 Neon Free 프로젝트**로 옮겨 DB와 한도를 분리한다(0원, 미적용, 사용자 결정) |

- 검증(10-01): 백엔드 테스트, Neon 운영 스크립트 대역(`scripts/neon-ops-check.sh`), 로컬 끝단(`scripts/etl-local-e2e.sh`: 가짜 data.go.kr → 워크플로와 같은 jar 실행 → S3 호환 버킷 → 익명 읽기 검사 → 시뮬레이터 칩 표시, data.go.kr에 닿지 못하면 종료 코드 75). 수치와 실제 운영 검증은 `docs/verification/W3-status.md`에 있다.
- 실제 Neon 버킷·자격 증명·시크릿은 사용자 승인(10-01) 뒤 설정했고, 실제 데이터로 발행 중이다(`docs/ETL.md` 무과금 운영).
