# StarIndex: 오늘 밤 별 지수

공공 데이터 ETL로 **"오늘 밤 별이 잘 보이는가"**를 지수로 계산하는 iOS 앱입니다. 폰을 드는 방향을 따라 하늘을 보여 주는 스카이뷰, 노을과 해질녘 하늘색 변화, Unity AR 모드를 제공합니다.

- **데이터(ETL)**: 기상청 단기예보(SKY/PTY), 한국천문연구원 출몰시각·천문현상, EOG VIIRS 야간광
- **iOS**: SwiftUI, CoreMotion 방향 추적, Astronomy Engine(C), SwiftUI Canvas와 Metal 셰이더
- **AR**: Unity 6.3 LTS(AR Foundation과 ARKit, Unity as a Library)
- **백엔드**: Spring Boot 4.1, Spring Batch, QueryDSL, WebSocket, JWT, Redis 호환(Valkey)
- **운영(무과금, ADR-017)**: GitHub Actions 예약 실행 ETL → Neon Free PostgreSQL 18 → Neon Object Storage 공개 버킷 → 앱. AWS·RDS 없음(ADR-016·017). 별 보기는 서버 없이 기기에서 계산

## 저장소 구조

| 경로 | 내용 |
|---|---|
| `ios/` | iOS 앱과 Swift 패키지(SkyCore, SkySensors) |
| `unity/StarAR/` | Unity AR 모드(UaaL), R0 스파이크부터(아직 없음) |
| `backend/` | Spring Boot API와 ETL, `tools/catalog-builder` |
| `contracts/` | 앱·서버 계약 파일(`golden/`: 지수 팩·manifest, 백엔드와 iOS 테스트가 같은 파일을 검사) |
| `data/` | 카탈로그 원본, 한글 별자리명, 편각표, 지역·명소 |
| `legal/` | 개인정보처리방침, 지원, 라이선스 페이지, R4(아직 없음) |
| `ops/neon/` | Neon 운영 스크립트(최초 설정 `bootstrap.sh`, 복원 `restore.sh`, 팩 고정 `pin.sh`)와 검증 하네스 |
| `.github/workflows/` | `backend.yml`(테스트), `etl.yml`(3시간마다 ETL, 매일 천문 자료·백업) |
| `docs/` | 계획서(`PLAN.md`), ADR, 검증 기록, 비용 기록 |

## 진행 상황

작업 계획과 검증 게이트는 [`docs/PLAN.md`](docs/PLAN.md)에 있습니다.

- [x] Step 0: 저장소 생성, GitHub 연동
- [x] M0-W1: SkyCore 좌표·하늘색 계산, 카탈로그 빌더(skypack v1), G1a, CI ([W1-status](docs/verification/W1-status.md))
- [x] M0-W2: 스카이뷰 MVP, 해질녘 재생, 실기기 G3·T-P1·T-P5·G5(CPU), 백엔드 골격, ETL Job 6종 ([W2-status](docs/verification/W2-status.md))
- [x] M0-W3 코드: 앱 팩 클라이언트·지수 칩·지수 시트, 천체 상세 뜸·남중·짐, 관리자(JWT, 실행 이력 QueryDSL, 로컬), 예약 ETL 워크플로, Neon 운영 스크립트 ([W3-status](docs/verification/W3-status.md))
- [ ] M0-W3 운영: data.go.kr 인증키, Neon 버킷·자격 증명·GitHub 시크릿([ETL.md 8절](docs/ETL.md)), 24시간 무인 운영, 리허설([demo-script](docs/demo-script.md))

### 로컬 실행과 테스트
```bash
./scripts/test-skycore.sh                                   # SkyCore(Swift): 좌표·하늘색·팩 디코더
(cd backend && ./gradlew test)                              # 백엔드(Testcontainers PostgreSQL 18·Valkey·MinIO) + 카탈로그 QA
scripts/etl-local-e2e.sh                                    # 무과금 운영 경로를 로컬에서 끝까지(가짜 API → jar → S3 호환 버킷 → 익명 읽기)
scripts/neon-ops-check.sh                                   # ops/neon 스크립트를 Neon 대역(TLS 전용, 비슈퍼유저 관리자)에서 검증
scripts/etl.sh check                                        # data.go.kr 키 확인(backend/.env의 DATA_GO_KR_SERVICE_KEY)
scripts/serve-packs.sh --golden                             # 시뮬레이터용 로컬 팩 서버(127.0.0.1:8090)
```
- 관리자 화면(로컬): 백엔드를 띄운 뒤 `http://localhost:8080/admin`. 비밀번호 해시는 `backend/.env`의 `ADMIN_PASSWORD_HASH`(`htpasswd -nbBC 12 "" '<비밀번호>' | tr -d ':\n'`).
- 운영: `docs/ETL.md` 8절(Neon 버킷·자격 증명, GitHub 시크릿·변수, 첫 실행). 서버는 Mac 로컬 관리 도구라 루프백 요청만 받는다.

## 데이터 출처

- 기상청 단기예보: 공공누리 제1유형(출처 표시)
- 한국천문연구원 출몰시각·천문현상: 이용허락범위 제한 없음
- EOG VIIRS Nighttime Lights: CC BY 4.0
- Yale Bright Star Catalog(BSC5P, NASA HEASARC): 미국 정부 저작물
- IAU 별자리(CC BY 4.0, Sky & Telescope 협업), IAU-CSN 별 이름(CC BY)
- d3-celestial 별자리 선(BSD-3-Clause)
- Astronomy Engine(MIT, © Don Cross)
