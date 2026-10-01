# 오늘 밤 별 지수: 스카이뷰 + 하늘색 변화 + Unity AR, 최소 비용 작업 계획 (rev4, 2026-09-29)

> **2026-10-01 변경 3 (ADR-018):** 데이터 수명 주기를 정했다. 수집 데이터는 12시간(예보는 예보 시각 기준), 이력은 2일이고, 매 수집 끝에 정리한다. 밤 날짜 경계는 06시다.

> **2026-10-01 변경 2 (ADR-017, 사용자 결정): AWS를 쓰지 않는다. 전부 무과금이다.** 별 보기(스카이뷰·해질녘 재생·천체 상세)는 기기 안에서만 계산한다. '오늘 밤 지수' ETL은 **GitHub Actions 예약 실행**(`.github/workflows/etl.yml`)이 Neon Free PostgreSQL에 수집하고, 팩은 **Neon Object Storage 공개 버킷**에 올린다. 앱은 HTTPS로 manifest를 2분마다 확인한다. 상시 서버는 없고, 관리자 화면은 Mac 로컬(`http://localhost:8080/admin`)에서 연다. 그래서 아래의 CloudFront·EC2·CodeDeploy·IAM·CloudWatch·SSM·Budgets 내용(D8·D10·D11·D12의 AWS 부분, 3.5, 3.6의 AWS 행, W3 "AWS 일괄", 8장 2번)은 기록으로만 남긴다. 운영 절차는 `docs/ETL.md` 8절이다.

> **2026-09-30·10-01 변경:** DB는 PostgreSQL 18이다(ADR-013). 운영 DB는 **Neon Free**(관리형 PostgreSQL 18, AWS ap-southeast-1 싱가포르, TLS, direct 엔드포인트)다(ADR-015, `docs/DB-PLAN.md` 11). ADR-014의 "앱 EC2에 직접 설치"를 대체하고, ADR-014의 보관 결정은 그대로 둔다. EC2에는 JVM과 Valkey만 돈다. **RDS는 시연에도 쓰지 않는다(ADR-016, 10-01 사용자 결정: DB는 Neon 무과금).** 다른 PostgreSQL 18로 옮길 일이 생기면 `DB_URL`만 바꾼다. 보관은 기본 2일이고 예외는 `docs/DB-PLAN.md` 2장을 따른다. ETL 사용법은 `docs/ETL.md`.


## Context
- **주제**: 「오늘 밤 별 지수」 ETL 미니 프로젝트를 iOS 앱으로 만들어 App Store에 출시한다.
  - 데이터 소스: 기상청 단기예보, 천문연 출몰시각·천문현상, EOG VIIRS
- **사용자 요구**
  - ① 내 위치 기준 방향 추적 스카이뷰와 별자리·행성 표시
  - ② Unity AR을 v1.0에 포함
  - ③ 발표 MVP 먼저, 1인
  - ④ **시간에 따라 노을·해질녘 하늘색이 변하며 진행**
  - ⑤ **이미 가진 것(Apple Developer, iOS 26 이상 iPhone, AWS 계정)을 빼고 추가 비용 최소**
  - ⑥ 고정 스택: GitHub Actions → S3 → CodeDeploy → EC2(Spring Boot, Redis, JWT, WebSocket, QueryDSL), RDS MySQL, Bootstrap (과제 원문. DB는 PostgreSQL 18로 바꿨고 운영·시연 모두 Neon Free, RDS 없음: ADR-013, ADR-015, ADR-016)
- **저장소**: 이 저장소(`personal_project/`)
- **검증 이력**
  - 조사 2회(7트랙과 비평가)
  - 설계(Plan 3안 → 심사 2 → 통합 → 적대 검증)
  - rev2 적대 검증 4렌즈: 수학·셰이더, 비용·인프라, 의도·일정, 사실 32건. [확실] 주장 31건이 맞았고 1건을 고쳤다.
  - rev3는 이때 나온 high 4건, medium 약 20건, low 전부를 반영했다.
  - rev3 회귀 점검(2렌즈): 새 high는 없었다. medium 8건과 low 약 15건을 rev4에 반영했다. 내용은 m_tw 유한 앵커, 알파 식, 밤 휘도 상한, M0 인일 표, 허용 목록 필터, 수집 감시, 테스트·게이트 연결이다.
- **표기 규칙**
  - [확실] / [가능성 높음]: 조사 확신도
  - (추정): 규모나 수치를 어림한 값
  - (가정): 실측으로 보정할 값
  - G#: 검증 게이트
  - T#: 테스트

### 사용자 결정 (2026-09-29)
| 항목 | 결정 | 반영 |
|---|---|---|
| Unity AR | v1.0에 포함 | Unity 6.3 LTS UaaL 전체 화면 'AR 모드'. Go/No-Go 게이트에 실패하면 **사용자가 다시 결정**한다(5장) |
| 일정 | 발표 MVP 먼저 | M0(약 3주) → 출시 트랙 R1~R5 |
| 팀 | 1인 | 순차 진행. 다운로드처럼 기다리는 작업만 병행한다 |
| 보유 | iOS 26 이상 iPhone, Apple Developer, **AWS 계정**. Xcode 라이선스는 동의 예정(9/29 확인 시 exit 69) | 새로 만들 계정은 없다. **추가 비용만 최소화**한다(3.6) |
| 하늘색 | 노을·해질녘 진행 | 4.4: 팔레트와 셰이더 1개, 해질녘 재생, 박명에 따라 별이 나타남 |

**Unity v1.0 포함의 대가**
- 일정이 약 4~6주(추정) 늘어난다.
- 빌드가 두 갈래가 된다.
- 심사 대상이 늘어난다: UnityFramework privacy manifest, 4.2.1.
- Unload 뒤에도 메모리 80–180MB가 남는다 [확실].
- 환경 위험: Unity 6.0은 2026-10 지원 종료, iOS 모듈과 Rosetta 없음, Xcode 27 호환 미확인.

**불변식**: `AR_UNITY` 플래그를 끈 빌드도 항상 출시할 수 있어야 한다. Unity는 Personal이라 0원이다 [확실].

---

## 1. 목표와 성공 기준
| 요구 | 충족 기능 | 검증 |
|---|---|---|
| 별 지수 | 기상청 SKY/PTY + 천문연 박명 + VIIRS로 지역별 시간대 지수, 최적 2시간 창, 기여도, 명소 순위 | G6, T5, T13 |
| 방향 추적 스카이뷰 | 대략적 위치, 지평선 링과 8방위, 레티클 HUD, CoreMotion `.xTrueNorthZVertical` 60Hz, 프레임 폴백, 정확도 배지, 8자 보정, 원탭 보정(프레임별 누적) | G1, G2, G3 |
| 앱을 켜면 하늘 | 첫 탭이 '하늘'. 번들 카탈로그와 마지막 위치로 즉시 그림. 활성화될 때 위치가 30분 넘게 지났으면 다시 받음 | 콜드 스타트 ≤2 s(가정), G7 |
| 무엇이 어디 있는지 | BSC5P 별, 88개 별자리 선과 한글명, 해·달(위상)·행성, 은하 적도와 중심, 라벨 컬링, 탭 상세, 검색 안내(R1) | T8, T10 |
| **하늘색 진행** | 태양 기하 고도 팔레트 + 픽셀 셰이더(낮 → 골든아워 → 노을 → 블루아워 → 박명 → 밤), 태양 쪽 글로우, 실시간 진행, 재생, **해질녘 재생(약 20초)**, 박명에 따라 별이 나타남(m_tw), 흐림 탈채도 | T14~T18, G5 |
| Unity AR | 6.3 LTS + AR Foundation·ARKit XR 6.3(GravityAndHeading), UaaL, AR 연출 3종 | G-E, G-U, T-U1 |
| 최소 비용 | 로컬 우선 개발, CloudFront 기본 도메인, NAT·ALB·ElastiCache·도메인·RDS 미사용(DB는 Neon Free), Linux CI | **월별 `docs/cost-log.md` 실측 ≤ 3.6 추정의 120%**, Budgets |
| 출시 | 위치 거부·해외·실내·낮·EC2 정지에서도 동작, privacy manifest, 개인정보처리방침(앱 안과 메타데이터) | G7, G8 |

## 2. 핵심 설계 결정
| # | 결정 | 근거 |
|---|---|---|
| D1 | 기본 앱은 네이티브 SwiftUI, AR 모드만 Unity(UaaL) | UaaL은 전체 화면, 인스턴스 1개, Quit 후 재로드 불가 [확실] |
| D2 | `Canvas`+`TimelineView`로 시작하고 G5에 실패하면 `MTKView`. SceneKit과 ARSCNView는 쓰지 않는다 | iOS 26에서 deprecated [확실]. Canvas는 요소별 인터랙션이 없다 [확실] |
| D3 | `CMMotionManager` 싱글턴과 `.xTrueNorthZVertical`. `CLHeading`은 배지에만 쓴다 | NSMotionUsageDescription 대상 API 목록에 없다 [가능성 높음] |
| D4 | `NSLocationDefaultAccuracyReduced=YES`. **좌표와 격자는 서버로 보내지 않는다.** 지역 ID는 G9를 통과하고 사용자가 푸시에 opt-in한 경우의 관심 지역만 보낸다. 앱은 `/index`, `/spots/*`, `/events`를 호출하지 않는다 | 단말에서만 처리하면 위치기반서비스 신고 대상이 아니다 [확실]. 대략적 위치에서 진북 프레임이 동작하는지는 미확인 → W2 G3 스모크 |
| D5 | Astronomy Engine **v2.1.19(커밋 61dc070)**. iOS는 C 소스 벤더링, 서버는 JitPack jar를 `libs/`에 둔다(+kotlin-stdlib). Unity는 계산하지 않는다 | MIT, ±1′. 래퍼에 태그가 없고, 업스트림 master는 v2.1.19보다 28커밋 앞섬. Maven Central 미등록 [확실] |
| D6 | R은 `Rotation_EQJ_HOR`에 `RotateVector`로 기저벡터를 돌려 열로 구성한다. 굴절은 **모든 고도**에 적용한다. C 호출은 단일 `AstroEngine` actor로 모은다 | HOR 축 = CoreMotion 축 [확실]. `Constellation`의 static 초기화가 스레드 안전하지 않다 [확실]. 굴절은 −1° 아래에서도 연속 감쇠한다(AE 소스) [확실] |
| D7 | 카탈로그는 BSC5P, IAU-CSN, d3 lines, 한글 88개 표, Messier. HYG, Hipparcos·Gaia, Stellarium, Falchi는 뺀다 | NC·SA·GPL 조건 배제 [확실] |
| D8 | 앱 데이터는 모두 **S3 정적 팩**(지수와 72시간 SKY/PTY, 카탈로그, 이벤트, R3 명소)을 CloudFront로 받는다 | EC2가 꺼져도 앱이 동작하고, 오프라인과 D4를 지킨다 |
| D9 | **Spring Boot 4.1.x**(4.1.1, OSS 지원 2027-07-31까지), `spring-boot-starter-batch-jdbc`, `spring-boot-starter-flyway`+`flyway-database-postgresql`(ADR-013), QueryDSL은 OpenFeign `io.github.openfeign.querydsl` 7.x를 권장한다(7.7은 9/23에 나온 릴리스라 W2에서 7.6과 함께 호환 확인). 폴백은 Boot가 관리하는 `com.querydsl` 5.1.0이고, 이 경우 ScrollableResults 계열 API를 쓰지 않는다. **정렬·필터 키는 화이트리스트 enum으로만 받는다**(CVE-2024-49203). 결정은 ADR-004에 남긴다 | Boot 4에서 Batch가 분리됐다 [확실]. 3.5는 OSS가 끝났고(2026-06-30), 4.0.x는 2026-12-31에 끝난다 [확실] |
| D10 | WS는 raw JSON + Redis Pub/Sub. 앱은 공개 `/ws/v1/live`를 수신만 하고 30~60초 ping과 재연결을 한다 | CloudFront WS 지원 [확실] |
| D11 | 앱에는 사용자 로그인이 없다. JWT는 관리자에만 쓴다. **관리자 화면은 공개 경로에서 막고 SSM 포트 포워딩으로만 접속한다**(0원). 푸시는 G9 뒤 opt-in | CloudFront↔EC2 구간이 평문이라 관리자 자격증명이 노출될 수 있다 |
| D12 | 공개 진입점은 **CloudFront 기본 도메인 하나**. 도메인, 인증서, nginx TLS를 쓰지 않는다 | 기본 도메인은 HTTPS가 되어 ATS를 충족한다. 상시 무료 월 1TB·1천만 요청 [확실] |
| D13 | 하늘색은 **CPU 팔레트 + SwiftUI 픽셀 셰이더 1개**로 만든다 | Preetham과 Hosek은 태양이 지평선 위일 때만 유효하다 [확실]. Bruneton(BSD-3)은 4D LUT 사전계산과 텍스처 관리가 필요해 1인 MVP에 과하다. Stellarium·ShowMySky는 GPL [확실]. SwiftUI Shader는 iOS 17+ [확실] |
| D14 | Redis는 EC2에 **Valkey 8**(`dnf install valkey`, Redis 7.2 프로토콜 호환, BSD)로 설치한다. 로컬·CI도 `valkey/valkey:8`로 맞춘다. ADR-005에 "Redis(호환 구현 Valkey)"로 기록하고, 과제가 원본 Redis를 요구하면 Docker `redis:7.2`로 바꾼다 | AL2023 기본 저장소에는 redis6(EOL)이나 valkey만 있다 [가능성 높음] |

## 3. 아키텍처

### 3.1 저장소 (`personal_project/`, W1에서 `git init` → GitHub private)
```
ios/        StarIndex.xcworkspace, App/(Shaders/SkyColor.metal), Features/, Widget/, Packages/{SkyCore,SkySensors,StarIndexKit}, UnityExport/(gitignore)
unity/StarAR/   Unity 6.3 LTS(Assets, Packages, ProjectSettings), scripts/export_ios.sh
backend/    Gradle(Java 21, Boot 4.1.x), libs/astronomy-2.1.19.jar, tools/catalog-builder/, docker-compose.yml(PostgreSQL 18, valkey 8), src/main/resources/{static/admin, db/migration}
legal/      privacy.html, support.html, licenses.html → S3 legal/
contracts/  openapi.yaml, schemas/{manifest,index,spots,bridge-v1}.schema.json, fixtures/, golden/astro_vectors.json
data/       catalog-src/, names_ko.csv, declination.csv, regions.csv, spots.csv, meteor_showers.csv(10개, AR 연출용), viirs/
deploy/     appspec.yml, scripts/{stop,install,start,validate}.sh, systemd/starindex.service
docs/       adr/, ATTRIBUTION.md, review-notes.md, verification/, demo-script.md, cost-log.md
.github/workflows/  backend.yml(Linux 전용)
```

### 3.2 iOS (최소 iOS 26, iPhone 전용, 세로, 60Hz, Swift 6)
- **SkyCore** (macOS `swift test`)
  - C 타깃: `CAstronomy`
  - 계산 기반: `AstroEngine` actor, `SkyClock`
  - 좌표 변환: `HorizonTransform`, `Refraction`(순방향과 Inverse), `AzimuthCorrection`
  - 천체
    - `EphemerisService`
    - `RiseSetService`: 일몰·일출은 `Astronomy_SearchRiseSet`, −6/−12/−18°는 `Astronomy_SearchAltitude`, **하방 남중은 `Astronomy_SearchHourAngle(Sun, obs, 12.0, …)`**
    - `ConstellationLocator`
  - 카탈로그: `SkyPackDecoder`, `StarTable`
  - 투영·표시: `SkySnapshotBuilder`, `Projector`, `LabelLayout`, `HitTester`, `GuideHint`
  - 기타: `KMAGrid`, `DeclinationTable`, `GalacticGuide`
  - 하늘색·박명: `SkyPhase`, `TwilightMagnitude`(m_tw), `SkyPalette`, `SkyColorModel`(셰이더와 1:1 대응하는 CPU 참조 구현), `SunsetPlaybackPlanner`
- **SkySensors**
  - `AttitudeProvider`, `FrameKind`(cmTrueNorth / cmMagnetic / cmArbitrary / arkitGravityHeading / arkitGravityYaw)
  - 구현체: `CoreMotionAttitudeProvider`, `ManualAttitudeProvider`
  - 보조: `AttitudeFilter`, `HeadingQualityMonitor`, `CalibrationStore`(**FrameKind별 ψ**), `LocationProvider`, `AttitudeRecorder`
- **StarIndexKit**
  - 팩: `ManifestClient`, `PackStore`(압축 바이트 기준 sha256 검증, 원자적 교체)
  - 조회: `RegionLocator`, `HourlySkyLookup`
  - 통신·공유: `LiveSocket`, `TonightSnapshot`, `PushRegistrar`(G9)
- **App/Features**
  - 탭: `RootTabView` [하늘] [오늘 밤] [명소] [천문현상] [설정: 알림·데이터 삭제·**개인정보처리방침 링크(5.1.1(i))**·출처]
  - 하늘 화면: `SkyScreen`, `SkyCanvasView`(첫 레이어가 하늘 셰이더), `SkyHUD`, `IndexChip`, `Calibration*`, `ObjectDetailSheet`, `SkySearchSheet`(R1), `TargetGuideOverlay`(R1), `TimeTravelBar`(M0에서는 해질녘 재생 버튼과 '지금' 버튼만, 전체 UI는 R1), `VisibleObjectsList`
  - 위치 흐름: `OnboardingLocationView`, `RegionPickerView`
  - AR·디버그: `UnityHost`(`#if AR_UNITY`), `SkyProbeView`(디버그), `SkyContactSheetView`(디버그)
- **Widget**(R4): 18~06시 매시 엔트리, `.atEnd`. 자주 보는 위젯 기준 하루 40–70회 예산 [확실]
- **Info.plist**
  - 위치: `NSLocationWhenInUseUsageDescription`, `NSLocationDefaultAccuracyReduced=YES`
  - 모션: `NSMotionUsageDescription`(예비)
  - 카메라: `NSCameraUsageDescription`(AR에 들어갈 때 요청)
  - `ITSAppUsesNonExemptEncryption=NO`
  - ATS 예외 없음

### 3.3 Unity AR 모드 (`unity/StarAR`)
- **환경**: 6.3 LTS(2027-12까지 지원) + iOS 모듈, AR Foundation 6.3 + ARKit XR Plugin 6.3(Xcode 26.0 이상 [확실]). Player는 iOS 26, IL2CPP ARM64, stripping High.
- **세션**
  - `ARKitSessionSubsystem.requestedWorldAlignment = GravityAndHeading`: +Z가 진북 [확실]
  - 추적 모드는 G-U2 실측으로 정한다.
  - 천구 루트는 카메라 위치만 따라간다.
  - heading이 실패하면 `Gravity`와 네이티브 yaw로 바꾼다(FrameKind arkitGravityYaw).
- **좌표 매핑**
  - `M:(x_N,y_W,z_U)→(X_E,Y_U,Z_N)=(−y,z,x)`(det −1). 별 정점은 `100·M·s_i`
  - **`CelestialRoot.rotation = Quaternion.Euler(0,−ψ,0) * Quat(M·R·M⁻¹)`**(월드 기준 앞곱)
  - R은 row-major `m[9]`에서 `M4x4[r,c] = m[r*3+c]` 인덱서로 채운다. `new Matrix4x4(열벡터)`는 쓰지 않는다.
- **굴절**: AR에서는 **모든 천체에 굴절을 적용하지 않는다**(지평선 부근 0.48~0.65° 편차를 문서화).
- **하늘색**: 카메라가 실제 하늘을 보여 주므로 렌더링하지 않는다(v1.1에서 박명 칩 검토).
- **브리지 v1** (`{v:1,type,t,p}`)
  - 네이티브 → Unity
    - `init`
    - `rotation{m:[9]}`: 1Hz, **재생 중에는 매 프레임**
    - `bodies[{id, eqj:[3](관측자 중심 J2000 단위벡터), mag, illum, sunEqj:[3]}]`: 평소 0.2Hz, **재생 중에는 1Hz 이상이고 Unity가 두 샘플 사이를 보간**. CelestialRoot 아래에 배치
    - `target`, **`offset{frame, psiDeg}`**, `clock`
  - Unity → 네이티브: `ready`, `select`, `tracking`, `calibrated{frame, psiDeg}`, `close`, `stats`
  - 보정값 저장소는 네이티브 `CalibrationStore`이고 **키는 프레임별**이다. Unity 보정은 arkit* 키에만 저장한다.
  - ψ 수명
    - `arkitGravityYaw`의 ψ는 **AR 세션마다 초기화**하고 천체 정렬을 강제한다.
    - `arkitGravityHeading`의 ψ는 세션을 시작할 때 이전 값을 **제안값으로만** 적용하고, 첫 보정 전에는 배지를 노랑으로 둔다.
- **AR 연출 3종**(4.2.1)
  1. 행성 3D와 위상 조명
  2. 유성우 복사점: **번들 정적 표 `meteor_showers.csv`** 사용, R3 이벤트 팩과 무관
  3. 오늘 밤 최적 방향: **지수 팩 `best` 시간대에 가장 높이 뜨는 추천 천체의 방향.** VIIRS 방위 반영은 v1.1
- **빌드**: 로컬 batchmode export → `ios/UnityExport` → workspace embed. CI에서는 Unity를 빌드하지 않는다. `UnityHost`는 `quit()`를 호출하지 않는다.

### 3.4 백엔드 (단일 Gradle, 패키지 `etl.*`, `api`, `admin`, `ws`, `push`, `astro`)
| Job | 스케줄(KST, 가정) | 내용 | 단계 |
|---|---|---|---|
| `forecastIngestJob` | 발표 +15분 | 격자(M0 17개 시·도 → R3 시군구·명소) → 수집(`quota:kma`) → `kma_forecast_hour` upsert | M0 |
| `astroDailyJob` | 00:30 | 천문연 출몰·박명 → AE 계산 → 교차검증 | M0 |
| `starIndexPublishJob` | 체이닝 | 지수 → `qualityGateStep` → **지수 팩(어두운 창 지수 + 72시간 SKY/PTY)** 발행 → manifest 갱신 → WS 방송 → `PackAgeMinutes` 지표 | M0 |
| `spotsPublishStep` | 위 Job의 Step | 명소 목록·순위·기여도 팩 `packs/spots/v…` | R3 |
| `astroEventsJob` | 매월 | 천문현상 → 이벤트 팩 | R3 |
| `lightPollutionLoadJob` | 연 1회 | VIIRS 전처리 CSV(로컬 GDAL) → 광공해 등급(G12) | R3 |
| `skyCatalogBuildJob` | 수동 | catalog-builder를 Step으로 감쌈 | R3 |
| `pushDispatchJob` | 17:30, G9 통과 시 | 관심 지역 → APNs(ES256 JWT) | R4(조건부) |
| **적중률 스냅숏**(C9, `forecastIngestJob` 안) | R1 첫 주(11/2~11/6, 기한 11/28) | 17:00 발표와 전날 23:00 발표를 수집할 때 ASOS 관측소 격자 10곳의 21·22·23·00시 SKY/PTY를 `forecast_verification`에 바로 쓴다. ASOS 관측값은 R3 `forecastVerifyJob`이 채운다. `collect-only` 프로필과 S3 `raw/`는 폐기했다(ADR-014) | R1~ |

- **지수 v1**(가정, T13·G12로 재보정)
  - 인자: `f_cloud`(SKY 1/3/4 → 1.0/0.5/0.15), `f_precip`(PTY>0이면 0), `f_moon = 1−0.7k√max(0,sin h_moon)`, `f_light`(VIIRS, R3 전까지 1)
  - `S=100Πf`. 오늘 밤 지수는 2시간 평균의 최대값이다.
  - 기여도: 강수면 '관측 불가', 모든 f=1이면 0, 그 밖에는 `ln f_i/Σln f_j`
  - 밤 날짜 = 06:00 KST에 바뀐다(ADR-018. 그 전에는 12:00)
  - **계산 규칙(ADR-019, 결과를 정하는 세부)**
    - 시간 칸: 정각 h의 예보는 [h, h+1시간)을 대표한다. 어두운 시간은 이 칸 전체가 천문학적 밤 안에 드는 정각이다: 천문박명 끝 ≤ h 이고 h+1시간 ≤ 새벽 천문박명 시작(10-01 수정. 전에는 h ≤ 새벽 천문박명 시작이라 마지막 칸이 최대 59분 박명이었다).
    - 박명 시각: 지수는 Astronomy Engine 계산값을 초 단위 그대로 쓴다(태양 기하 고도 −18°, 관측 고도 0m). 저녁 사건은 밤 날짜 12:00 KST부터, 아침 사건은 천문박명 끝부터 찾는다. 천문연 값은 팩의 표시용이다.
    - 달: 그 1시간의 f_moon 평균이다. 10분 칸 6개의 가운데(:05, :15, …, :55)에서 Astronomy Engine 지형 기준 고도(대기굴절 Normal, 관측 고도 0m)와 밝은 면 비율 k를 각각 계산한다.
    - 창: 정확히 1시간 간격인 두 칸이다. 예보가 빈 시간은 창을 끊는다. 이런 쌍이 하나도 없으면 가장 좋은 한 칸을 쓴다. 같은 값이면 이른 창을 쓴다.
    - 반올림: 시간별 원점수의 창 평균을 한 번만 반올림한다(0.5는 올림). 시간별 정수는 표시용이다.
    - 기여도: 창 안에 PTY>0이 있으면 `{cloud 0, precip 1, moon 0, light 0}`(앱은 '관측 불가'로 표시). 그 밖에는 인자마다 창 평균 f_i를 구해 `ln f_i/Σln f_j`를 소수 셋째 자리로 반올림한다. 모든 f=1이면 모두 0이다.
    - 이유 코드: `PRECIP`(창 안 PTY>0), 창의 가장 나쁜 SKY에 따라 `CLOUD_CLEAR`/`CLOUD_MOSTLY`/`CLOUD_OVERCAST`, 창의 평균 f_moon에 따라 `MOON_NONE`(≥0.95)/`MOON_SOME`(≥0.7)/`MOON_BRIGHT`. 예보가 없으면 `NO_FORECAST`.
    - 등급: 80 이상 `EXCELLENT`, 60 이상 `GOOD`, 40 이상 `FAIR`, 그 밖 `POOR`(SERVICE-PLAN 4.5 판정 문구와 같은 경계)
- **팩 스키마**: 규범은 실제로 발행되는 **schema 2**이고, 기준 파일은 `contracts/golden/index-pack-v2.json`(백엔드 골든 테스트와 iOS 디코더 테스트가 같은 파일을 검사)이다. 지역마다 `id, name, kind, grid, score, grade, best:[HHmm,HHmm], reasons, contrib, twilight:{kasi:{sunset,civile,naute,aste}|null, computed:{sunset,civile,naute,aste,astm,sunrise}}, hourly:{t0, sky, pty, tmp, reh, wsd, pop}`(72칸, 1시간 간격)를 둔다. 시각은 KST HHmm이고 가장 가까운 분으로 반올림한다(ADR-019). 앱은 천문연 값을 "(천문연)"으로 보여 주고, 없으면 계산값을 "(계산)"으로 보여 준다. (이전 "팩 스키마 v1"의 지역 최상위 `kasi`와 `hourly:{t0, sky, pty}`는 schema 2로 대체됐다.)
- **REST 경로**(확정)
  - 헬스: `/api/health`(단순 UP, DB를 조회하지 않는다. `/actuator/health`는 db 지표가 Neon을 깨우므로 주기적으로 호출하지 않는다, ADR-015)
  - 공개 `/api/v1/**`
    - 웹 전용(**앱 호출 금지를 openapi에 명시**): `/api/v1/spots/ranking`, `/api/v1/spots/{id}`, `/api/v1/events`, `/api/v1/index`. QueryDSL을 쓰고, 정렬 키는 enum 화이트리스트
    - 기기(G9): `/api/v1/devices`
  - 관리자 **`/api/admin/**`**(`/api/v1` 밖, JWT)
    - 인증: `auth/login`, `ws-ticket`
    - ETL 운영: `etl/runs`, **`etl/jobs/{name}/run`(비동기 `202 {executionId}`, 실행 중이면 `409`)**, `quality`, `crosscheck`, `backtest`(`forecast_verification`의 binary-clear-v2 혼동행렬)
    - 팩: `packs/rollback`. 대상은 종류별 최신 3개와 pinned 팩뿐이다(보존 정리가 지우지 않는 팩, ADR-014). 고정은 로컬 `scripts/etl.sh pin|unpin <version>`, EC2 `/opt/starindex/postgres/pin.sh`
  - 관리자 화면: `/admin/**`, 관리자 WS: `/ws/admin`
  - manifest의 **단일 원천은 S3 `packs/manifest/latest.json`**이다. REST에는 manifest 엔드포인트를 두지 않는다. `data_pack`은 발행 이력, Redis `pack:manifest`는 관리자 표시용 캐시다.
  - **롤백 순서**: S3 latest.json 교체 → `/packs/manifest/*` 무효화 → `data_pack` 갱신 → Redis `pack:manifest` 갱신
- **보안 필터(8080, 허용 목록 방식)**
  - `X-Origin-Verify`가 붙어 있고 값이 맞으면 `/api/health`, `/api/v1/**`, `/ws/v1/**`**만** 허용한다. 나머지는 모두 403이다(관리자 경로 포함).
  - 헤더 값이 틀리면 403이다.
  - 헤더가 없으면 `InetAddress.isLoopbackAddress()`(127.0.0.1과 ::1, SSM 터널)일 때만 허용하고, 그 밖은 403이다.
  - actuator는 `management.server.port=8081`, `address=127.0.0.1`에 둔다. `validate.sh`는 `http://127.0.0.1:8081/actuator/health`를 60초 동안 재시도한다.
  - `server.tomcat.use-relative-redirects=true`로 두고, 서버는 절대 URL을 만들지 않는다.
- **WebSocket**
  - `/ws/v1/live`: 공개, CloudFront 경유
  - `/ws/admin?ticket=`: 터널 전용. `setAllowedOrigins("http://localhost:18080")`
  - Redis 채널: `ch:live`, `ch:admin`
- **Valkey**(`bind 127.0.0.1 -::1`, `protected-mode yes`, `maxmemory 128mb`, `volatile-lru`)
  - 지수·팩: `idx:tonight:*`(TTL 36h), `idx:rank:*`, `pack:manifest`
  - 수집·쿼터: `fcst:raw:*`(TTL 24h), `quota:{kma|kasi}:{date}`(70% 경고, 90% 정지)
  - 운영·인증: `lock:job:*`, `etl:progress:*`, `ws:ticket:*`(TTL 30s), `jwt:deny:*`, `auth:fail:{ip}`(5회 실패 시 15분 잠금)
  - 푸시: `push:sent:*`
- **PostgreSQL 18**(ADR-013/014, 실제 스키마와 보관은 `docs/DB-PLAN.md`. Flyway V1에 `BATCH_*` 포함. 운영 위치는 Neon Free, ADR-015)
  - 지역: `region`
  - 원천 데이터: `kma_forecast_hour`(격자·예보 시각마다 1행, SKY/PTY/TMP/REH/WSD/POP), `kasi_riseset`(저녁 시각만), `kasi_astro_event`, `kasi_special_day`, `kasi_lunar_day`
  - 지수: `star_index_nightly`(score, grade)
  - 검증: `astro_crosscheck`. R1에 `verify_station`, `forecast_verification` 추가(DB-PLAN 3.3)
  - 팩: `data_pack`(+ `pinned`)
  - 운영: `etl_api_call`, `BATCH_*`
  - 보관: 기본 2일. `etl_api_call`·`astro_crosscheck`·`data_pack`·`BATCH_*`는 8일, 천문 달력은 지난달 1일부터, `forecast_verification`은 32일
  - R3 이후 계획(미생성): `observing_spot`, `spot_rank_daily`, `constellation_name`, `etl_quality_metric`, `admin_user`, `device*`
- **S3 버킷 1개** `starindex-{acct}`(Block Public Access 4개 모두 켬)
  - `packs/manifest/latest.json`: 업로드 시 `Cache-Control: max-age=60, must-revalidate`
  - `packs/{index,catalog,events,spots}/v…/*`: `Cache-Control: public, max-age=31536000, immutable`. `.json.gz`는 `Content-Type: application/gzip`(Content-Encoding 없음)이고 sha256은 **압축된 바이트**로 계산한다.
  - `legal/*.html`
  - `backup/db/`: (ADR-017로 대체: 매일 00:40 KST `etl.yml`의 daily 실행이 `pg_dump`를 GitHub 아티팩트 `starindex-db-<날짜>`로 7일 보관하고, 복원은 `ops/neon/restore.sh`로 새 DB에 한 뒤 `DB_URL` 시크릿만 바꾼다. `docs/ETL.md` 7·8절) 매일 05:20 KST 전체 `pg_dump`(EC2의 PostgreSQL 18 클라이언트가 Neon에서 받는다), 수명주기 **7일**(ADR-014). Neon Free 이력은 6시간뿐이라 이것이 실제 백업이다(ADR-015)
    - 복원: 6시간 안이면 Neon 즉시 복원. 그 밖에는 `deploy/postgres/restore.sh`로 운영 DB 옆 **새 DB**에 복원하고, 필요하면 `--switch`로 바꾼다. 운영 DB는 지우지 않는다
  - `deploy/backend/{sha}.zip`: 수명주기 **90일**(롤백 리비전 보존)
  - 버킷 정책: Principal `cloudfront.amazonaws.com`, `AWS:SourceArn`=배포 ARN, Resource는 `packs/*`와 `legal/*`**만** 허용
  - EC2 인스턴스 역할(`deploy/aws/iam-instance-db.json`, ADR-014): `deploy/backend/*` 읽기, `backup/db/*`·`packs/*` Put/Get, `s3:DeleteObject`는 `packs/{index,events,spots}/*`만(manifest·legal·backup 제외), `s3:ListBucket`(Condition StringLike `s3:prefix`=`backup/db/*`, `packs/*`), `ssm:GetParameter(s)` `/starindex/*`, ssm 경유 `kms:Decrypt`. `raw/*` 권한은 없다
- **`skypack.bin`**
  - 헤더: `SKYP`, u16, u32
  - 레코드: f32×3, i16(등급×100), u8(B−V), u16(HR), i32(이름 인덱스)
  - 크기: ≤1MB(추정)

### 3.5 CloudFront, 웹, CI/CD, IAM, 모니터링 (폐지: ADR-017)

> **현재 구성(ADR-017):** 팩은 Neon Object Storage `public_read` 버킷(`<엔드포인트>/starindex-packs/packs/…`)에 있다. CI는 `backend.yml`(테스트만), ETL은 `etl.yml`(예약 실행)이다. 실패 알림은 GitHub 메일과 공개 팩 신선도 검사(`scripts/check-public-pack.py`, 6시간)가 맡는다. 관리자 웹(Bootstrap)은 Mac 로컬에서 루프백 요청만 받는다(`LocalOnlyFilter`). 아래는 AWS 설계 기록이다.
- **CloudFront 배포 1개**(PAYG, `*.cloudfront.net`, HTTPS only). 동작 순서는 다음과 같다.
  1. `/packs/manifest/*` → S3(OAC), 캐시 정책 Min 0, Default 60, Max 300초
  2. `/packs/*`, `/legal/*` → S3(OAC), CachingOptimized
  3. `/ws/*`, `/api/*` → EC2, CachingDisabled + AllViewerExceptHostHeader, 오리진 헤더 `X-Origin-Verify`
  4. 기본(`*`) → EC2, 같은 정책(관리자 경로는 필터가 403)
  - EC2 오리진은 기본 VPC(DNS hostnames 켜짐)에서 `ec2-<EIP>.ap-northeast-2.compute.amazonaws.com:8080`이고 HTTP only다. SG 인바운드는 8080 포트에 CloudFront prefix list 규칙 1개뿐이다(가중치 55).
  - 롤백하면 S3 latest.json을 교체하고 `/packs/manifest/*`를 무효화한다(월 1,000경로 무료).
- **관리자 웹**(Bootstrap, Spring static): 로컬에서 `aws ssm start-session --document-name AWS-StartPortForwardingSession --parameters portNumber=8080,localPortNumber=18080`을 실행한 뒤 `http://localhost:18080/admin`으로 접속한다. 화면 구성은 실행 이력(QueryDSL), 진행률(WS), 품질, 쿼터, 교차검증·백테스트 차트, 팩 롤백, 명소 CRUD다.
- **공개 페이지**: S3 `legal/*.html`(EC2가 꺼져도 열림, 0원)
- **CI/CD**
  - `backend.yml`(Linux): PR마다 `./gradlew test`(Testcontainers PostgreSQL 18(로케일 C)·valkey 8, WireMock, ADR-013). main 머지 시 zip을 S3 `deploy/`에 올리고 OIDC로 CodeDeploy를 실행하며, `validate.sh`로 확인한다.
  - iOS는 로컬 `swift test`와 pre-push 훅으로 돌린다(macOS 러너는 분을 약 10배로 소진하므로 쓰지 않는다).
- **IAM과 에이전트**
  - CodeDeploy 에이전트는 SSM Distributor `AWSCodeDeployAgentV2`(AL2023 aarch64)로 설치한다.
  - 인스턴스 프로파일: `AmazonSSMManagedInstanceCore`, S3(3.4에 적은 범위, `backup/db/*`·`packs/*` ListBucket 포함, raw 없음, ADR-014), `ssm:GetParameter(s)` `/starindex/*`(DB 비밀번호 SecureString `/starindex/db/password`, ssm 경유 `kms:Decrypt`), `cloudfront:CreateInvalidation`(해당 배포), `cloudwatch:PutMetricData`
  - CodeDeploy 서비스 역할: `AWSCodeDeployRole`
  - OIDC 역할 신뢰 조건: `aud=sts.amazonaws.com`, `sub=repo:<owner>/<repo>:ref:refs/heads/main`. 권한은 S3 `deploy/backend/*` PutObject와 codedeploy Create/Get/Register. `id-token: write`는 deploy 잡에만 준다.
- **모니터링**(알람 3개, 무료 한도 안)
  1. 서울: EC2 StatusCheckFailed
  2. 서울: 데이터 신선도. 모든 단계에서 같은 지표를 쓴다.
     - `StarIndex/PackAgeMinutes`가 360분을 넘거나 데이터가 없을 때
     - R1~R2에도 EC2가 24/7로 돌고 DB(Neon)는 Job 때만 깨어나 발행이 이어진다(ADR-015). `collect-only`와 `RawCollectedAgeMinutes`는 폐기했다(ADR-014)
  3. **us-east-1**: CloudFront 5xxErrorRate. SNS 토픽도 us-east-1에 따로 만든다.
  - health-cron은 쓰지 않는다.

### 3.6 비용 최소화 (서울, 부가세 10% 별도)

> **현재(ADR-017): 0원.** GitHub Actions 비공개 저장소 월 2,000분(결제 수단 없음 → 초과 시 실행만 막힘), Neon Free(DB 월 100 CU-시간·0.5GB, Object Storage 5GB, 전송 월 5GB). 아래 AWS 표는 기록이다. 한도와 예상 사용량은 ADR-017 비용 표.
**원칙**
1. 개발은 로컬 docker-compose로 한다.
2. AWS는 필요한 기간에만 쓴다. EC2는 W3부터 24/7로 켠다. DB(PostgreSQL 18)는 Neon Free(0 USD)에 둔다(ADR-015). **RDS는 시연에도 쓰지 않는다(ADR-016).**
3. 도메인, 인증서, NAT, ALB, ElastiCache, WAF는 쓰지 않는다.
4. 앱 데이터는 S3 정적 팩이다.
5. 측정 장비(삼각대, 수평계 앱)는 보유품이나 대여로 해결한다(0원).

| 구성요소 | 선택 | 함정·근거 |
|---|---|---|
| EC2 | t4g.small(2GB) 1대만, **CPU 크레딧 standard**, gp3 20GB, 스왑 2GB, `-Xmx512m -XX:+UseSerialGC`(Metaspace 192m, code cache 64m, direct 64m), Valkey 128MB. JVM과 Valkey만 돌린다(DB 서버 없음, `deploy/ec2/install.sh`는 PostgreSQL 18 클라이언트와 Valkey만 설치) | **T4g 무료 체험 2026-12-31까지** [확실]. Unlimited 모드는 초과 과금. 리허설 실측(`scripts/ec2sim.sh`, 10-01, DB 제외 구성): 서버 JVM 306MiB, valkey 19MiB, OS·에이전트 270MiB 포함 1,600MiB 중 595MiB, 대기 중 DB 연결 0. **t4g.micro 전환이 다시 가능하다**(조건: `-Xmx384m`, Valkey `maxmemory 64mb`, 실제 EC2에서 7일간 MemAvailable ≥250MiB와 스왑 ≈0). 12월에 정한다(ADR-015) |
| DB | **Neon Free**(PostgreSQL 18, ap-southeast-1, TLS, direct 엔드포인트, `-pooler` 아님). 컴퓨트 크기는 Free에서 고정(primary 0.25~2 CU 자동 확장, 10-01 확인). Hikari `minimum-idle 0`, `idle-timeout 60000`, `keepalive-time 0`, 최대 풀 5. 최초 1회 `deploy/postgres/bootstrap-db.sh`(neondb_owner)로 `starindex` 역할(superuser·CREATEDB 없음)과 DB를 만든다 | 프로젝트당 0.5GB(넘으면 쓰기 실패), 월 100 CU-시간(넘으면 다음 달까지 정지), 5분 무쿼리 시 0으로 축소, 월 egress 5GB, 즉시 복원 6시간, 브랜치 10개 [확실, neon.com 문서 2026-10-01]. 예상 하루 약 10회 짧게 깨어나 월 약 12 CU-시간 [추정]. 2 CU면 8배다. HikariCP 7 기본값은 유휴 연결을 2분마다 확인해 Neon을 깨워 둔다(월 약 180 CU-시간). 실측: 마지막 쿼리 약 100초 뒤 DB 연결 0(ADR-015, DB-PLAN 11) |
| 네트워크 | 기본 VPC 퍼블릭 서브넷, EIP 1개, SG는 CloudFront prefix list만 허용, SSM으로 접속 | **NAT를 쓰면 월 43 USD 이상 추가** [확실]. IPv4 월 3.65(정지 중에도 과금) [확실] |
| RDS | **쓰지 않는다**(ADR-016, 10-01 사용자 결정). 과제 스택의 "RDS" 자리는 Neon Free PostgreSQL 18이 맡는다 | 평가가 RDS 인스턴스를 요구하면 감점 위험 [불확실]. 옮길 때는 `DB_URL`만 바꾼다 |
| CloudFront | PAYG + 기본 도메인 | 월 1TB·1천만 요청 무료 [확실] |
| 기타 | SSM Standard, CloudWatch 알람 3개, Budgets, Scheduler(월 1,400만 호출 무료), Unity Personal, APNs, data.go.kr, GitHub private + Linux | 0원 |

**기간별 예상 비용**(가격 API 2026-09 [확실], 합계는 추정)

| 기간 | AWS 가동 | 금액 |
|---|---|---|
| M0(~10/19) | W3부터 약 10일(EC2 무료, Neon Free 0, RDS 없음, 스토리지·EIP·EBS 약 2.5) | **약 3~6 USD**(추정, ADR-016) |
| R1~R2(약 6~9주) | EC2 24/7 + Neon Free 0 + EIP·IPv4 3.65 + EBS + S3, RDS 없음(EC2 무료 체험 2026-12-31까지) | **월 약 6**(추정, ADR-015) |
| R3~2026-12-31 | EC2 24/7 + Neon Free 0, RDS 없음 | **월 약 6**(추정, ADR-015) |
| 2027-01~ | 심사·운영 24/7, EC2 t4g.small + EBS + IPv4, Neon Free 0, RDS 없음 | **월 약 21**(t4g.micro 조건 통과 시 월 약 13, 추정, ADR-015) |
| 2027 선택 G-C1 | Scheduler로 16:30 EC2 시작 → 01:30 EC2 정지(DB는 Neon이라 EC2와 따로 돈다)<br>Spring은 `hikari.initialization-fail-timeout=-1`, systemd `Restart=on-failure`<br>Scheduler 역할에는 `ec2:Start/StopInstances`만 준다<br>정지 시간대에는 알람 ②·③을 `DisableAlarmActions`하거나 `TreatMissingData=notBreaching`으로 둔다 | 금액은 RDS 제외로 재산정 필요(이전 20/18은 RDS 포함). **심사 기간에는 쓰지 않음** |

- **계정**
  - **Free plan이면 W1에 즉시 Paid로 전환한다.** Free plan은 6개월이 지나거나 크레딧을 다 쓰면 계정이 닫힌다 [확실]. 남은 크레딧은 가입 후 12개월까지 적용된다.
  - 레거시 12개월 프리티어는 이미 끝났다 [확실].
- **Budgets**: 2026년 월 30 USD, 2027-01부터 월 45 USD. 50/80/100%에 알림을 건다. M0 달에는 50% 알림이 울릴 수 있다.
- **비용 체크리스트**(W3 완료 기준에 포함)
  - `aws ec2 describe-instance-credit-specifications` = standard
  - Neon direct 엔드포인트·TLS, 첫 주 콘솔 CU-시간 확인(primary 컴퓨트 0.25~2 CU, ADR-015)
  - RDS 인스턴스 0개(ADR-016)
  - NAT 0, EIP 1
  - `cost-log.md` 첫 기록
- **2027 선택**: (폐지) RDS 1년 예약 검토는 하지 않는다. M0 뒤 RDS를 쓰지 않는다(ADR-014).
- **G-C2(선택)**: CloudFront VPC origin(추가 비용 0)과 자동 할당 IPv4 조합으로 EIP와 비밀 헤더 의존을 없앨 수 있는지 검증한다. 퍼블릭 서브넷에서 되는지는 [미확인]이다.

## 4. 스카이뷰 핵심 알고리즘

### 4.1 센서
1. **프레임**(`FrameKind` 이름으로 통일)
   - `cmTrueNorth`(권한이 있고 사용 가능할 때)
   - → `cmMagnetic`(`DeclinationTable` D, 서울 −9° [확실], 해외 예시)
   - → `cmArbitrary`(천체 정렬 필수)
   - → `manual`(ψ를 적용하지 않음)
   - **W2 G3 스모크**: 대략적 위치에서 `.xTrueNorthZVertical`로 5초 안에 갱신이 오는지, `CMErrorTrueNorthNotAvailable`가 나는지 기록한다. 실패하면 magnetic 폴백으로 시연한다.
2. **설정**
   - `1/60`s, `showsDeviceMovementDisplay=true`, 렌더 루프 폴링
   - 비활성이면 stop
   - SkyScreen이 활성인 동안 `startUpdatingLocation(distanceFilter:1km)`
3. **필터**: `simd_slerp(q_f, q_raw, α)`, `α = 1−exp(−Δt/τ)`, `τ = clamp(0.14s − c|ω|, 0.02s, 0.14s)`. 프레임률과 무관한 시정수다.
4. **배지**: `headingAccuracy<0`이면 빨강, ≤10°는 초록, ≤25°는 노랑(가정). 빨강이 5초 넘게 이어지면 8자 보정 안내
5. **원탭 보정**
   - `ψ_new = wrap180(ψ_old + (A_true − A_reticle))`
   - **ψ는 FrameKind별로 저장한다.** 프레임이 바뀌면 그 키의 ψ를 적용한다.
   - cmArbitrary의 ψ는 모션을 재시작할 때마다 초기화하고 천체 정렬을 강제한다.
   - 30분이 지나거나 지역이 바뀌면 재보정을 권한다.

### 4.2 좌표 파이프라인 (x=N, y=W, z=Up)
1. **별 벡터**: `s_i=(cosδcosα, cosδsinα, sinδ)`. J2000, epoch 2026.5 고유운동
2. **R(1Hz, 재생 중에는 매 프레임)**: k번째 열 = `Astronomy_RotateVector(Astronomy_Rotation_EQJ_HOR(&t,obs), e_k)`
3. **지평 좌표**: `h=R·s`, `alt=asin(h_z)`, `az=atan2(−h_y,h_x)`
4. **굴절**: **모든 고도에** `alt' = alt + Astronomy_Refraction(REFRACTION_NORMAL, alt)`(도 단위)를 적용하고 벡터를 다시 만든다. AE는 −1° 아래에서 `(alt+90)/89`로 연속 감쇠한다 [확실].
5. **해·달·행성**: `Astronomy_Equator(body,&t,obs,EQUATOR_J2000,ABERRATION)`(관측자 중심)로 같은 경로에 넣는다. 평소에는 5초마다 계산하고, **재생 중에는 매 프레임 또는 시뮬레이션 시간 1분마다** 계산한다.
6. **방위 보정**
   - `Rz(θ)`는 반시계이고 방위를 A → A−θ로 바꾼다. `h' = Rz(ψ)·Rz(D)·h_r`
   - **D는 frame==cmMagnetic일 때만 값이 있다.** trueNorth, arbitrary, ARKit에서는 0이다. `FrameTransform`이 D를 가진다.
7. **기기 좌표**: `M_f = A·Rz(ψ)·Rz(D)`. A 규약은 G2에서 실제 렌더 경로(CMQuaternion → simd_quatd → 행렬)로 확정한다.
8. **투영**: `f=(H/2)/tan(φ_v/2)`, `sx=c0.x+f·v_x/(−v_z)`, `sy=c0.y−f·v_y/(−v_z)`(c0는 rect 중심)
9. **역투영**
   - `d_HOR = Rz(−D)·Rz(−ψ)·Aᵀ·d_dev`
   - **`d_EQJ = Rᵀ·unrefract(d_HOR)`**(`Astronomy_InverseRefraction`)
   - → `Astronomy_Constellation`

### 4.3 렌더링과 인터랙션
- **레이어 순서**: 하늘 셰이더 → 고도 격자 → 은하 적도 → 별자리 선 → 별 → 행성·달 → 반투명 지면 → 방위 → 라벨 → HUD
- **한계등급**(박명에 따라 별이 나타나는 규칙)
  - `m_night = clamp(m_base(light) − 0.5k·max(0,sin h_moon), 3.0, 6.5)`
  - `m_tw(h_geo)`: 구간 선형이고 **모든 매듭이 유한값**이다. `h≥−3°`에서 −5.0(별 숨김), −6°에서 0.0, −12°에서 3.0, **−18°에서 7.0, h<−18°는 7.0 유지**(m_night 상한 6.5보다 커서 결과적으로 m_night가 적용된다)
  - **`m_lim = min(m_night, m_tw)`**
  - 별 알파 = **`1 − smoothstep(m_lim−0.6, m_lim, m)`**. m≥m_lim이면 0, m≤m_lim−0.6이면 1이다.
  - 해·달은 항상 표시한다. 행성은 m_lim을 따르고 하한은 −5다.
  - 별자리 선과 라벨의 알파도 SkyPhase를 따른다(낮·골든아워는 0, 시민박명에서 서서히 켬).
- **라벨**: 우선순위(해·달 > 행성 > 별자리 > 밝은 별 > Messier), 최대 40개, 이전 프레임 가점
- **성능**(G5로 통일): 보유 기기 프레임 p95 ≤8 ms(A13 환산 16.7 ms), 셰이더 GPU ≤1 ms. 세부 예산은 투영 ≤1 ms, 라벨 ≤1 ms다.
  - M0(W2)는 한시적으로 16.7 ms를 기준으로 삼는다.
  - `thermalState ≥ .serious`이면 30Hz로 낮춘다.
  - **실패하면 4.4 폴백 ①②를 적용하고, 그래도 안 되면 D2 MTKView로 옮긴다.**
- **인터랙션**
  - 탭: 44pt 최근접 → 상세
  - 검색 안내(R1): 초성 검색, 가장자리 화살표, 150°를 넘으면 "뒤돌아보세요", "21:42 뜸", 햅틱
- **시간 이동**: ±24h, ×60/×600/×3600, 오늘 밤 미리보기, 최적 시각, 해질녘·해돋이 재생(4.4)
- **기타**: 수동 모드, VoiceOver 목록, 적색 야간 모드

### 4.4 시간에 따른 하늘색 (노을·해질녘 진행), 추가 비용 0원
- **입력**
  - 태양 벡터: `EphemerisService`. live는 1Hz, 재생은 매 프레임
  - **기하 고도 `h_geo`**(굴절 없음): 단계 판정, 팔레트, m_tw에 쓴다. USNO·천문연 정의와 같다 [확실].
  - 굴절 고도: 글로우 위치에만 쓴다.
- **단계 표시 `SkyPhase`**(겹치지 않게 설계)
  1. 공식 단계(반열린 구간): 낮 `h>−0.833`, 시민 `−6<h≤−0.833`, 항해 `−12<h≤−6`, 천문 `−18<h≤−12`, 밤 `h≤−18`
  2. 관례 태그: 골든아워 `−0.833<h≤+6`, 블루아워 `−6<h≤−4`, 둘 다 아니면 없음. 둘 다 사진계 관례이고 출처마다 다르다.
  3. 이벤트: `|h+0.833|<0.25°`이면 '일몰' 또는 '일출'. 방향은 dh/dt 부호로 저녁과 새벽을 가른다.
  - HUD 한 줄: 이벤트가 있으면 이벤트. 없으면 `{저녁|새벽} {공식 단계}`에 태그가 있을 때 `· {태그}`를 붙인다(예: "저녁 시민박명 · 블루아워").
  - 천문연 ETL 시각을 함께 표시한다: "천문박명 종료 19:52(천문연)".
- **팔레트**(sRGB hex 초안, 출처 없는 디자인 값이라 튜닝 대상. gW 단위는 `1−cosθ`)

| h_geo | 천정 | 지평(반대) | 지평(태양) | gS | gW | nightGlow |
|---|---|---|---|---|---|---|
| ≥+20° | #3D7CC9 | #A9CBEA | #CFE0F0 | 0.15 | 0.03 | 0 |
| +6° | #4A78B8 | #B9C9DC | #F3D9A8 | 0.45 | 0.06 | 0 |
| −0.83° | #3A5584 | #8E90B4 | #F59A52 | 1.0 | 0.12 | 0 |
| −4° | #263A66 | #4D5C8C | #C9735A | 0.7 | 0.15 | 0 |
| −6° | #1B2A52 | #33416E | #8C5A66 | 0.45 | 0.18 | 0 |
| −12° | #0B1430 | #16203F | #22284A | 0.12 | 0.20 | 0.3 |
| −18° | #03060E | #070B17 | #070B17 | 0 | 0.20 | 1.0 |

  - 밤 가산색 `cNight`
    - 식: 달 `k√max(0,sin h_moon)`×#1A2A4A + 광공해 `L`×#3A2E2A
    - `L`은 0~1로 정규화한 광공해 등급이다. **M0에서는 0**이고 R3의 VIIRS 이후에 적용한다.
    - **밤 휘도 상한**: `Y(cNight) ≤ Y(−12° 천정)`이 되도록 스케일한다. 그래서 어떤 조건에서도 h≤−6° 하늘이 −6° 천정보다 밝아지지 않는다.
  - 지면색 `cGround`: 지평선 반대쪽 색×0.35
- **색공간 계약**
  - hex는 CPU에서 **sRGB EOTF로 선형화**한다.
  - 시간 보간은 OKLab에서 smoothstep으로 하고, 결과는 **선형 sRGB `float3`**로 넘긴다(`.color` 인자는 쓰지 않는다).
  - 셰이더 안의 mix, 가산, 탈채도는 **선형에서** 계산한다. luma는 Rec.709 선형 계수(0.2126, 0.7152, 0.0722)를 쓴다.
  - 반환 직전에 **`c = saturate(c)`로 클램프한 뒤** sRGB OETF(x≤0.0031308이면 12.92x, 아니면 1.055x^(1/2.4)−0.055)로 인코딩하고 α=1로 반환한다.
  - `Canvas(colorMode: .nonLinear)`를 명시한다. `SkyColorModel`도 같은 순서로 계산한다.
- **셰이더** `SkyColor.metal`(약 50줄, 추정)
  - 시그니처: `[[stitchable]] half4 skyColor(float2 p, float4 rect, float f, float3 r0, float3 r1, float3 r2, float3 sun, float3 cZ, float3 cA, float3 cS, float3 cNight, float3 cGround, float4 misc)`
    - `misc`: gS, gW, cloud, nightGlow
    - `r0..r2`: `Rz(−D)·Rz(−ψ)·Aᵀ`의 행
  - 계산
    ```
    c0 = rect.xy + 0.5*rect.zw
    v  = normalize(float3((p.x-c0.x)/f, -(p.y-c0.y)/f, -1)); d = (dot(r0,v), dot(r1,v), dot(r2,v)); mu = d.z
    t  = pow(1 - saturate(mu), HORIZON_EXP)       // 상수 3.0, Swift와 Metal이 같은 값을 공유
    nd = d.xy * rsqrt(max(dot(d.xy,d.xy), 1e-8))
    side = 0.5 + 0.5*dot(nd, sun.xy)            // sun.xy는 정규화하지 않음(태양이 높을수록 좌우 차가 사라짐)
    base = mix(cZ, mix(cA, cS, side), t)
    glow = gS * exp(-(1 - dot(d,sun)) / max(gW,1e-3)) * t * smoothstep(-0.02, 0.0, mu)
    c = base + glow*cS + nightGlow*cNight
    c = mix(c, float3(luma(c)*(1-0.25*cloud)), 0.7*cloud)  // 흐림 탈채도
    c = mix(cGround, c, smoothstep(-0.10, 0.0, mu))
    return half4(half3(srgbEncode(saturate(c))), 1)
    ```
  - 사용: Canvas 첫 레이어에서 `ctx.fill(Path(rect), with: .shader(...))`, `dithersColor = true`, 앱 시작 시 `compile(as: .shapeStyle)`(iOS 18+) [확실]
  - Shader.Argument에는 행렬 타입이 없다 [확실].
- **시간 진행**
  - live: 실시간으로 조금씩 변한다.
  - 재생: ×60/×600/×3600
  - **'해질녘 재생'**(`SunsetPlaybackPlanner`)
    - 시작은 일몰 −45분이다.
    - 종료 T_end는 {h_geo=−18° 도달, 태양 하방 남중, 일몰+3시간} 중 가장 이른 시각이다.
    - 1구간(시작 → min(−6° 도달, T_end))의 배속은 **max(×300, 구간 실시간/15초)**다. 서울에서는 ×300으로 약 14~15초다.
    - 2구간(−6° → T_end)은 남은 실시간을 6초에 맞춰 배속을 계산한다(서울 약 ×600~×850). 전체는 **약 20초, 어떤 위도에서도 ≤21초**다.
    - −6°에 닿지 않는 날은 한 구간으로 보고 전체를 20초에 맞춘다(0으로 나누는 경우 없음).
    - 안내 문구 "오늘은 천문박명이 끝나지 않음"은 **하루 최저 고도가 −18°보다 높을 때만** 표시한다. 일몰+3시간 상한 때문에 멈춘 경우와 구분한다.
    - 일몰이 없는 날(극주·극야)에는 버튼을 비활성화한다.
    - 해돋이 재생도 대칭으로 지원한다.
- **흐림 연동**(Should)
  - 팩의 72시간 SKY/PTY로 cloud를 만든다: SKY1 → 0, SKY3 → 0.45, SKY4 → 0.85, PTY → 0.95. 시각 사이는 선형 보간한다.
  - "예보 기반: 흐림" 칩을 띄운다. 예보가 없으면 맑음으로 처리하고 "예보 없음"을 표시한다.
- **적색 야간 모드**: 마지막에 `Filter.colorMultiply`
- **폴백**(G5 초과 시): `opaque:true` → 2색 그라디언트 → 단색
- **고지**: "표현용 하늘색(물리 시뮬레이션 아님)". GPL 코드와 상수는 쓰지 않는다.

## 5. 마일스톤 (1인, 규모 추정)

### M0 발표 MVP: 약 3주(9/30~10/19), 목표 10/20 전후, 비용 약 8~12 USD
- **가용일**
  - 평일 **12일**: 9/30, 10/1, 10/2, 10/6~8, 10/12~16, 10/19. 10/5와 10/9는 휴일이다.
  - 달력일은 20일이다.
- **인일 추정표**(1인, 추정)

| 주차 | 항목(인일) | 합계 |
|---|---|---|
| W1 | 사용자 조치 0.5 · git/번들 ID/ADR-004 0.5 · catalog-builder(한글명은 d3 `ko`를 잠정 사용하고 R1에서 검수) 1.0 · SkyCore 계산(C 벤더링, AstroEngine, R, 굴절, Ephemeris, RiseSet, Projector, AzimuthCorrection, FrameTransform, DeclinationTable) 2.5 · 하늘 모듈(SkyPhase, m_tw, SkyPalette, SkyColorModel, SunsetPlaybackPlanner) 1.5 · G1a 테스트 1.0 | **7.0** |
| W2 | SkySensors 1.5 · SkyScreen MVP 2.5 · 셰이더와 해질녘 재생 버튼 1.0 · 실기기 스모크 0.5 · Boot 골격 1.0 · 수집 Job 2개(로컬, 교차검증 Step은 R3) 1.5 | **8.0** |
| W3 | 발행 Job 1.5 · 앱 팩 클라이언트와 IndexChip 1.5 · 무과금 운영(GitHub Actions 예약 ETL, Neon DB·버킷, 운영 스크립트; ADR-017로 AWS 일괄 대체) 2.5 · 관리자(JWT, 실행 이력, 로컬) 1.0 · 24시간 무인 운영과 리허설 1.0 | **7.5** |
| 합계 | | **약 22.5**(가용 평일 12일 + 주말·휴일 8일 = 최대 20) |

- **해석**: 발표가 10/20이면 주말을 모두 써도 약 2.5인일이 부족하다(추정). 그래서 둘 중 하나를 택한다.
  - (a) **발표일이 10/27 이후면 M0를 4주로 늘린다(권장).**
  - (b) 10/20이 확정이면 아래 컷라인을 **체크포인트 날짜에 기계적으로 적용**한다.
- **발표일은 8장 0번에서 확인한다.**
- **배포 동결**: 24시간 무인 운영을 시작하기 전 10/17 12:00(3주 안) 또는 발표 D-2 12:00

**시연 시나리오**(`docs/demo-script.md`: 발표 시각 기준 대상 천체 고도 >15°를 사전 확인)
1. 앱을 켜면 내 하늘이 보인다.
2. 폰을 돌리면 화면이 따라 움직인다.
3. **'해질녘 재생' 약 20초 동안 노을이 블루아워와 박명을 거쳐 밤이 되고 별이 밝은 순서로 나타난다.**
4. **토성**(10/4 충, 저녁 동남~남쪽)을 탭해 상세를 연다.
5. "오늘 밤 72"가 표시된다.
6. Mac 로컬 관리자 화면(`localhost:8080/admin`)에서 ETL 실행 이력(Neon)을 보여 준다.
7. GitHub Actions의 예약 ETL 실행 기록과 공개 팩 검사를 보여 준다(ADR-017, AWS 배포 대신).

| 주차 | 작업 | 완료 기준 |
|---|---|---|
| W1 (9/30~10/4) | **사용자 조치(8장)**. 천문연 출몰 API로 과거 locdate 1콜이 되는지 확인<br>`git init`과 private 저장소, 번들 ID, ADR-004<br>`catalog-builder` → `skypack.bin` v1(≤5.5등), T9 QA<br>SkyCore 계산과 하늘 모듈(인일표의 목록)<br>docker-compose<br>**G-E1(디스크) 판정 뒤** Unity 6.3을 배경으로 설치한다. E3/E4 판정은 R2에서 한다 | **G0**, **G1a** |
| W2 (10/5~10/11) | SkySensors와 `SkyScreen` MVP(별·선·한글명·해달행성·HUD·라벨·탭·드래그 수동 모드)<br>**하늘 셰이더, 해질녘 재생 버튼, m_tw, 단계별 선·라벨 알파**<br>G3 스모크, T-P1·T-P5 실기기 스모크<br>Boot 4.1 골격(더미 Job을 실행하면 `BATCH_JOB_EXECUTION` 행 생성, QueryDSL 7.x Q타입 빌드)과 `forecastIngestJob`·`astroDailyJob`(**로컬**) | ① 실기기 해질녘 재생 1회(자세한 기준은 표 아래)<br>② **G3 스모크 결과 기록**(갱신 도착 여부, `CMErrorTrueNorthNotAvailable` 여부). 실패하면 cmMagnetic 폴백으로 회전 추적 시연을 확인<br>③ T-P1·T-P5 실기기 통과<br>④ 로컬 ETL 1회 성공 |
| W3 (10/12~10/19) | `starIndexPublishJob`(17개 시·도, 72시간 SKY/PTY, kasi 시각), 앱 `IndexChip`<br>무과금 운영(ADR-017): `etl.yml` 예약 실행, Neon DB(`ops/neon/bootstrap.sh`)·공개 버킷, 시크릿·변수(`docs/ETL.md` 8절)<br>관리자(JWT, 실행 이력, Mac 로컬)<br>24시간 무인 운영 → 리허설 | ① `scripts/check-public-pack.py <공개 URL>` 통과(익명 읽기, sha256, Cache-Control, 발표 6시간 이내)<br>② 버킷 쓰기는 자격 증명으로만 된다(익명 PUT 거부 확인), 서버는 루프백만 받는다(`LocalOnlyFilter`)<br>③ **T19 통과**(발행 뒤 5분 안에 실기기 manifest 갱신)<br>④ **연속 24시간(발표 8회) 예약 실행 수집·발행 성공**(Actions 기록)<br>⑤ 비용 0원 확인: Actions 사용 분, Neon CU-시간·전송량, AWS 자원 0개<br>⑥ RDS·AWS 인스턴스 0개(ADR-016·017) |

W2 해질녘 재생 합격 기준
- 알파가 0보다 큰 별은 m<m_lim인 별뿐이다.
- h_geo>−3°에서는 알파가 0보다 큰 별이 0개다.
- −6°에서는 알파가 0보다 큰 별이 m<0인 별뿐이다.
- 종료 조건에서 자동으로 멈춘다.
- 프레임 p95를 기록한다. 16.7 ms를 넘으면 폴백 ②로 시연한다.

**컷라인**(iOS 부가 기능부터 뺀다. ETL → 팩 → IndexChip 실연동은 마지막까지 지킨다)
- **10/8 체크포인트**(해질녘 재생이 미완이면 즉시 적용)
  - ① 해질녘 재생의 2구간 자동 배속을 고정 ×600으로 단순화한다.
  - ② 라벨 우선순위를 행성·별자리명만 남긴다.
- **10/15 체크포인트**(무과금 운영 설정이 미완이면 즉시 적용)
  - ③ (폐지: ADR-017로 알람 없음. 실패 알림은 GitHub 메일)
  - ④ 관리자 화면은 실행 이력 표만 남긴다(QueryDSL 필터 1개).
  - ⑤ `astroDailyJob`은 AE 계산만 쓰고 천문연 호출을 R3로 미룬다.

**R 단계로 미룬 것**
- R1: T2 골든, G2 정식 측정, 검색 안내, TimeTravelBar 전체 UI(스크럽·배속), 한글명 검수, ADR-001~003, 흐림 탈채도
- R2 첫날: G-E3, G-E4
- R3: 교차검증 Step, 관리자 WS 진행률
- R4: legal 페이지, App Group, 앱 레코드

### 출시 트랙: R1 2–3 + R2 4–6(No-Go 시 약 2.5) + R3 2–3 + R4 1–2 + R5 2–3 = **11~17주**, 전체 14~20주, 제출 2027-01~02(추정)
| 단계 | 작업 | 완료 기준 |
|---|---|---|
| R1 스카이뷰 완성 | 전체 카탈로그(≤6.5), 검색 안내, 보정 UX, 접근성, 은하, 박명 연동 튜닝, 하늘색 튜닝(콘택트 시트)<br>T2 골든(Kotlin), **T5·T16: 천문연 API를 locdate로 10지점×30일 일괄 조회(약 300콜)**<br>G2 정식 측정, G3, G5<br>**C9 적중률 스냅숏**: `verify_station`·`forecast_verification` 기록 시작(첫 주 11/2~11/6, 기한 11/28, ADR-014) | **G1**, G2, G3, G5, T8, T10, T14~T18 |
| R2 Unity AR | **U-스파이크(5일)**: UaaL 임베드, 브리지 rotation·offset, 빈 천구<br>→ **Go/No-Go**(G-E3, G-E4, G-U1, G-U2, G-U4, G-U5, 스파이크 수준 G-U3)<br>→ **U-구현**(라벨, 탭, 목표 안내, 보정 왕복, 시간 동기화, 연출 3종)<br>→ G-U6, G-U7, G-U8, T-U1 | G-U 전부 통과와 T-U1(No-Go에서 ①을 고르면 **G10**). `AR_UNITY` OFF 빌드도 정상 |
| R3 백엔드 완성 | `forecastVerifyJob`(ASOS 관측값 채움), 시군구·명소 팩, 천문현상, VIIRS, 카탈로그 Job, 품질 게이트, 교차검증, **T13** | G6, G11, G12 |
| R4 앱 통합 | 오늘 밤·명소·천문현상 탭(팩 기반), 오프라인, LiveSocket, 위젯, 해외·장애 화면, 데이터 삭제, `legal/*.html`, App Group, G9에 따른 푸시 | G7, G9 |
| R5 출시 | privacy manifest(앱, 위젯, UnityFramework), 라벨, 연령등급, Content Rights, 스크린샷, 심사 노트, TestFlight 1주, 제출, 반려 버퍼 1주 | G8, 승인 |

- **Unity Go/No-Go 실패 시**
  - **사용자가 고른다**(ADR-006에 기록)
    - ① 네이티브 AR-1(AVCapture 회전 전용 오버레이, 약 1.5주)로 대체해 출시(권장)
    - ② 출시를 N주 미루고 Unity 문제를 해결
    - ③ v1.0은 AR 없이 출시하고 Unity AR은 v1.1
  - G-E3/E4의 2일 시계는 **R2 첫날부터** 센다. W1~W3에서는 설치만 한다.
  - U-구현 이후 게이트가 실패하면 **사용자에게 v1.1 이월 또는 출시 연기를 묻고** ADR-006에 기록한다.
- **v1.0에서 하지 않는 것**: 로그인, Live Activity, NGC/IC, 한국 전통 별자리, iPad, 120Hz, Android, 도메인, AR 하늘색

## 6. 검증 계획

### 6.1 테스트 (`swift test`와 Gradle)
- **G1a(W1)**: T1, T3, T4, **T7(합성: Apple 기준 프레임 정의로 만든 정답 쿼터니언만 사용, A 규약은 잠정이고 G2 뒤 재실행)**, T9, T11, T14, T15, T18
- **G1(R1)**: G1a에 T2, T5, T6, T8, T16을 더한다. T5와 T16은 과거 locdate 조회가 안 되면 **둘 다 R3 완료 기준으로 옮긴다.**
- **T12**(자세 로그 재생)는 G2에 속한다. **T19**는 W3 완료 기준과 G7에 속한다.
- **T1**: `R·Rᵀ≈I`(1e-12), `det≈1`
- **T2**: Kotlin `rotationEqjHor`·`refractionAngle`로 만든 골든 값과 비교. R 원소 ≤1e-9, 각도 ≤0.001°
- **T3**: J2000→R→굴절 경로와 `Astronomy_Horizon(EQUATOR_OF_DATE, REFRACTION_NORMAL)`의 차이 ≤1′(모든 고도)
- **T4**
  - `Refraction(NORMAL, 0)=0.4830325°`, `−0.57 → 0.573221°`, `−1.0 → 0.646581°`, `−2.0 → 0.639316°`, 각각 |Δ|≤1e-6°
  - Inverse 왕복 오차 ≤0.01′
  - 북극성 고도 ≈ 위도 ±1°(천구북극 이격 약 0.62° 반영)
  - 남중: δ<φ이면 az=180°, δ>φ이면 az=0°
- **T5**: 천문연 대비 10지점 × 30일 출몰·박명 p95 ≤2분. R1에서 locdate로 일괄 조회한다(약 300콜). 과거 날짜 조회 가능 여부는 W1에 확인한다.
- **T6**: JPL Horizons 5건 ≤2′
- **T7**
  - T-P1: 북쪽 지평선을 보면 중앙, 오른쪽이 동쪽
  - T-P2: 동쪽을 보면 az90이 중앙
  - T-P3: 원탭 보정 부호. **T-P3b: 같은 목표 연속 2회 탭에서 ψ 변화 ≤0.1°**
  - T-P4: **trueNorth는 D 미적용, magnetic은 D 적용. 두 방위 차 ≤0.5°**
  - T-P5: 화면이 아래를 향하면 천정이 중앙
- **T8**: 화면 → HOR → 화면 ≤0.5px. **EQJ → 화면 → EQJ ≤0.01°(InverseRefraction 포함)**. ψ와 D가 0이 아닐 때도 북극성은 UMi
- **T9~T12**: 팩 QA, 라벨 겹침 0, `KMAGrid` 서울 → (60,127) [확실], 자세 로그 재생
- **T14 SkyPhase**: +6, −0.833, −4, −6, −12, −18° 경계, 경계값이 정확히 같을 때의 소속, dh/dt 부호 반전(저녁과 새벽), 굴절 고도를 쓰지 않음
- **T15 팔레트**(픽스처 cNight=0: 달은 지평선 아래, 광공해 0)
  - 0.1° 간격 스윕에서 인접 ΔE_ok ≤0.02(가정)
  - 천정 휘도 단조 감소(+6 → −18°)
  - cloud 극한
  - **isfinite(천정·천저 픽셀)**
  - **T15b**: cNight를 최대로 두어도 모든 h≤−6°에서 Y(천정) ≤ Y(−6° 천정)
- **T16 천문연 교차**: civile/naute/aste 시각에서 AE 기하 고도가 −6/−12/−18°±0.25°(서울 약 1.3~1.8분)
- **T17 셰이더**
  - **절대색**: `dithersColor=false`일 때 천정 픽셀이 키프레임 hex ±2/255. 단색 #3D7CC9 입력 시 (61,124,201)±1
  - CPU 참조와 GPU 콘택트 시트(고도 13 × 방위 4)
  - 24시간 ×1000 재생에서 급변 없음
  - SKY fixture로 탈채도 확인
  - **해질녘 재생**
    - 서울 9/29·6/21·12/21: 전체 18~21초
    - 55°N·60°N·62°N의 6/21: ≤21초이고 0으로 나누는 경우가 없음
    - 48°N 6/21: '천문박명 미종료' 문구가 뜨지 않음(상한으로 멈춘 경우)
  - 실기기 10분 thermal
- **T18 한계등급**(픽스처 k=0, 달은 지평선 아래)
  - 매듭: h_sun=+10/−6/−12/−18°에서 m_base=6.5이면 m_lim=−5/0/3/6.5, m_base=4.0이면 −5/0/3/4.0
  - **중간점**: −9°에서 1.5, −15°에서 5.0(m_base 6.5), −15°에서 4.0(m_base 4.0)
  - 알파: m≥m_lim이면 0
- **T19 팩 전파**: 발행 뒤 5분 안에 앱의 manifest가 바뀐다(CloudFront TTL 60초).
- **T-U1**(Unity EditMode)
  - 입력: 실제 R fixture(서울, 2026-10-01 21:00 KST), 목표 2개(alt0/az10, alt60/az100), ψ=+10°, 카메라 forward=+Z
  - 합격: 첫 목표가 중앙에서 ≤0.1°, 둘째 목표의 방위가 ψ만큼 이동 ≤0.1°
- **백엔드**
  - 단위: 지수·기여도 예외, LCC 격자, 쿼터, JWT·티켓, 정렬 키 화이트리스트
  - **오리진 필터**
    - 헤더 없는 외부 요청 → 403
    - 헤더 없는 loopback(127.0.0.1과 ::1) 관리자 경로 → 200
    - 올바른 헤더 + `/api/admin/**`, `/admin/**`, `/api/v1/admin` → 403
    - 헤더 값 불일치 → 403
    - 8081 loopback actuator → 200
  - 배치: `@SpringBatchTest` + WireMock, 멱등성
  - Testcontainers PostgreSQL 18(로케일 C) + valkey 8 + WireMock(ADR-013/014)
  - WS, 계약 테스트
- **T13 백테스트**: 17:00 발표 SKY/PTY와 ASOS 전운량을 10곳 × 30일 비교해 혼동행렬을 만든다. 예보 쪽 값은 R1부터 `forecast_verification`에 기록한 17:00(d17)·전날 23:00(p23) 발표 스냅숏(C9)이고, ASOS 관측값은 R3 `forecastVerifyJob`이 채운다(ADR-014).

### 6.2 실기기 방향 검증
- **측정 방법**: 삼각대(보유 또는 대여), 다른 기기의 수평계 앱, `SkyProbeView` 카메라 십자선, 1km 이상 떨어진 랜드마크. 먼저 측정자 반복성(σ≤0.5°)을 확인한다. 밤에는 달, 토성, 북극성을 기준으로 한다.
- **측정 조건**: 기준마다 10회 × 장소 3곳. 보정 전, 8자 보정 뒤, 원탭 보정 뒤. roll ±30°, 5분 드리프트, 첫 유효 heading 시간.

### 6.3 게이트 정의
| 게이트 | 합격 기준 |
|---|---|
| G0 | `xcodebuild -license check`=0, 빈 앱이 실기기에서 실행, Budgets 설정, **AWS가 Free plan이면 Paid 전환 완료**, 플랜 유형 기록 |
| G1a / G1 | 6.1 목록 전부 통과 |
| G2 | 실외 3곳 × 10회에서 8자 보정 뒤 중앙값 ≤5°, 원탭 보정 뒤 ≤2°, T-P1~P5 실기기 통과, A 규약 확정(샘플 100개 차이 ≤1e-6) |
| G3 | 정밀·대략·거부·미결정에서 사용된 프레임 기록, trueNorth를 쓸 수 없으면 5초 안에 폴백 자동 선택, 크래시 0 |
| G5 | **보유 기기 프레임 p95 ≤8 ms(A13 환산 16.7 ms), 셰이더 GPU ≤1 ms**. M0(W2)는 한시적으로 16.7 ms. 실패하면 4.4 폴백 ①② → D2 MTKView |
| G6 | 7일 연속 모든 Job 성공, 품질 지표 충족(신선도 ≤3.5h/6h, 완결성 ≥99%, 오류 ≤2%, 쿼터 <90%, 교차검증 p95 ≤2분) |
| G7 | 위치 거부, 해외(GPX 쿠퍼티노), 실내·낮, **EC2 정지**, 비행기 모드 5개 시나리오에서 하늘 탭과 캐시된 팩 동작, 크래시 0. **T19와 롤백 뒤 5분 안에 앱 반영** |
| G8 | 6.4 체크리스트 100% |
| G9 | lbsc.kr 회신(관심 지역과 토큰 결합의 법적 성격) |
| G10 | (AR-1 대체 시) 달·행성·밝은 별 3개 오차 ≤2°, 기기별 화각 계수 k 기록 |
| G11 | 기상청·천문연 원문 필드 확인, ASOS 라이선스 |
| G12 | VIIRS → 광공해 등급 모델 |
| G-E1 | **W1에서 Unity를 설치하기 전에** 판정한다. Unity 6.3 + iOS 모듈 + Xcode 26.x 여유분을 합쳐 디스크 ≥40GB. 부족하면 6000.0.78f1 제거를 먼저 제안한다(동의 필요) |
| G-E2 | = G0의 Xcode 라이선스 |
| G-E3 | Rosetta 없이 6.3 빈 AR 템플릿 플레이. 실패하면 동의를 받아 Rosetta 2 설치 |
| G-E4 | 빈 AR 프로젝트 → Xcode 27 → 실기기. 실패하면 Xcode 26.x를 설치하고 **앱 전체를 Xcode 26.x로 아카이브**(업로드 요건 충족 [확실]) |
| G-U1 | export → Archive → 실기기 스크립트 재현 ≤15분 |
| G-U2 | 추적 모드, GravityAndHeading 적용, +Z와 CoreMotion 진북 차이 ≤5°, 야간 limited 비율 |
| G-U3 | 원탭 보정 뒤 중앙값 ≤2°(ARKit 프레임 ψ) |
| G-U4 | 다운로드 증가분 ≤+50MB |
| G-U5 | 진입·이탈 20회에서 jetsam 0, 잔존 ≤180MB(150MB 초과는 경고) |
| G-U6 | 첫 진입 ≤3 s, 재진입 ≤1 s, fps p95 ≥55, 10분 ≤`.fair` |
| G-U7 | UnityFramework PrivacyInfo·서명 누락 0 |
| G-U8 | 연출 3종 완료 |
| G-C1 / G-C2 | (선택) 3.6 참조 |

### 6.4 심사 전 체크리스트 (G8)
- **빌드**: Xcode 27(27A266a)로 빌드한다. 업로드 요건은 Xcode 26 이상이다(2026-04-28부터) [확실]. G-E4 폴백이면 Xcode 26.x로 아카이브한다. `ITSAppUsesNonExemptEncryption=NO`, 연령등급 질문에 답한다.
- **privacy manifest**: 앱, 위젯, UnityFramework. 코드는 **CA92.1, 1C8F.1, 35F9.1**이고 나머지는 스캔해서 정한다 [확실].
- **권한과 동의**
  - **위치·푸시를 켜지 않아도 핵심 기능이 동작한다(5.1.2(i)).**
  - 위치를 거부하면 수동으로 입력할 수 있다(5.1.1(iv)).
  - 위치 서비스 용도를 설명한다(5.1.5).
  - 푸시는 필수가 아니고 opt-in·opt-out을 둔다(4.5.4).
  - **개인정보처리방침 링크를 App Store Connect와 앱 설정 탭 양쪽에 둔다(5.1.1(i)).**
  - 로그인은 없고 데이터 삭제를 제공한다.
- **메타데이터**: Privacy·Support URL은 CloudFront `legal/*.html`이다. 출처 화면을 두고 Content Rights를 신고한다.
- **심사 운영**
  - GPX 쿠퍼티노로 확인한다. EC2가 꺼져도 하늘과 팩은 동작해야 한다. 심사 기간에는 EC2를 24/7로 둔다. DB(Neon)는 배치 때만 깨어나고 앱 사용자는 DB를 거치지 않는다(ADR-015).
  - 심사 노트: 한국 데이터 차별점(4.3(b)), 해외 데모, 낮·실내에서는 해질녘 재생과 수동 모드로 확인하는 법, 보정, AR 사용법(4.2.1)
- **스토어**: 스크린샷(하늘·노을 재생, 지수, AR, 위젯), EU DSA 판단

## 7. 주요 리스크
| 리스크 | 대응 |
|---|---|
| M0 일정 초과(인일 약 22.5, 가용 최대 20) | 발표일 확인(8장 0번). 10/27 이후면 M0를 4주로, 10/20 확정이면 10/8·10/15 체크포인트 컷라인을 적용하고 R 단계로 이월 |
| 나침반 오차, 축 부호 오류 | 배지, 프레임별 누적 보정, 수동 모드, R 열 구성, T7, G2 |
| 대략적 위치에서 진북 프레임 불가 | W2 G3 스모크, magnetic 폴백을 W2 범위에 포함 |
| Unity 환경·일정·메모리 | R2 Go/No-Go, 사용자 재결정, `AR_UNITY` OFF 빌드 유지 |
| **비용 함정** | RDS 미사용(ADR-016), Neon은 Hikari 유휴 연결 0과 첫 주 CU-시간 확인(ADR-015), NAT 미사용, standard 크레딧, Free plan은 W1에 Paid 전환, macOS CI 미사용, Budgets, cost-log |
| Neon Free 운영 | Neon은 중단 없는 가용성이 필요한 운영에는 Free를 피하라고 한다 [확실]. Free의 상업적 사용 허용 여부는 [불확실]. 서울→싱가포르 지연은 미측정(배치만 DB를 쓴다). CU-시간·egress를 넘으면 다음 달까지 DB가 정지한다. 이때 S3/CloudFront 팩으로 앱은 동작하고 다음 발표만 수집되지 않는다. 폴백은 EC2 PostgreSQL(ADR-014, 스크립트는 git `db5aeb4`/`78c8ffa`)이나 RDS, 모두 `DB_URL`만 바꾼다(ADR-015, DB-PLAN 11) |
| 팩 전파 지연 | manifest TTL 60초, 불변 버전 경로, 롤백 시 무효화, T19 |
| 관리자 자격증명 노출 | 공개 경로 차단, SSM 터널, 로그인 실패 잠금 |
| 하늘색 품질(주관성, 색공간) | 색공간 계약, T17 절대색, 콘택트 시트, '표현용' 표기, 폴백 3단계 |
| T13 데이터 공백 | R1 첫 주부터 `forecast_verification` 스냅숏(C9, 기한 11/28), 32일 보존(ADR-014) |
| 위치정보법 | 전국 팩, 앱은 조회 API 호출 금지, 푸시는 G9 뒤 |
| Boot 4.1과 QueryDSL 포크 | ADR-004, W2 호환 확인, 5.1.0 폴백, 정렬 키 화이트리스트 |
| 4.3(b) 유사 앱 판정 | 한국 지수, 명소, 노을 재생을 전면에 |

## 8. 사용자가 직접 할 일
0. **발표 일자·형식·필수 평가 항목을 확인한다**(M0 컷라인 결정에 필요).
1. `sudo xcodebuild -license accept`를 실행한다.
2. ~~AWS(기존 계정)~~ (폐지: ADR-017. 대신 `docs/ETL.md` 8절: Neon 버킷·자격 증명, `ops/neon/bootstrap.sh --github --save-local`, GitHub 시크릿·변수)
   - Billing에서 플랜 유형을 확인하고, **Free plan이면 즉시 Upgrade**한다. T4g 무료 체험과 크레딧 잔액도 확인한다.
   - Budgets 30 USD를 설정한다.
   - **AWS CLI v2와 Session Manager 플러그인을 설치한다**(W3 전). 로그인 순서는 다음과 같다.
     1. IAM Identity Center를 활성화한다.
     2. 관리자 권한 세트와 사용자를 만든다(0원).
     3. `aws configure sso`로 로그인한다.
     - 대안: MFA를 건 IAM 사용자 액세스 키.
   - W3에 SNS 구독 확인 메일(서울과 us-east-1)을 승인한다.
3. data.go.kr 활용신청 3건(기상청 단기예보, 천문연 출몰시각, 천문연 천문현상)을 낸다. ASOS는 R3.
4. Xcode > Settings > Accounts에서 개발자 팀에 로그인하고 번들 ID를 등록한다. 실기기에서 개발자 모드를 켠다. **보유 iPhone 모델명을 기록한다**(G5).
5. **G-E1(디스크) 판정 뒤**, Unity Hub에서 6.3 LTS와 iOS Build Support를 설치한다(동의 후, W1 배경 작업). 필요하면 R2에서 Rosetta 2와 Xcode 26.x를 설치한다.
6. (R3 전) EOG 계정을 만든다. lbsc.kr G9 질의는 W1에 발송한다(초안 제공).
7. (W3 전) **Neon 계정과 프로젝트를 만든다**(ADR-015, `docs/DB-PLAN.md` 11.3). **완료(10-01)**: `star_index`, Postgres 18, Singapore. 실제 Neon 검증도 끝났다(DB-PLAN 11.7).
   - 컴퓨트 크기는 Free에서 바꿀 수 없다. 첫 주 CU-시간만 확인한다.
   - 직접(pooled 아님) 연결 호스트를 `ops/neon/neon.env`의 `DB_URL`에 넣는다.
   - `neondb_owner` 비밀번호는 파일에 저장하지 말고, `ops/neon/bootstrap.sh`가 물을 때 입력한다.
   - 출시 전에 Neon 약관(무료 플랜 상업적 이용)을 확인한다.

도메인은 사지 않는다. 추가 유료 결제는 없다(ADR-017).

## Critical Files (모두 신규)
- `ios/Packages/SkyCore/Sources/SkyCore/Transform/HorizonTransform.swift`: R 열 구성, 굴절 연속, Rz·D 조건
- `ios/Packages/SkyCore/Sources/SkyCore/Projection/Projector.swift`: 투영·역투영(unrefract), `FrameTransform`
- `ios/Packages/SkyCore/Sources/SkyCore/Sky/{SkyPhase,TwilightMagnitude,SkyPalette,SunsetPlaybackPlanner}.swift` + `ios/App/Shaders/SkyColor.metal`: 하늘색·박명
- `ios/Packages/SkySensors/Sources/SkySensors/{CoreMotionAttitudeProvider,CalibrationStore}.swift`: 프레임 폴백, 프레임별 ψ
- `ios/App/Features/AR/UnityHost.swift` + `unity/StarAR/Assets/Scripts/SkyBridge.cs`: 브리지 v1, 월드 앞곱 보정
- `backend/src/main/java/.../etl/index/StarIndexPublishJobConfig.java`, `.../security/OriginVerifyFilter.java`
- `backend/tools/catalog-builder/`, `contracts/{golden/astro_vectors.json, schemas/*.schema.json}`, `deploy/scripts/validate.sh`
