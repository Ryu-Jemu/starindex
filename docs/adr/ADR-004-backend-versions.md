# ADR-004: 백엔드 버전과 의존성

- 상태: 채택(W2 골격 구성 때 호환성 확인)
- 날짜: 2026-09-29

## 결정
- **Spring Boot 4.1.x**(2026-09 기준 4.1.1)를 쓴다. OSS 지원은 2027-07-31까지다.
- Batch는 `spring-boot-starter-batch-jdbc`를 쓴다. 이 스타터여야 JobRepository가 DB에 `BATCH_*` 메타 테이블을 쓴다.
- 마이그레이션은 `spring-boot-starter-flyway`와 `flyway-mysql`로 한다. `BATCH_*` 스키마는 V1에 넣는다.
- QueryDSL은 OpenFeign 포크 `io.github.openfeign.querydsl` 7.x를 쓴다. 7.7은 2026-09-23에 나온 릴리스라 W2에서 7.6과 함께 확인한다.
- 폴백은 Boot가 관리하는 `com.querydsl` 5.1.0(jakarta)이다. 이 경우 ScrollableResults 계열 API(`iterate`, `groupBy` transform)는 쓰지 않는다.
- 정렬·필터 키는 화이트리스트 enum으로만 받는다(CVE-2024-49203 대응, 포크와 무관하게 적용).
- 천문 계산은 Astronomy Engine **v2.1.19**(커밋 `61dc070`) Kotlin jar를 `libs/`에 두고 쓴다. JitPack 좌표는 `io.github.cosinekitty:astronomy:2.1.19`이고, `kotlin-stdlib`를 런타임 의존성에 넣는다.

## 근거
- Spring Boot 4.0 Migration Guide: Batch가 resourceless(`spring-boot-starter-batch`)와 JDBC(`spring-boot-starter-batch-jdbc`)로 분리됐다.
- Spring Boot 지원 주기: 3.5는 2026-06-30, 4.0은 2026-12-31에 OSS 지원이 끝나 폴백으로 쓰지 않는다.
- spring-boot#48573(→ #43550): com.querydsl 5.x의 알려진 기능 결함은 ScrollableResults 계열이다.

## 검증(W2 완료 기준)
- 더미 Batch Job을 실행하면 RDS/MySQL 8.4에 `BATCH_JOB_EXECUTION` 행이 생긴다.
- QueryDSL Q타입 생성과 빌드가 통과한다(Testcontainers MySQL 8.4, Hibernate 7.4.5).
