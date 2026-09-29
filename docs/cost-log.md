# 비용 기록

목표: 월별 실측이 `docs/PLAN.md` 3.6 추정의 120%를 넘지 않는다. 금액은 부가세 별도 USD다.

| 월 | 단계 | 추정 | 실측(Billing) | 비고 |
|---|---|---|---|---|
| 2026-10 | M0 | 8~12 |  | EC2 T4g 무료 체험, RDS는 W3에만 |

## 체크리스트(W3)
- [ ] `aws ec2 describe-instance-credit-specifications` = standard
- [ ] RDS: MySQL **8.4**, Single-AZ, Performance Insights off, 퍼블릭 액세스 off
- [ ] NAT Gateway 0, Elastic IP 1
- [ ] Budgets 월 30 USD(50/80/100% 알림)
