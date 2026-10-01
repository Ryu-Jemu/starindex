# M0-W1 진행 현황 (2026-09-29)

## 완료

| 항목 | 결과 | 근거 |
|---|---|---|
| Step 0: 저장소·GitHub 연동 | private `Ryu-Jemu/starindex`, `main` 추적 | 커밋 `bae923b` |
| Step 1a: SkyCore 좌표·하늘색·박명 | Swift 테스트 38개 통과 | `scripts/test-skycore.sh` |
| Step 1b: 카탈로그 빌더·skypack v1 | JUnit 6개 통과. 별 2,893, 별자리 88, 선분 743, 꼭짓점 893/893 매칭(최대 9.1″) | `data/packs/skypack-v1.qa.json` |
| Step 1c: CI(Linux) | T9와 팩 재현성(바이트 비교) 통과 | Actions run `36530887141` |
| Step 1d: SkyCore 적대적 리뷰 반영 | 확인된 결함 14건 수정(반박 5건 제외). 테스트 47개 통과 | 아래 '리뷰 반영' |

## 게이트 상태

| 게이트 | 상태 | 비고 |
|---|---|---|
| **G1a** | ✅ 통과 | T1, T3, T4(굴절 원식 값 ±1e-6°), T7(합성 자세, A 규약 잠정), T9, T11, T14, T15/T15b, T18, T17(CPU 절대색·재생) |
| G0 | ⏳ 사용자 조치 대기 | `sudo xcodebuild -license accept`(현재 exit 69), 실기기 빈 앱 실행, AWS Budgets 설정, 플랜 유형 기록 |
| G-E1 | ✅ 통과 | 여유 42 → **53GiB**(기준 ≥40GB). 사용자 허가(쓰지 않는 모듈·버전 삭제)에 따라 정리했다. **Unity 6000.0.78f1 에디터는 유지**했다. `mobile-ar/ARFingerDrawPoc`와 `HandSpike` 프로젝트가 쓰고 있기 때문이다. 대신 두 프로젝트 모두 macOS 대상이라 쓰지 않는 **AndroidPlayer 모듈(5.7GB)**을 지웠다(Hub에서 다시 추가할 수 있음). 오래된 Xcode **DerivedData(5.7GB, 빌드 캐시)**도 지웠다 |
| Unity 6.3 LTS 설치 | ⏳ 사용자 조치 | Unity Hub 3.19.3은 CLI 설치(`--headless`)가 동작하지 않는다(3.18부터 deprecated). .pkg 설치는 sudo가 필요하다. Hub 화면의 Installs → Install Editor → 6.3 LTS → 모듈 "iOS Build Support"로 설치한다 |
| T5 사전 확인 | ⏳ 사용자 조치 대기 | data.go.kr 천문연 출몰시각 활용신청 뒤 과거 locdate 1콜로 확인 |

## 환경 메모
- Xcode 라이선스에 동의하기 전까지 `/usr/bin/git`과 swift shim이 막혀 있다. `source scripts/dev-env.sh`로 CLT(git 2.54, Swift 6.4)를 쓴다.
- CLT의 SwiftPM ManifestAPI에 2024년 CLT에서 남은 `*.private.swiftinterface`가 섞여 있어 매니페스트 링크가 실패한다. 캐시에 둔 정리본을 `SWIFTPM_CUSTOM_LIBS_DIR`로 지정해 해결했다(시스템 파일은 수정하지 않음).
- `~/Desktop`은 iCloud(File Provider) 동기화 폴더다. 빌드 산출물에 FinderInfo xattr이 붙어 codesign이 실패하므로, SwiftPM `--scratch-path`를 캐시 폴더로 둔다. (2026-10-01: 저장소를 `~/Developer`로 옮겼다. 캐시 설정은 그대로 둔다.)
- CLT의 Swift Testing은 매크로 플러그인 경로(`-plugin-path …/host/plugins/testing`)를 명시해야 한다.

## 리뷰 반영 (SkyCore 적대적 리뷰: 3렌즈 → 각 finding마다 반박 검증)

| 심각도 | 결함 | 조치 |
|---|---|---|
| high | AE `Astronomy_InverseRefraction`의 `for(;;)`에 반복 상한이 없음. 천정(>89.99997°), −90~−64°의 약 0.7%(±1 ulp 2-주기), NaN에서 무한 루프(천저를 볼 때 60Hz로 1초 안에 멈출 확률 약 34%) | 반복 상한이 있는 Swift 고정점 반복으로 교체(AE 호출 안 함). 89.9° 위와 비유한 값은 0 |
| medium | 영벡터·NaN이 `altAz`에서 +90°(천정)로 바뀌어 위 루프로 이어짐 | NaN을 그대로 전파하고, refract·unrefract·ConstellationLocator에 가드 추가 |
| low | Saemundsson 식이 89.89° 위에서 음수가 돼 refract(천정) ≠ 천정 | 89.9° 위에서는 굴절 0(불연속 2.5e-6°) |
| low | 1일 검색 창 때문에 일몰 직후 몇 분간 plan이 nil(극주로 오판) | 2일 창 |
| low | KMAGrid가 NaN이면 `Int()`에서 트랩 | Optional 반환, 격자 범위(1…149, 1…253) 검사 |
| low(테스트) | T7이 대칭 자세만 써서 A와 Aᵀ를 구분하지 못함. 쿼터니언 경로가 빠짐 | `AttitudeConvention`(G2에서 한 곳만 변경) + 쿼터니언·행렬 어댑터. 비대칭 자세(방위 45°, roll 20°)와 잘못된 규약이면 실패함을 음성 테스트로 확인 |
| low(테스트) | 동어반복 검사(clamp가 NaN을 숨김, 기대값을 같은 hex로 생성, T15b 재구현) | `SkyColorModel.linear`로 클램프 전 값 검사, 정수 리터럴 표, 천저=지면색, T15b는 모델 호출로 검증 |
| low(테스트) | 절대 시각 기준점 없음 | J2000 epoch ut=0, Date 왕복, **JPL Horizons 외부 기준(서울, airless): 태양·목성 ≤1′, 달 ≤2′ 통과** |
| low(테스트) | 해질녘 종료 사유와 경계 미검증 | 48/55/60/62°N 종료 사유, 62°N 단일 구간 20초, 70°N 극주 nil, 일몰 직후 1/5/30분 |
