# ADR-013: 데이터베이스를 MySQL 8.4에서 PostgreSQL 18로 바꾼다

- 상태: 채택 (2026-09-30, 사용자 결정)
- 대체: PLAN rev4의 "RDS MySQL 8.4"(3.4, 3.6), ADR-004의 flyway-mysql·mysql-connector-j

## 배경

사용자가 ETL 데이터베이스를 PostgreSQL로 구축하라고 지시했다. 과제 이미지의 고정 스택에는 "RDS MySQL"이 적혀 있다. RDS(관리형 DB)를 쓰는 것은 같지만 엔진이 바뀐다. 평가 기준이 MySQL 엔진을 명시한다면 사용자가 확인해야 한다.

## 결정

- 엔진: **PostgreSQL 18** (로컬 `postgres:18`, 운영 RDS for PostgreSQL 18)
- 드라이버와 마이그레이션: `org.postgresql:postgresql`(Boot 4.1.1이 관리하는 42.7.13), `flyway-database-postgresql`(Flyway 12.4.0)
- 테스트: Testcontainers `testcontainers-postgresql` 2.0.5, 클래스 `org.testcontainers.postgresql.PostgreSQLContainer`
- 스키마
  - V1: Spring Batch 6.0.5 `schema-postgresql.sql` 원문
  - V2: 지역
  - V3: ETL 테이블. TIMESTAMPTZ, JSONB, `INSERT … ON CONFLICT` upsert를 쓴다.
- 로컬 포트: 15432. 사용자의 다른 PostgreSQL·Redis와 겹치지 않게 했다.

## 근거

| 항목 | 내용 | 확신도 |
|---|---|---|
| RDS 지원 기간 | PG 18: RDS 출시 2025-11-14, 표준 지원 2031-02-28. PG 17: 2030-02-28. MySQL 8.0 같은 Extended Support 과금 위험이 수년간 없다. | [확실, AWS RDS 버전 캘린더 2026-09-30 조회] |
| 비용 | db.t4g.micro Single-AZ 서울 요금은 PostgreSQL과 MySQL 모두 $0.025/h로 같다. | [확실, AWS 가격 JSON 2026-09-29] |
| 기능 | 예보 upsert(`ON CONFLICT`), 최신 발표값 조회(`DISTINCT ON`), 기여도 JSONB | [확실, 구현·테스트] |

## 결과

- PLAN rev4의 비용 표(3.6)는 엔진 이름만 바뀌고 금액은 그대로다.
- W3 인프라 작업은 RDS for PostgreSQL 18로 만든다(파라미터 그룹 `postgres18`).
- QueryDSL, JPA(Hibernate 7), Spring Batch는 그대로 쓴다. BackendSmokeTest가 PostgreSQL 18에서 통과한다.
- 되돌리려면 V1~V3의 PostgreSQL 전용 문법(TIMESTAMPTZ, JSONB, DISTINCT ON, ON CONFLICT)을 MySQL용으로 다시 써야 한다.
