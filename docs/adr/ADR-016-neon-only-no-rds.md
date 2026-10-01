# ADR-016: DB는 Neon Free만 쓴다 (RDS는 시연에도 쓰지 않는다)

- 상태: 채택 (2026-10-01, 사용자 결정)
- 대체: ADR-015 결정 6의 "과제 시연에 RDS가 필요하면 그 기간에만 RDS를 쓴다", PLAN 3.6의 RDS 행과 M0 비용의 RDS 몫, DB-PLAN 11.9(RDS → Neon 전환)
- 유지: ADR-015의 나머지 전부(Neon Free, 연결 풀, 백업, 복구), "DB_URL만 바꾸면 다른 PostgreSQL 18로 옮길 수 있다"는 기술 조건

## 배경

- 10/1 사용자 지시: "저장소는 외부 Neon을 사용하여 무과금으로 사용한다." 같은 날 Neon 콘솔에 `star_index`(Free, 싱가포르, production 브랜치)가 등록된 화면을 공유했다.
- "저장소"가 DB만인지, 앱 팩 파일(S3)까지인지 확인했다. 사용자는 **A안(DB만 Neon)**을 골랐다. 앱 팩·배포 번들·백업은 S3와 CloudFront에 그대로 둔다(B안 Neon Object Storage는 채택하지 않음).
- 과제 이미지의 고정 스택에는 "RDS"가 적혀 있다. ADR-013부터 엔진은 PostgreSQL 18로 바뀌었고, 이번 결정으로 RDS 인스턴스 자체도 만들지 않는다.

## 결정

1. 운영 DB와 시연 DB 모두 Neon Free(`star_index`, PostgreSQL 18, aws-ap-southeast-1)다. RDS 인스턴스는 어느 단계에서도 만들지 않는다.
2. S3는 DB 용도가 아니다. 앱 팩(`packs/`), CodeDeploy 번들(`deploy/backend/`), 매일 `pg_dump`(`backup/db/`)만 둔다.
3. 배포 정의(`deploy/aws/starindex.yaml`)와 프로비저닝 스크립트에는 RDS 자원이 없다.

## 결과

- 비용: DB 0원. M0 예상 비용에서 RDS 몫(약 216시간 ≈ 5.4 USD)이 빠진다.
- 위험: 평가 기준이 "RDS 인스턴스"를 요구하면 감점될 수 있다 [불확실]. 발표에서는 "관리형 PostgreSQL 18(Neon, AWS 싱가포르 리전에서 동작)"으로 설명하고, `DB_URL`만 바꾸면 RDS for PostgreSQL 18로 옮길 수 있다는 점(마이그레이션은 슈퍼유저 아닌 소유자로 실행, DB-PLAN 6.1 테스트)을 보여 준다. 실제로 옮길지는 사용자가 다시 결정한다.
