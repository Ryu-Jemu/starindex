# 비용 기록

목표: **0원**(ADR-017, 2026-10-01 사용자 결정 "무과금"). GitHub와 Neon 모두 결제 수단이 없으면 무료 한도를 넘어도 과금하지 않고 멈춘다. 그래서 확인할 것은 금액이 아니라 한도 사용량이다.

| 월 | 단계 | 추정 | 실측 | 비고 |
|---|---|---|---|---|
| 2026-10 | M0 | 0 |  | GitHub Actions(ETL 약 600분 + CI, 한도 2,000분), Neon Free(DB·Object Storage). AWS 자원 0 |
| 2026-11~ | R1~ | 0 |  | 같은 구성 |

## 체크리스트(W3)
- [ ] AWS 자원 0개(ADR-017), RDS 0개(ADR-016)
- [x] Neon 프로젝트(PG 18, 싱가포르, 10-01 생성·실검증)
- [ ] Neon: `ops/neon/bootstrap.sh --github --save-local` 완료, 공개 버킷 `starindex-packs`, 저장소 자격 증명
- [ ] GitHub: 시크릿 5개(`DB_URL`, `DB_PASSWORD`, `DATA_GO_KR_SERVICE_KEY`, `NEON_STORAGE_KEY_ID`, `NEON_STORAGE_SECRET`), 변수 4개(`PACK_BUCKET`, `PACK_S3_ENDPOINT`, `PACK_S3_REGION`, `PACK_PUBLIC_URL`)
- [ ] 첫 주 매일: Actions 사용 분(Settings → Billing), Neon Usage(CU-시간 예상 월 약 7·한도 100, 전송량 한도 5GB)
- [ ] 복원 리허설 1회(`ops/neon/restore.sh`로 새 DB)
- [ ] 결제 수단을 등록하지 않은 상태 유지(GitHub, Neon): 한도 초과 시 과금 대신 정지
