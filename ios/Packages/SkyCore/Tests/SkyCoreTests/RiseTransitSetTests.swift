import Foundation
import Testing
@testable import SkyCore

/// M0-a '뜸·남중·짐'. Expected instants come from the JVM build of the same Astronomy Engine release
/// (backend/libs/astronomy-2.1.19.jar: `searchRiseSet(body, obs, dir, start, 1.0, 0.0)` and
/// `searchHourAngle(body, obs, 0.0, start, +1)`), run 2026-10-01 for Seoul (37.5665, 126.9780, 38 m) from
/// 2026-10-12 12:00 KST. Two implementations of one algorithm; the AE search tolerance is 0.1 s, so 2 s is generous.
///
/// Fixed stars differ by more, for a known reason: the JVM build ignores aberration for user-defined stars
/// (`equator(Star1, …, Aberration.Corrected)` == `Aberration.None`, checked 2026-10-01) while the C build applies
/// it (astronomy.c `Astronomy_BackdatePosition`, `case ABERRATION`). Annual aberration (≤ 20.5″) moves the
/// apparent RA by ≤ 20.5″/cos δ, i.e. a time shift ≤ 20.5/(15·cos δ) s: Sirius ~1.4 s, Achernar ~2.5 s, Polaris
/// ~126 s. Star expectations allow that bound. An independent analytic check (spherical astronomy) guards
/// the star case too.
@Suite("M0-a 뜸·남중·짐")
struct RiseTransitSetTests {
    static let start = utc("2026-10-12T03:00:00Z")       // 12:00 KST
    static let sirius = SkyTarget.star(raHours: 6.752477, decDeg: -16.716116)
    static let polaris = SkyTarget.star(raHours: 2.530301, decDeg: 89.264109)
    static let achernar = SkyTarget.star(raHours: 1.628556, decDeg: -57.236753)

    func close(_ d: Date?, _ unix: Double, _ note: Comment, starDecDeg: Double? = nil) {
        guard let d else { Issue.record("missing \(note)"); return }
        let aberration = starDecDeg.map { 20.5 / (15 * cos($0 * .pi / 180)) } ?? 0
        #expect(abs(d.timeIntervalSince1970 - unix) < 2 + aberration, "\(note): Δ \(d.timeIntervalSince1970 - unix) s")
    }

    func compute(_ t: SkyTarget) throws -> RiseTransitSet {
        try #require(RiseTransitSet.next24h(t, observer: .seoul, from: Self.start))
    }

    @Test("Saturn: rise 17:43, transit 23:50 (alt 54°), set 05:57 next morning")
    func saturn() throws {
        let r = try compute(.body(.saturn))
        #expect(r.visibility == .risesAndSets)
        close(r.rise, 1_791_794_619.507, "rise")
        close(r.transit, 1_791_816_646.068, "transit")
        close(r.set, 1_791_838_669.801, "set")
        #expect(abs(r.transitAltitudeDeg! - 54.1717) < 0.01)
        let rows = r.rows(now: Self.start)
        #expect(rows.map(\.label) == ["뜸", "남중", "짐"])
        #expect(rows.map(\.value) == ["17:43", "23:50 · 고도 54°", "내일 05:57"])
    }

    @Test("Sirius (fixed star): JVM AE times, and rise/set symmetric about transit by the semi-diurnal arc")
    func siriusStar() throws {
        let r = try compute(Self.sirius)
        close(r.rise, 1_791_819_838.402, "rise", starDecDeg: -16.74)
        close(r.transit, 1_791_838_359.797, "transit", starDecDeg: -16.74)
        close(r.set, 1_791_856_881.201, "set", starDecDeg: -16.74)
        // cos H0 = (sin h0 − sin φ sin δ) / (cos φ cos δ), h0 = −34′; sidereal → solar hours × 0.99727.
        let d2r = Double.pi / 180, phi = 37.5665 * d2r, dec = -16.716116 * d2r, h0 = -34.0 / 60 * d2r
        let h0Hours = acos((sin(h0) - sin(phi) * sin(dec)) / (cos(phi) * cos(dec))) / d2r / 15 * 0.997_269_6
        let up = r.transit!.timeIntervalSince(r.rise!) / 3600, down = r.set!.timeIntervalSince(r.transit!) / 3600
        #expect(abs(up - down) * 3600 < 10, "asymmetry \((up - down) * 3600) s")
        // Precession/nutation move δ of date by ~0.1° from J2000 → allow ±1 min on the half-arc.
        #expect(abs(up - h0Hours) * 60 < 1, "half arc \(up) h vs \(h0Hours) h")
    }

    @Test("Catalog vector → same star target as RA/Dec")
    func catalogVector() throws {
        guard case .star(let ra, let dec) = SkyTarget(starJ2000: j2000(raHours: 6.752477, decDeg: -16.716116)) else {
            Issue.record("not a star"); return
        }
        #expect(abs(ra - 6.752477) < 1e-9 && abs(dec + 16.716116) < 1e-9)
    }

    @Test("Polaris never sets in Seoul; Achernar never rises")
    func circumpolar() throws {
        let p = try compute(Self.polaris)
        #expect(p.visibility == .alwaysUp && p.rise == nil && p.set == nil)
        close(p.transit, 1_791_825_217.423, "Polaris transit", starDecDeg: 89.38)   // dec of date
        #expect(p.rows(now: Self.start).map(\.value) == ["지지 않음", "내일 \(KST.hhmm(p.transit!)) · 고도 38°"])

        let a = try compute(Self.achernar)
        #expect(a.visibility == .neverUp && a.rise == nil && a.set == nil)
        close(a.transit, 1_791_819_952.304, "Achernar transit", starDecDeg: -57.12)
        #expect(a.rows(now: Self.start).map(\.value) == ["뜨지 않음", "내일 00:45 · 지평선 아래"])
    }

    @Test("Sun and Moon (upper limb): match the pack's computed sunset 17:59 and JVM AE")
    func sunMoon() throws {
        let s = try compute(.body(.sun))
        close(s.transit, 1_791_775_119.763, "Sun transit")
        close(s.set, 1_791_795_582.694, "sunset")
        close(s.rise, 1_791_841_078.967, "sunrise")
        #expect(KST.hhmm(s.set!) == "17:59")                     // golden pack: computed sunset "1759" for Seoul
        let m = try compute(.body(.moon))
        close(m.transit, 1_791_778_840.309, "Moon transit")
        close(m.set, 1_791_797_249.580, "moonset")
        close(m.rise, 1_791_850_261.852, "moonrise")
    }

    @Test("Events outside the 24 h window are not reported")
    func window() throws {
        // A 0.2-day window from 12:00 ends at 16:48, before Saturn's 17:43 rise and 23:50 transit.
        let r = try #require(AstroEngine.shared.riseTransitSet(.body(.saturn), observer: .seoul, after: Self.start, windowDays: 0.2))
        #expect(r.rise == nil && r.transit == nil && r.set == nil)  // 12:00 + 4.8 h = 16:48 < 17:43 rise
        #expect(r.visibility == .neverUp)                          // below the horizon the whole window
        #expect(r.rows(now: Self.start).map(\.value) == ["뜨지 않음", "24시간 안에 없음"])
        #expect(AstroEngine.shared.riseTransitSet(.star(raHours: 1, decDeg: 95), observer: .seoul, after: Self.start) == nil)
    }
}
