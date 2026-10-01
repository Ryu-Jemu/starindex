# StarIndex: 오늘 밤 별 지수

공공 데이터 ETL로 **"오늘 밤 별이 잘 보이는가"**를 지수로 계산하는 iOS 앱입니다. 폰을 드는 방향을 따라 하늘을 보여 주는 스카이뷰, 노을과 해질녘 하늘색 변화, Unity AR 모드를 제공합니다.

- **데이터(ETL)**: 기상청 단기예보(SKY/PTY), 한국천문연구원 출몰시각·천문현상, EOG VIIRS 야간광
- **iOS**: SwiftUI, CoreMotion 방향 추적, Astronomy Engine(C), SwiftUI Canvas와 Metal 셰이더
- **AR**: Unity 6.3 LTS(AR Foundation과 ARKit, Unity as a Library)
- **백엔드**: Spring Boot 4.1, Spring Batch, QueryDSL, WebSocket, JWT, Redis 호환(Valkey)
- **인프라**: GitHub Actions → S3 → CodeDeploy → EC2, PostgreSQL 18(EC2 직접 설치, M0 시연은 RDS 가능, ADR-014), S3, CloudFront

## 저장소 구조

| 경로 | 내용 |
|---|---|
| `ios/` | iOS 앱과 Swift 패키지(SkyCore, SkySensors, StarIndexKit) |
| `unity/StarAR/` | Unity AR 모드(UaaL) |
| `backend/` | Spring Boot API와 ETL, `tools/catalog-builder` |
| `contracts/` | OpenAPI, JSON Schema, 골든 테스트 벡터 |
| `data/` | 카탈로그 원본, 한글 별자리명, 편각표, 지역·명소 |
| `legal/` | 개인정보처리방침, 지원, 라이선스 페이지 |
| `deploy/` | CodeDeploy appspec과 배포 스크립트 |
| `docs/` | 계획서(`PLAN.md`), ADR, 검증 기록, 비용 기록 |

## 진행 상황

작업 계획과 검증 게이트는 [`docs/PLAN.md`](docs/PLAN.md)에 있습니다.

- [x] Step 0: 저장소 생성, GitHub 연동
- [x] M0-W1(자동화 가능 범위): SkyCore 좌표·하늘색 계산, 카탈로그 빌더(skypack v1), G1a 통과, CI. 사용자 조치 대기 항목은 [`docs/verification/W1-status.md`](docs/verification/W1-status.md)에 있다.

### 로컬 테스트
```bash
./scripts/test-skycore.sh                                   # SkyCore(Swift) — G1a
(cd backend && ./gradlew :tools:catalog-builder:test)       # 카탈로그 QA — T9
```
- [ ] M0-W2: 스카이뷰 MVP, 해질녘 재생, 로컬 ETL
- [ ] M0-W3: 지수 발행, AWS 배포, 관리자 화면, 24시간 무인 운영

## 데이터 출처

- 기상청 단기예보: 공공누리 제1유형(출처 표시)
- 한국천문연구원 출몰시각·천문현상: 이용허락범위 제한 없음
- EOG VIIRS Nighttime Lights: CC BY 4.0
- Yale Bright Star Catalog(BSC5P, NASA HEASARC): 미국 정부 저작물
- IAU 별자리(CC BY 4.0, Sky & Telescope 협업), IAU-CSN 별 이름(CC BY)
- d3-celestial 별자리 선(BSD-3-Clause)
- Astronomy Engine(MIT, © Don Cross)
