# 비용 기록

목표: 월별 실측이 `docs/PLAN.md` 3.6 추정의 120%를 넘지 않는다. 금액은 부가세 별도 USD다.

| 월 | 단계 | 추정 | 실측(Billing) | 비고 |
|---|---|---|---|---|
| 2026-10 | M0 | 8~12 |  | EC2 T4g 무료 체험, RDS는 W3 시연 기간에만(이후 스냅숏 뒤 삭제) |
| 2026-11~12 | R1~R3 | 약 6/월 |  | DB는 Neon Free(0원, ADR-015), RDS 없음 |
| 2027-01~ | 운영 | 약 21/월(small) 또는 약 13/월(micro) |  | EC2 + EBS + IPv4. micro는 DB-PLAN 11.6 조건 통과 시 |

## 체크리스트(W3)
- [ ] `aws ec2 describe-instance-credit-specifications` = standard
- [ ] (시연에 RDS를 쓰는 경우) RDS for PostgreSQL **18**, db.t4g.micro, Single-AZ, Performance Insights off, 퍼블릭 액세스 off. 시연 뒤 최종 스냅숏 → 삭제(DB-PLAN 11.9)
- [x] Neon 프로젝트(PG 18, 싱가포르, 10-01 생성·실검증)
- [ ] Neon: `bootstrap-db.sh` 완료, 백업 타이머 켜짐, 복구 리허설 1회(DB-PLAN 11.3, 11.5)
- [ ] Neon Usage: 첫 주 매일 CU-시간 확인(예상 월 약 12, 한도 100)
- [ ] NAT Gateway 0, Elastic IP 1
- [ ] Budgets 월 30 USD(50/80/100% 알림)
