# 카탈로그 원본 데이터

2026-09-29에 받은 파일이다. `backend/tools/catalog-builder`가 이 폴더만 읽어서 `data/packs/skypack-v1.bin`을 만든다. 네트워크 없이 다시 만들 수 있다.

| 파일 | 출처 | 라이선스 / 조건 |
|---|---|---|
| `heasarc_bsc5p.tdat.gz` | NASA HEASARC `bsc5p`(Yale Bright Star Catalog 5th Revised Ed., Preliminary), https://heasarc.gsfc.nasa.gov/FTP/heasarc/dbase/tdat_files/heasarc_bsc5p.tdat.gz (9,110행, 최종 수정 2022-02-03) | data.gov 메타데이터상 미국 정부 저작물(https://www.usa.gov/government-works) |
| `d3-constellations.lines.json` | d3-celestial `data/constellations.lines.json`, 커밋 `7e720a3de062059d4c5400a379146a601d9010e0` | BSD-3-Clause(`d3-celestial.LICENSE`). 별자리 선은 IAU·Sky & Telescope 도판 기반이다 |
| `d3-constellations.json` | d3-celestial `data/constellations.json`, 같은 커밋 | BSD-3-Clause. `ko` 필드는 Wikipedia 번역에서 왔으므로 R1에서 한국천문학회 천문학용어집과 대조해 검수한다 |
| `d3-celestial.LICENSE` | 위 저장소 | BSD-3-Clause 원문 |
| `IAU-CSN.txt` | IAU WGSN, https://www.pas.rochester.edu/~emamajek/WGSN/IAU-CSN.txt (2022-04-04판) | IAU 산출물로 CC BY, 출처 표시가 필요하다. 이후 승인된 이름은 exopla.net과 대조한다 |

쓰지 않는 것: HYG(CC BY-SA), Hipparcos·Tycho·Gaia 원본(CC BY-NC 3.0 IGO), d3 `stars.*.json`·`dsos.*.json`(XHIP 파생), Stellarium 데이터(GPL, CC BY-SA).
