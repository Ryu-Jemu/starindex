import Foundation
import Testing
import simd
@testable import SkyCore

/// T9 (Swift side): the pack produced by the Java catalog-builder decodes identically here.
@Suite("T9 skypack 교차 검증")
struct SkyPackTests {
    static var repoRoot: URL {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { u.deleteLastPathComponent() }   // Tests/SkyCoreTests/<file> → repo root
        return u
    }

    func load() throws -> (SkyCatalog, [String: Any]) {
        let packs = Self.repoRoot.appending(path: "data/packs")
        let catalog = try SkyPackDecoder.decode(Data(contentsOf: packs.appending(path: "skypack-v1.bin")))
        let qa = try JSONSerialization.jsonObject(with: Data(contentsOf: packs.appending(path: "skypack-v1.qa.json"))) as! [String: Any]
        return (catalog, qa)
    }

    @Test("Counts match the builder's QA report")
    func counts() throws {
        let (c, qa) = try load()
        #expect(c.version == 1)
        #expect(c.constellations.count == 88)
        #expect(c.stars.filter { !$0.isLineOnly }.count == qa["starsIncluded"] as? Int)
        #expect(c.stars.filter(\.isLineOnly).count == qa["lineOnlyPoints"] as? Int)
        #expect(c.segments.count == qa["segments"] as? Int)
        #expect(abs(c.epoch - 2026.5) < 1e-4)
        for s in c.segments { #expect(s.a < c.stars.count && s.b < c.stars.count && s.constellation < 88) }
    }

    @Test("Known stars and names")
    func knownStars() throws {
        let (c, _) = try load()
        #expect(c.stars.first?.name == "Sirius")
        let vega = try #require(c.stars.first { $0.hr == 7001 })
        #expect(abs(vega.magnitude - 0.03) < 1e-4)
        #expect(vega.name == "Vega")
        let ori = try #require(c.constellations.first { $0.abbr == "Ori" })
        #expect(ori.nameKo == "오리온자리")
        #expect(ori.nameLatin == "Orion")
        let polaris = try #require(c.stars.first { $0.hr == 424 })
        #expect(ConstellationLocator.locate(j2000: SIMD3<Double>(polaris.j2000)) == "UMi")
    }

    @Test("Stars are unit vectors; most label anchors fall inside their own constellation")
    func geometry() throws {
        let (c, _) = try load()
        for s in c.stars { #expect(abs(simd_length(s.j2000) - 1) < 1e-5) }
        let inside = c.constellations.filter { ConstellationLocator.locate(j2000: SIMD3<Double>($0.anchor)) == $0.abbr }
        #expect(inside.count >= 80, "anchors inside own boundary: \(inside.count)/88")
    }

    @Test("Corrupt input is rejected")
    func corrupt() {
        #expect(throws: SkyPackDecoder.DecodeError.badMagic) { try SkyPackDecoder.decode(Data("NOPE0000".utf8)) }
        #expect(throws: SkyPackDecoder.DecodeError.truncated) { try SkyPackDecoder.decode(Data("SKYP".utf8) + Data([1, 0])) }
    }
}
