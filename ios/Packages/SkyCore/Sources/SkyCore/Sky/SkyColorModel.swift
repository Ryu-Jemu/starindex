import Foundation
import simd

/// CPU reference implementation of `SkyColor.metal`. Must stay 1:1 with the shader so the
/// contact-sheet test (T17) can compare them.
public enum SkyColorModel {
    /// Exponent shaping the zenith→horizon blend. Shared constant with the Metal shader.
    public static let horizonExponent = 3.0

    /// Returns the sRGB-ENCODED color (0…1) for a horizontal view direction.
    /// - Parameters:
    ///   - direction: unit vector in the horizontal frame (x = N, y = W, z = up).
    ///   - sun: unit vector toward the Sun (refracted position) in the same frame.
    ///   - palette: `SkyPalette.eval` at the Sun's geometric altitude.
    ///   - night: `SkyPalette.nightColor(...)` (linear).
    ///   - ground: `SkyPalette.groundColor(...)` (linear).
    ///   - cloud: 0 (clear) … 1 (overcast / precipitation).
    public static func eval(direction d: SIMD3<Double>, sun: SIMD3<Double>, palette p: SkyPaletteSample,
                            night: SIMD3<Double>, ground: SIMD3<Double>, cloud: Double) -> SIMD3<Double> {
        let mu = d.z
        let t = pow(1 - saturate(mu), horizonExponent)
        let xy = SIMD2(d.x, d.y)
        let nd = xy / max(simd_length(xy), 1e-4)            // shader: xy * rsqrt(max(dot, 1e-8))
        let side = 0.5 + 0.5 * simd_dot(nd, SIMD2(sun.x, sun.y)) // sun.xy not normalized: |.| = cos h_sun
        let horizon = simd_mix(p.horizonAnti, p.horizonSun, SIMD3(repeating: side))
        let base = simd_mix(p.zenith, horizon, SIMD3(repeating: t))
        let glow = p.glowStrength * exp(-(1 - simd_dot(d, sun)) / max(p.glowWidth, 1e-3)) * t
            * smoothstep(-0.02, 0.0, mu)
        var c = base + glow * p.horizonSun + p.nightGlow * night
        let luma = ColorMath.luminance(c) * (1 - 0.25 * cloud)
        c = simd_mix(c, SIMD3(repeating: luma), SIMD3(repeating: 0.7 * cloud))
        c = simd_mix(ground, c, SIMD3(repeating: smoothstep(-0.10, 0.0, mu)))
        let clamped = simd_clamp(c, SIMD3(repeating: 0), SIMD3(repeating: 1))
        return ColorMath.linearToSrgb(clamped)
    }

    static func saturate(_ x: Double) -> Double { min(1, max(0, x)) }
}
