import Foundation
import simd

/// Palette sample for one Sun altitude. Colors are LINEAR sRGB (see ColorMath contract).
public struct SkyPaletteSample: Sendable, Equatable {
    public var zenith: SIMD3<Double>
    public var horizonAnti: SIMD3<Double>
    public var horizonSun: SIMD3<Double>
    /// Glow strength gS, width gW (in units of 1 − cosθ), night-glow weight.
    public var glowStrength: Double
    public var glowWidth: Double
    public var nightGlow: Double
}

/// Presentational sky palette keyed by the Sun's geometric altitude. Values are a design draft
/// (no physical source) and are tuned on the debug contact sheet — not a physical simulation.
public enum SkyPalette {
    struct Keyframe {
        let h: Double
        let zenith, anti, sun: String
        let gS, gW, night: Double
    }

    /// Ordered from high to low Sun altitude.
    static let keyframes: [Keyframe] = [
        Keyframe(h: 20, zenith: "#3D7CC9", anti: "#A9CBEA", sun: "#CFE0F0", gS: 0.15, gW: 0.03, night: 0),
        Keyframe(h: 6, zenith: "#4A78B8", anti: "#B9C9DC", sun: "#F3D9A8", gS: 0.45, gW: 0.06, night: 0),
        Keyframe(h: -0.83, zenith: "#3A5584", anti: "#8E90B4", sun: "#F59A52", gS: 1.0, gW: 0.12, night: 0),
        Keyframe(h: -4, zenith: "#263A66", anti: "#4D5C8C", sun: "#C9735A", gS: 0.7, gW: 0.15, night: 0),
        Keyframe(h: -6, zenith: "#1B2A52", anti: "#33416E", sun: "#8C5A66", gS: 0.45, gW: 0.18, night: 0),
        Keyframe(h: -12, zenith: "#0B1430", anti: "#16203F", sun: "#22284A", gS: 0.12, gW: 0.20, night: 0.3),
        Keyframe(h: -18, zenith: "#03060E", anti: "#070B17", sun: "#070B17", gS: 0, gW: 0.20, night: 1.0),
    ]

    static func sample(_ k: Keyframe) -> SkyPaletteSample {
        SkyPaletteSample(
            zenith: ColorMath.srgbToLinear(ColorMath.hex(k.zenith)),
            horizonAnti: ColorMath.srgbToLinear(ColorMath.hex(k.anti)),
            horizonSun: ColorMath.srgbToLinear(ColorMath.hex(k.sun)),
            glowStrength: k.gS, glowWidth: k.gW, nightGlow: k.night)
    }

    /// Palette at a Sun geometric altitude. Between keyframes: smoothstep in time, OKLab for colors.
    public static func eval(sunGeometricAltitudeDeg h: Double) -> SkyPaletteSample {
        let k = keyframes
        if h >= k[0].h { return sample(k[0]) }
        if h <= k[k.count - 1].h { return sample(k[k.count - 1]) }
        for i in 1..<k.count where h >= k[i].h {
            let upper = sample(k[i - 1]), lower = sample(k[i])
            let t = (k[i - 1].h - h) / (k[i - 1].h - k[i].h)
            let s = t * t * (3 - 2 * t)
            return SkyPaletteSample(
                zenith: ColorMath.mixOklab(upper.zenith, lower.zenith, s),
                horizonAnti: ColorMath.mixOklab(upper.horizonAnti, lower.horizonAnti, s),
                horizonSun: ColorMath.mixOklab(upper.horizonSun, lower.horizonSun, s),
                glowStrength: upper.glowStrength + (lower.glowStrength - upper.glowStrength) * s,
                glowWidth: upper.glowWidth + (lower.glowWidth - upper.glowWidth) * s,
                nightGlow: upper.nightGlow + (lower.nightGlow - upper.nightGlow) * s)
        }
        return sample(k[k.count - 1])
    }

    /// Night additive color (linear): moonlight + light pollution, luminance-capped so the sky
    /// below −6° can never become brighter than the −12° zenith.
    /// - Parameters:
    ///   - moonIllumination: k (0…1); moonAltitudeDeg: below horizon → no moon term.
    ///   - lightPollution: L normalized 0…1 (0 until VIIRS data exists).
    public static func nightColor(moonIllumination k: Double, moonAltitudeDeg: Double,
                                  lightPollution L: Double) -> SIMD3<Double> {
        let moonTerm = k * sqrt(max(0, sin(moonAltitudeDeg * Double.pi / 180)))
        let moon = ColorMath.srgbToLinear(ColorMath.hex("#1A2A4A"))
        let city = ColorMath.srgbToLinear(ColorMath.hex("#3A2E2A"))
        var c = moon * moonTerm + city * min(1, max(0, L))
        let cap = ColorMath.luminance(eval(sunGeometricAltitudeDeg: -12).zenith)
        let y = ColorMath.luminance(c)
        if y > cap, y > 0 { c *= cap / y }
        return c
    }

    /// Ground color under the horizon: anti-sun horizon × 0.35 (linear).
    public static func groundColor(_ sample: SkyPaletteSample) -> SIMD3<Double> {
        sample.horizonAnti * 0.35
    }
}
