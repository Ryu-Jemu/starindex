import Foundation
import Testing
import simd
@testable import SkyCore

@Suite("T15/T17 하늘색")
struct SkyColorTests {
    let noNight = SIMD3<Double>(repeating: 0)

    @Test("OKLab round-trip")
    func oklabRoundTrip() {
        for r in stride(from: 0.0, through: 1.0, by: 0.25) {
            for g in stride(from: 0.0, through: 1.0, by: 0.25) {
                for b in stride(from: 0.0, through: 1.0, by: 0.25) {
                    let c = SIMD3(r, g, b)
                    let back = ColorMath.oklabToLinear(ColorMath.linearToOklab(c))
                    #expect(simd_distance(c, back) < 1e-6)
                }
            }
        }
    }

    @Test("T15: palette is continuous (ΔE_ok ≤ 0.02 per 0.1°)")
    func continuity() {
        var prev = SkyPalette.eval(sunGeometricAltitudeDeg: 30)
        for h in stride(from: 29.9, through: -25.0, by: -0.1) {
            let cur = SkyPalette.eval(sunGeometricAltitudeDeg: h)
            for (a, b) in [(prev.zenith, cur.zenith), (prev.horizonAnti, cur.horizonAnti), (prev.horizonSun, cur.horizonSun)] {
                let d = simd_distance(ColorMath.linearToOklab(a), ColorMath.linearToOklab(b))
                #expect(d <= 0.02, "h \(h) ΔE \(d)")
            }
            prev = cur
        }
    }

    @Test("T15: zenith lightness decreases monotonically from +6° to −18° (cNight = 0)")
    func monotonicZenith() {
        var prevL = Double.infinity, prevY = Double.infinity
        for h in stride(from: 6.0, through: -18.0, by: -0.05) {
            let z = SkyPalette.eval(sunGeometricAltitudeDeg: h).zenith
            let l = ColorMath.linearToOklab(z).x, y = ColorMath.luminance(z)
            #expect(l <= prevL + 1e-12, "L at h \(h)")
            #expect(y <= prevY + 1e-9, "Y at h \(h)")
            prevL = l; prevY = y
        }
    }

    @Test("T15b: moon + light pollution never make h ≤ −6° brighter than the −6° zenith")
    func nightCap() {
        let night = SkyPalette.nightColor(moonIllumination: 1, moonAltitudeDeg: 90, lightPollution: 1)
        let cap = ColorMath.luminance(SkyPalette.eval(sunGeometricAltitudeDeg: -6).zenith)
        for h in stride(from: -6.0, through: -30.0, by: -0.5) {
            let p = SkyPalette.eval(sunGeometricAltitudeDeg: h)
            let zenith = p.zenith + p.nightGlow * night
            #expect(ColorMath.luminance(zenith) <= cap + 1e-12, "h \(h)")
        }
    }

    @Test("T17 (CPU): zenith pixel equals the keyframe hex within 1/255")
    func keyframeAbsoluteColor() {
        for k in SkyPalette.keyframes {
            let p = SkyPalette.eval(sunGeometricAltitudeDeg: k.h)
            let sun = Horizontal.vector(altitudeDeg: k.h, azimuthDeg: 270)
            let out = SkyColorModel.eval(direction: U, sun: sun, palette: p, night: noNight,
                                         ground: SkyPalette.groundColor(p), cloud: 0)
            let expected = ColorMath.hex(k.zenith)
            #expect(simd_reduce_max(simd_abs(out - expected)) <= 1.0 / 255, "\(k.h)")
        }
    }

    @Test("Shader math is finite at zenith, nadir and toward the Sun")
    func finite() {
        for h in [-30.0, -12, -6, -0.83, 0, 6, 30, 89.9] {
            let p = SkyPalette.eval(sunGeometricAltitudeDeg: h)
            let sun = Horizontal.vector(altitudeDeg: h, azimuthDeg: 250)
            let night = SkyPalette.nightColor(moonIllumination: 0.5, moonAltitudeDeg: 40, lightPollution: 0.3)
            for d in [U, -U, sun, Horizontal.vector(altitudeDeg: 0, azimuthDeg: 250)] {
                for cloud in [0.0, 1.0] {
                    let c = SkyColorModel.eval(direction: d, sun: sun, palette: p, night: night,
                                               ground: SkyPalette.groundColor(p), cloud: cloud)
                    #expect(c.x.isFinite && c.y.isFinite && c.z.isFinite)
                    #expect(simd_reduce_min(c) >= 0 && simd_reduce_max(c) <= 1)
                }
            }
        }
    }

    @Test("Sunward horizon is warmer than the anti-sun horizon at sunset")
    func sunwardGlow() {
        let p = SkyPalette.eval(sunGeometricAltitudeDeg: -0.83)
        let sun = Horizontal.vector(altitudeDeg: -0.5, azimuthDeg: 270)
        let look = { (az: Double) in
            SkyColorModel.eval(direction: Horizontal.vector(altitudeDeg: 2, azimuthDeg: az), sun: sun,
                               palette: p, night: SIMD3(repeating: 0), ground: SkyPalette.groundColor(p), cloud: 0)
        }
        let west = look(270), east = look(90)
        #expect(west.x - west.z > east.x - east.z)
    }

    @Test("Cloud reduces chroma")
    func cloudDesaturates() {
        let p = SkyPalette.eval(sunGeometricAltitudeDeg: -0.83)
        let sun = Horizontal.vector(altitudeDeg: -0.5, azimuthDeg: 270)
        let d = Horizontal.vector(altitudeDeg: 3, azimuthDeg: 260)
        func chroma(_ cloud: Double) -> Double {
            let enc = SkyColorModel.eval(direction: d, sun: sun, palette: p, night: SIMD3(repeating: 0),
                                         ground: SkyPalette.groundColor(p), cloud: cloud)
            let lab = ColorMath.linearToOklab(ColorMath.srgbToLinear(enc))
            return hypot(lab.y, lab.z)
        }
        #expect(chroma(1) < chroma(0) * 0.5)
    }
}
