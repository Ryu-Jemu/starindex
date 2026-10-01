import Foundation
import Testing
@testable import SkyCore

/// Golden files written by the backend (`contracts/golden`, see `PackPublisher`).
enum Golden {
    static var dir: URL { SkyPackTests.repoRoot.appending(path: "contracts/golden") }
    static func data(_ name: String) throws -> Data { try Data(contentsOf: dir.appending(path: name)) }
    static func gz() throws -> Data { try data("index-pack-v2.json.gz") }
    static func json() throws -> Data { try data("index-pack-v2.json") }
    static func manifest() throws -> PackManifest { try PackManifest.decode(data("manifest-v1.json")) }
    static func pack() throws -> IndexPack { try IndexPack.decode(json: json()) }
}

/// 2026-10-12T21:00+09:00 style KST instant.
func kst(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0, _ s: Int = 0) -> Date {
    KST.calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
}

@Suite("W3 지수 팩 계약(골든)")
struct IndexPackGoldenTests {
    @Test("gunzip(golden .gz) == golden JSON bytes")
    func gunzipMatchesJSON() throws {
        #expect(try Gzip.decompress(Golden.gz()) == Golden.json())
    }

    @Test("SHA-256 and size of the compressed bytes match the manifest entry")
    func shaMatchesManifest() throws {
        let entry = try #require(try Golden.manifest().packs.index)
        let gz = try Golden.gz()
        #expect(IndexPackDecoder.sha256Hex(gz) == entry.sha256)
        #expect(entry.bytes == gz.count)
        try IndexPackDecoder.verify(gz, against: entry)
    }

    @Test("Manifest fields")
    func manifest() throws {
        let m = try Golden.manifest()
        #expect(m.schema == 1)
        let e = try #require(m.packs.index)
        #expect(e.version == "20261012-1700-2b636870")
        #expect(e.path == "packs/index/20261012-1700-2b636870/index.json.gz")
        #expect(e.nightDate == "2026-10-12")
        #expect(IndexPackDecoder.isSafeRelativePath(e.path))
        #expect(m.generatedDate == kst(2026, 10, 12, 17, 21, 4))
        #expect(e.issuedAt.flatMap(PackTime.parse) == kst(2026, 10, 12, 17))
    }

    @Test("verify → gunzip → decode: all 17 regions")
    func decodeAll() throws {
        let entry = try #require(try Golden.manifest().packs.index)
        let pack = try IndexPackDecoder.decode(gzipped: Golden.gz(), entry: entry)
        #expect(pack.schema == 2)
        #expect(pack.kind == "index")
        #expect(pack.version == entry.version)
        #expect(pack.night == NightDate(year: 2026, month: 10, day: 12))
        #expect(pack.issuedDate == kst(2026, 10, 12, 17))
        #expect(pack.hourlyStep == 1)
        #expect(pack.attribution.count == 3)
        #expect(pack.regions.count == 17)
        #expect(Set(pack.regions.map(\.id)).count == 17)
        for r in pack.regions {
            #expect(r.gridCell != nil, "\(r.name)")
            #expect(r.score.map { (0...100).contains($0) } ?? true)
            #expect(r.hourly?.sky?.count == 72, "\(r.name)")
            #expect(r.twilight?.computed?.sunset != nil)
        }
        let seoul = try #require(pack.regions.first { $0.id == "1100000000" })
        #expect(seoul.name == "서울" && seoul.kind == "SIDO")
        #expect(seoul.gridCell! == (60, 127))
        #expect(seoul.score == 50 && seoul.grade == "FAIR")
        #expect(seoul.best == ["2000", "2200"])
        #expect(seoul.reasons == ["CLOUD_MOSTLY", "MOON_NONE"])
        #expect(seoul.contrib?["cloud"] == 1.0)
        #expect(seoul.twilight?.kasi == nil)
        // Rounded to the nearest minute since ADR-019 (KASI's convention); before, seconds were truncated.
        #expect(seoul.twilight?.computed == .init(sunset: "1800", civile: "1826", naute: "1856", aste: "1927",
                                                  astm: "0511", sunrise: "0638"))
        #expect(seoul.hourly?.t0 == "2026-10-12T12:00+09:00")
        #expect(seoul.hourly?.sky?[0] == nil && seoul.hourly?.sky?[6] == 3)
        #expect(seoul.hourly?.tmp?[6] == 14.0 && seoul.hourly?.wsd?[6] == 1.8)
    }

    @Test("Tampered bytes or a wrong manifest entry are rejected before inflating")
    func integrity() throws {
        let entry = try #require(try Golden.manifest().packs.index)
        var gz = try Golden.gz()
        gz[gz.count / 2] ^= 0x01
        #expect(throws: IndexPackDecoder.Failure.shaMismatch) { try IndexPackDecoder.decode(gzipped: gz, entry: entry) }
        var short = entry
        short.bytes = 10
        #expect(throws: IndexPackDecoder.Failure.sizeMismatch(expected: 10, actual: try Golden.gz().count)) {
            try IndexPackDecoder.decode(gzipped: Golden.gz(), entry: short)
        }
        var otherVersion = entry
        otherVersion.version = "20261012-2000-00000000"
        #expect(throws: IndexPackDecoder.Failure.self) { try IndexPackDecoder.decode(gzipped: Golden.gz(), entry: otherVersion) }
    }

    @Test("Manifest paths must stay relative to the CDN root")
    func safePaths() {
        for ok in ["packs/index/20261012-1700-b2a3bf8b/index.json.gz", "a/b.c"] { #expect(IndexPackDecoder.isSafeRelativePath(ok)) }
        for bad in ["", "/packs/x.gz", "../x", "packs/../../x", "https://evil.example/x", "packs//x", "packs/x?y=1",
                    "packs/./x", "packs/%2e%2e/x"] {
            #expect(!IndexPackDecoder.isSafeRelativePath(bad), "\(bad)")
        }
    }

    @Test("Tolerant decoding: unknown fields ignored, producer nulls accepted")
    func tolerant() throws {
        let json = """
        {"schema":3,"kind":"index","version":"v","nightDate":"2026-10-12","issuedAt":null,"future":{"x":1},
         "regions":[{"id":"1","name":"가","kind":"NEW_KIND","grid":[1,2],"score":null,"grade":null,"best":null,
                     "reasons":["NO_FORECAST","SOMETHING_NEW"],"contrib":null,
                     "twilight":{"kasi":{"sunset":"1801","civile":null,"naute":null,"aste":null},
                                 "computed":{"sunset":"1759","civile":"1825","naute":null,"aste":null,"astm":null,"sunrise":"0637"}},
                     "extra":[1,2,3]},
                    {"id":"2","name":"나"}]}
        """
        let p = try IndexPack.decode(json: Data(json.utf8))
        #expect(p.attribution.isEmpty && p.issuedDate == nil && p.regions.count == 2)
        let r = p.regions[0]
        #expect(r.score == nil && r.best == nil && r.hourly == nil)
        #expect(p.regions[1].reasons.isEmpty && p.regions[1].gridCell == nil)
        let s = IndexSummary.make(pack: p, region: r, basis: .nearest, generatedAt: nil, now: kst(2026, 10, 12, 21))
        #expect(s.reasons == ["예보 없음"])        // unknown code hidden
        #expect(s.chipText == "오늘 밤 예보 없음")
        #expect(s.twilight.map(\.label) == ["일몰", "시민박명 끝", "일출"])
        #expect(s.twilight[0] == .init(label: "일몰", time: "18:01", source: .kasi))
        #expect(s.twilight[1].source == .computed && s.twilight[1].sourceLabel == "(계산)")
        #expect(s.twilight[0].sourceLabel == "(천문연)")
    }
}

@Suite("W3 gzip 디코더")
struct GzipTests {
    static func parts() throws -> (deflate: [UInt8], trailer: [UInt8]) {
        let b = [UInt8](try Golden.gz())
        #expect(Array(b[0..<4]) == [0x1F, 0x8B, 8, 0])     // the golden file has the plain 10-byte header
        return (Array(b[10..<(b.count - 8)]), Array(b.suffix(8)))
    }

    @Test("Optional header fields FEXTRA, FNAME, FCOMMENT and FHCRC are skipped and checked")
    func optionalHeaderFields() throws {
        let (deflate, trailer) = try Self.parts()
        var header: [UInt8] = [0x1F, 0x8B, 8, 0x02 | 0x04 | 0x08 | 0x10, 1, 2, 3, 4, 0, 3]
        header += [5, 0] + [0x41, 0x42, 2, 0, 0x7A]           // XLEN 5: subfield "AB", length 2, then 1 extra byte
        header += Array("index.json".utf8) + [0]
        header += Array("별 지수 팩".utf8) + [0]
        let crc16 = UInt16(truncatingIfNeeded: CRC32.checksum(header))
        let good = header + [UInt8(crc16 & 0xFF), UInt8(crc16 >> 8)] + deflate + trailer
        #expect(try Gzip.decompress(Data(good)) == Golden.json())

        let badHCRC = header + [UInt8(crc16 & 0xFF) ^ 0xFF, UInt8(crc16 >> 8)] + deflate + trailer
        #expect(throws: Gzip.DecodeError.headerCRCMismatch) { try Gzip.decompress(Data(badHCRC)) }
    }

    @Test("CRC32 check value")
    func crc32() {
        #expect(CRC32.checksum(Array("123456789".utf8)) == 0xCBF4_3926)
        #expect(CRC32.checksum([UInt8]()) == 0)
    }

    @Test("Corrupted input fails")
    func corrupted() throws {
        let gz = [UInt8](try Golden.gz())
        func fails(_ bytes: [UInt8], _ expected: Gzip.DecodeError? = nil, _ note: Comment) {
            do {
                _ = try Gzip.decompress(Data(bytes))
                Issue.record("decoded corrupt input: \(note)")
            } catch let e as Gzip.DecodeError {
                if let expected { #expect(e == expected, note) }
            } catch {
                Issue.record("unexpected error \(error)")
            }
        }
        fails([0x50, 0x4B, 3, 4] + gz.dropFirst(4), .badMagic, "zip magic")
        fails(Array("{\"schema\":2}".utf8), .badMagic, "plain JSON (e.g. a proxy already decoded it)")
        fails([0x1F, 0x8B, 7] + gz.dropFirst(3), .unsupportedMethod(7), "method 7")
        fails([0x1F, 0x8B, 8, 0x20] + gz.dropFirst(4), .reservedFlags, "reserved flag bit")
        fails([0x1F, 0x8B, 8], .truncated, "header cut")
        fails([], .truncated, "empty")
        fails(Array(gz.dropLast(4)), nil, "trailer cut")
        fails(Array(gz.dropLast(300)), nil, "DEFLATE cut")
        var crc = gz
        crc[crc.count - 8] ^= 0xFF
        fails(crc, .crcMismatch, "CRC32 flipped")
        var size = gz
        size[size.count - 1] ^= 0x01
        fails(size, .sizeMismatch, "ISIZE flipped")
        var payload = gz
        payload[200] ^= 0x5A
        fails(payload, nil, "DEFLATE byte flipped")
        let hi: [UInt8] = [31, 139, 8, 0, 0, 0, 0, 0, 2, 19, 203, 200, 4, 0, 172, 42, 147, 216, 2, 0, 0, 0]   // gzip("hi")
        #expect(try Gzip.decompress(Data(hi)) == Data("hi".utf8))
        fails(gz + hi, nil, "second member (unsupported → must not return only the first)")
        fails(hi + gz, nil, "second member after a short one")
        fails(gz + [0, 0, 0, 0], nil, "junk after trailer")
        #expect(throws: Gzip.DecodeError.tooLarge) { try Gzip.decompress(Data(gz), maxOutputBytes: 1000) }
        // Known limit (documented in Gzip): the same member twice ends with a trailer that matches the first
        // member, so it decodes as ONE copy where RFC 1952 would give two. Harmless here: the bytes were
        // sha256-verified against the manifest before inflating, and the producer writes one member.
        #expect(try Gzip.decompress(Data(gz + gz)) == Golden.json())
    }
}

@Suite("W3 지역 선택(기기 안)")
struct RegionLocatorTests {
    @Test("Seoul City Hall → 서울, Busan → 부산")
    func knownCities() throws {
        let p = try Golden.pack()
        #expect(RegionLocator.nearest(p.regions, latitude: 37.5665, longitude: 126.9780)?.id == "1100000000")
        #expect(RegionLocator.nearest(p.regions, latitude: 35.1796, longitude: 129.0756)?.id == "2600000000")
    }

    @Test("Remote Korean islands are covered; foreign or far points → nil")
    func bounds() throws {
        let p = try Golden.pack()
        #expect(RegionLocator.nearest(p.regions, latitude: 37.2426, longitude: 131.8669)?.name == "울산")   // Dokdo, 57.3 cells
        #expect(RegionLocator.nearest(p.regions, latitude: 37.9667, longitude: 124.6667)?.name == "인천")   // Baengnyeongdo
        #expect(RegionLocator.nearest(p.regions, latitude: 33.1167, longitude: 126.2667)?.name == "제주")   // Marado
        #expect(RegionLocator.nearest(p.regions, latitude: 37.32, longitude: -122.03) == nil)              // Cupertino
        #expect(RegionLocator.nearest(p.regions, latitude: 36.07, longitude: 120.38) == nil)               // Qingdao (off grid)
        #expect(RegionLocator.nearest(p.regions, latitude: 41.8, longitude: 129.78) == nil)                // Chongjin, 90.5 cells
        #expect(RegionLocator.nearest(p.regions, latitude: .nan, longitude: 127) == nil)
    }

    @Test("Ties go to the lower id; regions without a grid are skipped")
    func ties() {
        let regions = [IndexRegion(id: "30", name: "c", grid: [12, 10]), IndexRegion(id: "4", name: "b", grid: [8, 10]),
                       IndexRegion(id: "100", name: "a", grid: [10, 12]), IndexRegion(id: "1", name: "x")]
        #expect(RegionLocator.nearest(regions, nx: 10, ny: 10)?.id == "4")     // numeric, not lexicographic ("100" < "30" < "4")
        #expect(RegionLocator.nearest(regions, nx: 10, ny: 10, maxDistance: 1.9) == nil)
        #expect(RegionLocator.nearest([], nx: 10, ny: 10) == nil)
    }
}

@Suite("W3 밤 날짜·칩 문구")
struct IndexSummaryTests {
    @Test("Night date = KST date of the preceding 12:00 (backend nightDateOf)")
    func nightDate() {
        let d = NightDate(year: 2026, month: 10, day: 12)
        #expect(NightDate.of(kst(2026, 10, 13, 3)) == d)          // 03:00 next morning → still the 12th's night
        #expect(NightDate.of(kst(2026, 10, 12, 18)) == d)
        #expect(NightDate.of(kst(2026, 10, 12, 6)) == d)          // 06:00 exactly starts the new night (ADR-018)
        #expect(NightDate.of(kst(2026, 10, 12, 5, 59, 59)) == NightDate(year: 2026, month: 10, day: 11))
        #expect(NightDate.of(kst(2026, 10, 12, 9)) == d)          // morning: "tonight" is already the coming night
        #expect(NightDate.of(kst(2027, 1, 1, 5)) == NightDate(year: 2026, month: 12, day: 31))   // across New Year
        #expect(NightDate.of(utc("2026-10-12T15:30:00Z")) == d)  // = 00:30 KST on the 13th, any device time zone
        #expect(d.description == "2026-10-12" && NightDate("2026-10-12") == d && d.label == "10/12(월)")
        #expect(NightDate("2026-1-12") == nil && NightDate("x") == nil)
    }

    @Test("Pack timestamps with and without seconds, fractions, Z")
    func packTime() {
        #expect(PackTime.parse("2026-10-12T17:00+09:00") == kst(2026, 10, 12, 17))
        #expect(PackTime.parse("2026-10-12T17:21:04+09:00") == kst(2026, 10, 12, 17, 21, 4))
        #expect(PackTime.parse("2026-10-12T08:21:04.5Z") == kst(2026, 10, 12, 17, 21, 4).addingTimeInterval(0.5))
        #expect(PackTime.parse("2026-10-12T17:00-01:30") == utc("2026-10-12T18:30:00Z"))
        for bad in ["", "2026-10-12", "2026-10-12T17:00", "2026-10-12T17:00+0900", "2026-13-12T17:00Z", "2026-10-12T17:00Zx"] {
            #expect(PackTime.parse(bad) == nil, "\(bad)")
        }
    }

    @Test("Tonight: '오늘 밤 50 · 보통 · 17시 발표', best window, reasons, verdict")
    func tonight() throws {
        let p = try Golden.pack()
        let gen = try Golden.manifest().generatedDate
        let s = try #require(IndexSummary.make(pack: p, observer: (37.5665, 126.9780), generatedAt: gen, now: kst(2026, 10, 12, 21)))
        #expect(s.regionName == "서울" && s.basis == .nearest && s.isTonight && !s.isStale)
        #expect(s.chipText == "오늘 밤 50 · 보통 · 17시 발표")
        #expect(s.chipNote == nil)
        #expect(s.bestWindow == "20:00–22:00")
        #expect(s.reasons == ["구름많음", "달빛 영향 없음"])
        #expect(s.verdict == "밝은 별 위주로 보여요")
        #expect(s.issueDateLabel == "10/12 17시 발표")
        #expect(s.twilight.map(\.time) == ["18:00", "18:26", "18:56", "19:27", "05:11", "06:38"])
        #expect(s.twilight.allSatisfy { $0.sourceLabel == "(계산)" })
        #expect(s.attribution.first?.contains("기상청") == true)

        // After midnight it is still "tonight".
        let late = try #require(IndexSummary.make(pack: p, observer: (35.1796, 129.0756), generatedAt: gen, now: kst(2026, 10, 13, 2)))
        #expect(late.regionName == "부산" && late.isTonight)
        let daegu = try #require(p.regions.first { $0.name == "대구" })
        let d = IndexSummary.make(pack: p, region: daegu, basis: .nearest, generatedAt: gen, now: kst(2026, 10, 12, 21))
        #expect(d.chipText == "오늘 밤 100 · 매우 좋음 · 17시 발표" && d.verdict == "아주 좋은 밤이에요")
    }

    @Test("Stored / older night: '저장된 예보 · 10/12 17시 발표'")
    func storedNight() throws {
        let p = try Golden.pack()
        let s = try #require(IndexSummary.make(pack: p, observer: nil, generatedAt: nil, now: kst(2026, 10, 14, 21)))
        #expect(!s.isTonight && s.basis == .defaultLocation && s.regionName == "서울")
        #expect(s.chipText == "저장된 예보 · 10/12 17시 발표 · 50 보통")
    }

    @Test("Stale after 6 h of manifest age; outside Korea → Seoul with a note")
    func staleAndAbroad() throws {
        let p = try Golden.pack()
        let gen = kst(2026, 10, 12, 17, 21, 4)
        let fresh = try #require(IndexSummary.make(pack: p, observer: nil, generatedAt: gen, now: kst(2026, 10, 12, 23, 21)))
        #expect(!fresh.isStale && fresh.staleLabel == nil)
        let stale = try #require(IndexSummary.make(pack: p, observer: nil, generatedAt: gen, now: kst(2026, 10, 13, 1, 30)))
        #expect(stale.isStale && stale.staleLabel == "8시간 전 발표 기준" && stale.isTonight)

        let abroad = try #require(IndexSummary.make(pack: p, observer: (37.32, -122.03), generatedAt: gen, now: kst(2026, 10, 12, 21)))
        #expect(abroad.basis == .outsideKorea && abroad.regionName == "서울")
        #expect(abroad.chipNote == "한국 밖 · 서울 기준")
    }

    @Test("Every reason code the backend emits has a phrase; grades follow StarIndexCalculator")
    func reasonsAndGrades() {
        // StarIndexCalculator.reasons + PackPublisher (NO_FORECAST).
        for code in ["PRECIP", "CLOUD_CLEAR", "CLOUD_MOSTLY", "CLOUD_OVERCAST", "MOON_NONE", "MOON_SOME", "MOON_BRIGHT", "NO_FORECAST"] {
            #expect(IndexReason.phrase(code) != nil, "\(code)")
        }
        #expect(IndexReason.phrase("SOMETHING_NEW") == nil)
        let cases: [(Int, IndexGrade)] = [(0, .poor), (39, .poor), (40, .fair), (59, .fair), (60, .good), (79, .good), (80, .excellent), (100, .excellent)]
        for (score, g) in cases { #expect(IndexGrade.from(score: score) == g, "\(score)") }
        #expect(IndexGrade.allCases.map(\.text) == ["어려움", "보통", "좋음", "매우 좋음"])
    }

    @Test("SERVICE-PLAN 4.5 verdicts: precipitation, all-overcast window, score bands")
    func verdicts() throws {
        let p = try Golden.pack()
        var r = try #require(p.regions.first { $0.id == "1100000000" })
        // Best window 20:00–22:00 = slots 8, 9 from t0 12:00.
        #expect(IndexSummary.bestWindowSlots(region: r, pack: p) == [8, 9])
        r.best = ["2300", "0100"]
        #expect(IndexSummary.bestWindowSlots(region: r, pack: p) == [11, 12])
        r.best = ["0400", "0600"]                     // after midnight → the morning after the night date
        #expect(IndexSummary.bestWindowSlots(region: r, pack: p) == [16, 17])
        #expect(IndexSummary.verdict(region: r, pack: p) == "오늘 밤은 어려워요")   // SKY 4, 4 although score is 50

        r.best = ["2000", "2200"]
        r.reasons = ["PRECIP", "CLOUD_CLEAR", "MOON_NONE"]
        #expect(IndexSummary.verdict(region: r, pack: p) == "관측 불가 · 비(또는 눈)")
        let s = IndexSummary.make(pack: p, region: r, basis: .nearest, generatedAt: nil, now: kst(2026, 10, 12, 21))
        #expect(s.gradeText == "관측 불가")
        r.reasons = ["CLOUD_CLEAR", "MOON_NONE"]
        for (score, text) in [(39, "오늘 밤은 어려워요"), (40, "밝은 별 위주로 보여요"), (60, "나가 볼 만해요"), (80, "아주 좋은 밤이에요")] {
            r.score = score
            #expect(IndexSummary.verdict(region: r, pack: p) == text, "\(score)")
        }
        r.score = nil
        #expect(IndexSummary.verdict(region: r, pack: p) == "예보가 없어요")
    }

    @Test("KST clock labels")
    func labels() {
        #expect(KST.hourLabel(kst(2026, 10, 12, 17)) == "17시")
        #expect(KST.hourLabel(kst(2026, 10, 12, 5, 30)) == "5:30")
        #expect(KST.displayHHmm("0511") == "05:11" && KST.displayHHmm("2460") == nil && KST.displayHHmm(nil) == nil)
        #expect(KST.timeRelative(kst(2026, 10, 13, 5, 57), now: kst(2026, 10, 12, 21)) == "내일 05:57")
        #expect(KST.timeRelative(kst(2026, 10, 12, 23, 50), now: kst(2026, 10, 12, 21)) == "23:50")
    }
}
