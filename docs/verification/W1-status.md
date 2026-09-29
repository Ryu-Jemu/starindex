# M0-W1 진행 현황 (2026-09-29)

## 완료

| 항목 | 결과 | 근거 |
|---|---|---|
| Step 0: 저장소·GitHub 연동 | private `Ryu-Jemu/starindex`, `main` 추적 | 커밋 `bae923b` |
| Step 1a: SkyCore 좌표·하늘색·박명 | Swift 테스트 38개 통과 | `scripts/test-skycore.sh` |
| Step 1b: 카탈로그 빌더·skypack v1 | JUnit 6개 통과. 별 2,893, 별자리 88, 선분 743, 꼭짓점 893/893 매칭(최대 9.1″) | `data/packs/skypack-v1.qa.json` |
| Step 1c: CI(Linux) | T9와 팩 재현성(바이트 비교) 통과 | Actions run `36530887141` |

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
- `~/Desktop`은 iCloud(File Provider) 동기화 폴더다. 빌드 산출물에 FinderInfo xattr이 붙어 codesign이 실패하므로, SwiftPM `--scratch-path`를 캐시 폴더로 둔다.
- CLT의 Swift Testing은 매크로 플러그인 경로(`-plugin-path …/host/plugins/testing`)를 명시해야 한다.
