import Foundation
import Testing
import simd
@testable import SkyCore

@Suite("T11 기상청 격자")
struct KMAGridTests {
    @Test("Seoul City Hall → (60, 127)")
    func seoul() {
        let g = KMAGrid.toGrid(latitude: 37.5665, longitude: 126.9780)
        #expect(g.nx == 60 && g.ny == 127)
    }
}

@Suite("T14 SkyPhase")
struct SkyPhaseTests {
    func hud(_ h: Double, evening: Bool = true) -> String {
        SkyPhase.classify(hGeoDeg: h, dhdt: evening ? -0.2 : 0.2).hudText
    }

    @Test("Official phases are half-open and non-overlapping")
    func officialBoundaries() {
        let cases: [(Double, OfficialPhase)] = [
            (10, .day), (-0.832, .day), (-0.833, .civil), (-5.999, .civil), (-6.0, .nautical),
            (-11.999, .nautical), (-12.0, .astronomical), (-17.999, .astronomical), (-18.0, .night), (-40, .night),
        ]
        for (h, expected) in cases {
            #expect(SkyPhase.classify(hGeoDeg: h, dhdt: -1).official == expected, "h \(h)")
        }
    }

    @Test("Convention tags: golden (−0.833, +6], blue (−6, −4]")
    func tags() {
        #expect(SkyPhase.classify(hGeoDeg: 6.0, dhdt: -1).tag == .goldenHour)
        #expect(SkyPhase.classify(hGeoDeg: 6.0001, dhdt: -1).tag == nil)
        #expect(SkyPhase.classify(hGeoDeg: -0.833, dhdt: -1).tag == nil)
        #expect(SkyPhase.classify(hGeoDeg: -4.0, dhdt: -1).tag == .blueHour)
        #expect(SkyPhase.classify(hGeoDeg: -3.999, dhdt: -1).tag == nil)
        #expect(SkyPhase.classify(hGeoDeg: -6.0, dhdt: -1).tag == nil)
    }

    @Test("HUD text, events and dh/dt reversal")
    func hudText() {
        #expect(hud(-0.833) == "일몰")
        #expect(hud(-0.833, evening: false) == "일출")
        #expect(hud(-0.5) == "낮 · 골든아워")
        #expect(hud(-4.0) == "저녁 시민박명 · 블루아워")
        #expect(hud(-5.0, evening: false) == "새벽 시민박명 · 블루아워")
        #expect(hud(-6.0) == "저녁 항해박명")
        #expect(hud(-15) == "저녁 천문박명")
        #expect(hud(-25) == "밤")
    }
}

@Suite("T18 한계등급")
struct LimitingMagnitudeTests {
    func mLim(_ h: Double, base: Double) -> Double {
        LimitingMagnitude.limit(base: base, moonIllumination: 0, moonAltitudeDeg: -10, sunGeometricAltitudeDeg: h)
    }

    @Test("Knots and midpoints (k = 0, Moon below horizon)")
    func knots() {
        let dark: [(Double, Double)] = [(10, -5), (-6, 0), (-12, 3), (-18, 6.5), (-9, 1.5), (-15, 5.0), (-30, 6.5)]
        for (h, m) in dark { #expect(abs(mLim(h, base: 6.5) - m) < 1e-12, "dark h \(h)") }
        let city: [(Double, Double)] = [(10, -5), (-6, 0), (-12, 3), (-18, 4.0), (-15, 4.0)]
        for (h, m) in city { #expect(abs(mLim(h, base: 4.0) - m) < 1e-12, "city h \(h)") }
    }

    @Test("Star alpha is 0 at/above the limit and 1 well below it")
    func alpha() {
        #expect(LimitingMagnitude.starAlpha(magnitude: 3.0, limit: 3.0) == 0)
        #expect(LimitingMagnitude.starAlpha(magnitude: 3.5, limit: 3.0) == 0)
        #expect(LimitingMagnitude.starAlpha(magnitude: 2.4, limit: 3.0) == 1)
        let mid = LimitingMagnitude.starAlpha(magnitude: 2.7, limit: 3.0)
        #expect(mid > 0 && mid < 1)
        // W2 criterion: above −3° no star is visible; at −6° only m < 0 stars.
        #expect(LimitingMagnitude.starAlpha(magnitude: -1.46, limit: mLim(-2.9, base: 6.5)) == 0)
        #expect(LimitingMagnitude.starAlpha(magnitude: 0.03, limit: mLim(-6, base: 6.5)) == 0)
        #expect(LimitingMagnitude.starAlpha(magnitude: -1.46, limit: mLim(-6, base: 6.5)) > 0)
    }

    @Test("Moonlight lowers the night limit but never below 3.0")
    func moon() {
        let full = LimitingMagnitude.night(base: 6.5, moonIllumination: 1, moonAltitudeDeg: 90)
        #expect(abs(full - 6.0) < 1e-12)
        #expect(LimitingMagnitude.night(base: 3.2, moonIllumination: 1, moonAltitudeDeg: 90) == 3.0)
    }
}
