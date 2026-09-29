# skypack v1 바이너리 형식

`backend/tools/catalog-builder`(Java)가 만들고, `SkyCore.SkyPackDecoder`(Swift)가 읽는다. 모든 값은 little-endian이다.

| 구역 | 크기 | 필드 |
|---|---|---|
| 헤더 | 32 B | `"SKYP"` · u16 version(=1) · u16 flags · f32 epoch · f32 magLimit · u32 starCount · u32 constellationCount · u32 segmentCount · u32 stringCount |
| 별 × starCount | 24 B | f32 x, y, z(epoch 기준 J2000 단위벡터, 고유운동 반영) · i16 mag×100 · u8 bvIndex · u8 flags · u16 HR · u16 reserved · i32 nameIdx(−1 = 없음) |
| 별자리 × constellationCount | 24 B | 4 B IAU 약자(ASCII, NUL 채움) · i32 nameKoIdx · i32 nameLatinIdx · f32 라벨 앵커 x, y, z |
| 선분 × segmentCount | 8 B | u16 constellationIdx · u16 reserved · u16 starA · u16 starB |
| 문자열 × stringCount | 가변 | u16 byteLength · UTF-8 bytes |

- `bvIndex`: B−V를 [−0.4, 2.0] 구간에서 0…255로 매핑한다. 값이 없으면 0.6으로 둔다.
- `flags`: bit0 = 선 전용 점(별로 그리지 않음), bit1 = 고유명 있음.
- 별은 밝은 순서로 정렬한다. 선에 쓰이는 별은 등급 한계를 넘어도 포함한다.

## v1 산출물 (2026-09-29, `--mag 5.5 --epoch 2026.5`)

`data/packs/skypack-v1.qa.json` 기준이다.

- 원본 9,110행 중 위치가 없는 14행은 제외했다.
- 별 2,893개: 5.5등 이하 2,887개와 선에만 쓰이는 별 6개다.
- 별자리 88개, 선분 743개
- 선 꼭짓점 893/893개가 모두 1′ 이내로 매칭됐다(최대 9.1″). 선 전용 점은 0개다.
- IAU 고유명 324개, 한글 별자리명 88개(검수 전)
- 크기 82,747 B, sha256 `d478a1ae…abbb97`
