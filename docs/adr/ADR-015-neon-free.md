# ADR-015: 운영 DB는 Neon Free에 둔다

- 상태: 채택 (2026-10-01, 사용자 결정)
- 대체: ADR-014의 "DB 위치"(앱 EC2에 PostgreSQL 18 직접 설치)와 그에 딸린 운영 절차(DB-PLAN 5장)
- 유지: ADR-014의 저장·보관 결정(필요한 것만 저장, 2일 보관과 예외 4가지, `kma_forecast_hour`, S3 원문·collect-only 폐기, 적중률 스냅숏 C9)
- 관련: ADR-013(PostgreSQL 18), `docs/DB-PLAN.md` 11장(세부와 검증)

## 배경

- 9/30 비교 답변에서 사용자는 "1번으로 진행"이라고 답했다. 답변의 1절이 "Neon 같은 무료 DB를 써도 되는가"였다. 하지만 추천 목록의 ①(EC2 직접 설치)과 번호가 겹쳤고, 확인 없이 ①로 해석해 ADR-014를 구현했다. 10/1에 사용자가 Neon을 뜻했다고 확인했다.
- Neon Free 조건 [확실, neon.com 문서 2026-10-01 조회]
  - 프로젝트당 저장 0.5GB. 넘으면 쓰기가 실패하고, 데이터는 지워지지 않는다.
  - 프로젝트당 월 100 CU-시간. 넘으면 다음 달까지 컴퓨트가 정지한다.
  - 실행 중인 쿼리가 5분 동안 없으면 정지한다. Free에서는 바꿀 수 없다.
  - 월 전송 5GB, 즉시 복원(PITR) 6시간, 브랜치 10개
  - 서울·도쿄 리전은 없다. 가장 가까운 곳은 AWS ap-southeast-1(싱가포르)이다.
  - PostgreSQL 18은 2026-05-01부터 정식 지원한다.
  - 슈퍼유저가 없다. `ALTER SYSTEM`을 쓸 수 없다.
- 우리 DB는 보관을 줄여 수 MB 수준이다 [추정]. 앱은 DB를 읽지 않고, DB에 붙는 것은 하루 약 10번 짧게 도는 배치와 관리 화면뿐이다.

## 결정

1. 운영 DB는 Neon Free 프로젝트 하나로 한다.
   - PostgreSQL 18, 리전 AWS ap-southeast-1
   - 연결은 직접 엔드포인트(`-pooler`가 없는 호스트)와 TLS(`sslmode=require&channelBinding=require`)로 한다.
   - 컴퓨트 자동 확장 상한은 0.25 CU로 고정한다(콘솔 설정).
2. 연결 풀은 Neon이 쉬도록 둔다.
   - 최소 유휴 연결 0, 유휴 60초 뒤 닫기, keepalive 핑 끔
   - HikariCP 7 기본값은 2분마다 핑을 보내서 24시간 깨어 있게 만든다. 그러면 월 약 180 CU-시간이 된다 [추정].
   - `DataSourcePoolTest`가 이 설정을 지킨다.
3. 앱 역할은 SQL로 만든 `starindex`다. 슈퍼유저도 CREATEDB도 아니다.
   - Neon 관리 계정(`neondb_owner`)으로 `bootstrap-db.sh`를 한 번 실행해 만든다.
   - 비밀번호는 SSM SecureString에 두고 stdin으로만 넘긴다.
4. 백업은 매일 `pg_dump`로 S3 `backup/db/`에 올린다(7일).
   - Free의 복원 기간이 6시간뿐이라 이것이 실제 백업이다.
   - 05:15 예보 실행 직후인 05:20 KST에 돌려, 이미 깨어 있는 컴퓨트를 쓴다.
5. 복구 방법
   - 6시간 안이면 Neon 즉시 복원을 쓴다.
   - 그보다 오래됐으면 `restore.sh`로 운영 DB 옆의 새 DB에 복원하고, 확인한 뒤 `--switch`로 바꾼다. 운영 DB를 지우는 경로는 없다.
6. RDS 호환은 유지한다. Neon, RDS, 다른 PostgreSQL 18 사이의 이동은 `DB_URL`만 바꾼다. 과제 시연에 "RDS"가 필요하면 그 기간에만 RDS를 쓴다.
7. EC2(t4g.small, AL2023)에는 JVM과 Valkey만 돌린다.
   - `deploy/ec2/install.sh`는 PostgreSQL 18 클라이언트와 Valkey만 설치한다.
   - DB가 빠지면서 t4g.micro를 다시 검토할 수 있다. 무료 체험이 끝나는 12월에 실측으로 판단한다(DB-PLAN 11.6).

## 결과

- 비용: Neon 0원. 2027년부터 EC2 t4g.small 월 약 $21, t4g.micro 조건을 통과하면 월 약 $13이다 [추정].
- EC2에서 PostgreSQL 설치·튜닝·pg_hba·업데이트를 운영할 필요가 없다. EC2 메모리 실측(DB-PLAN 11.7): JVM 306MiB + Valkey 19MiB + OS·에이전트 270 = 595/1,600MiB, 대기 중 DB 연결 0.
- 위험과 대응

| 위험 | 대응 |
|---|---|
| Neon은 "중단 없는 가용성이 필요한 운영"에는 Free를 권하지 않는다 [확실] | 앱은 S3·CloudFront의 팩으로 동작하므로, DB가 멈춰도 마지막 팩으로 앱은 계속 동작한다. 그 사이의 새 발표만 수집되지 않는다. |
| 한도(CU-시간, 전송)를 넘기면 그달 말까지 DB 정지 | 첫 주에 Neon Usage를 매일 확인한다. 예상 사용량은 월 약 12 CU-시간이다 [추정]. 주기적으로 DB를 건드리는 것(`/actuator/health` 폴링 등)은 금지한다. |
| 무료 플랜의 상업적 이용 허용 여부 [불확실] | 출시 전에 Neon 약관과 AUP를 확인한다. 막혀 있으면 유료 플랜이나 대안으로 옮긴다(`DB_URL`만 교체). |
| 서울↔싱가포르 지연(미측정) | DB를 쓰는 것은 배치뿐이다. 첫 주 실행 시간을 기록한다. |

- 대안(되돌릴 때): EC2 직접 설치(ADR-014, 스크립트는 git 이력 db5aeb4·78c8ffa) 또는 RDS. 둘 다 `DB_URL`만 바꾸면 된다.
