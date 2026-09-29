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

    @Test("T15b: moon + light pollution never make h ≤ −6° brighter than the −6° zenith (via SkyColorModel)")
    func nightCap() {
        let night = SkyPalette.nightColor(moonIllumination: 1, moonAltitudeDeg: 90, lightPollution: 1)
        let cap = ColorMath.luminance(SkyPalette.eval(sunGeometricAltitudeDeg: -6).zenith)
        for h in stride(from: -6.0, through: -30.0, by: -0.5) {
            let p = SkyPalette.eval(sunGeometricAltitudeDeg: h)
            let sun = Horizontal.vector(altitudeDeg: h, azimuthDeg: 280)
            for cloud in [0.0, 1.0] {
                let enc = SkyColorModel.eval(direction: U, sun: sun, palette: p, night: night,
                                             ground: SkyPalette.groundColor(p), cloud: cloud)
                #expect(ColorMath.luminance(ColorMath.srgbToLinear(enc)) <= cap + 1e-9, "h \(h) cloud \(cloud)")
            }
        }
    }

    /// Independent integer literals (not derived from ColorMath.hex) for each keyframe zenith.
    static let zenithLiterals: [(h: Double, rgb: SIMD3<Double>)] = [
        (20, SIMD3(61, 124, 201)), (6, SIMD3(74, 120, 184)), (-0.83, SIMD3(58, 85, 132)),
        (-4, SIMD3(38, 58, 102)), (-6, SIMD3(27, 42, 82)), (-12, SIMD3(11, 20, 48)), (-18, SIMD3(3, 6, 14)),
    ]

    @Test("T17 (CPU): zenith pixel equals the keyframe color literal within 1/255")
    func keyframeAbsoluteColor() {
        #expect(ColorMath.hex("#3D7CC9") * 255 == SIMD3(61, 124, 201))
        for (h, rgb) in Self.zenithLiterals {
            let p = SkyPalette.eval(sunGeometricAltitudeDeg: h)
            let sun = Horizontal.vector(altitudeDeg: h, azimuthDeg: 270)
            let out = SkyColorModel.eval(direction: U, sun: sun, palette: p, night: noNight,
                                         ground: SkyPalette.groundColor(p), cloud: 0) * 255
            #expect(simd_reduce_max(simd_abs(out - rgb)) <= 1.0, "h \(h): \(out)")
        }
    }

    @Test("T17 (CPU): nadir shows the ground color")
    func nadirGround() {
        for h in [20.0, -0.83, -12] {
            let p = SkyPalette.eval(sunGeometricAltitudeDeg: h)
            let sun = Horizontal.vector(altitudeDeg: h, azimuthDeg: 270)
            let ground = SkyPalette.groundColor(p)
            let out = SkyColorModel.eval(direction: -U, sun: sun, palette: p, night: noNight, ground: ground, cloud: 0)
            #expect(simd_reduce_max(simd_abs(out - ColorMath.linearToSrgb(ground))) <= 1.0 / 255)
        }
    }

    @Test("Shader math is finite (unclamped linear) at zenith, nadir and toward the Sun")
    func finite() {
        for h in [-30.0, -12, -6, -0.83, 0, 6, 30, 89.9] {
            let p = SkyPalette.eval(sunGeometricAltitudeDeg: h)
            let sun = Horizontal.vector(altitudeDeg: h, azimuthDeg: 250)
            let night = SkyPalette.nightColor(moonIllumination: 0.5, moonAltitudeDeg: 40, lightPollution: 0.3)
            for d in [U, -U, sun, Horizontal.vector(altitudeDeg: 0, azimuthDeg: 250)] {
                for cloud in [0.0, 1.0] {
                    let lin = SkyColorModel.linear(direction: d, sun: sun, palette: p, night: night,
                                                   ground: SkyPalette.groundColor(p), cloud: cloud)
                    #expect(lin.x.isFinite && lin.y.isFinite && lin.z.isFinite)
                    #expect(simd_reduce_min(lin) >= 0)
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
