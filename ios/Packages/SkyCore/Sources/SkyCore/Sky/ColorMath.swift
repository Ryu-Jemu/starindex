import Foundation
import simd

/// Color-space helpers. Contract: palette hex values are sRGB-encoded; interpolation happens in
/// OKLab; everything the shader receives and mixes is *linear* sRGB; the shader encodes with the
/// sRGB OETF right before returning.
public enum ColorMath {
    public static func srgbToLinear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    public static func linearToSrgb(_ x: Double) -> Double {
        x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
    }

    public static func srgbToLinear(_ c: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(srgbToLinear(c.x), srgbToLinear(c.y), srgbToLinear(c.z))
    }

    public static func linearToSrgb(_ c: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(linearToSrgb(c.x), linearToSrgb(c.y), linearToSrgb(c.z))
    }

    /// "#RRGGBB" → sRGB-encoded components in 0…1.
    public static func hex(_ string: String) -> SIMD3<Double> {
        let s = string.hasPrefix("#") ? String(string.dropFirst()) : string
        precondition(s.count == 6, "hex color must be #RRGGBB")
        let v = UInt32(s, radix: 16)!
        return SIMD3(Double((v >> 16) & 0xFF), Double((v >> 8) & 0xFF), Double(v & 0xFF)) / 255
    }

    /// Rec.709 relative luminance of a linear color.
    public static func luminance(_ c: SIMD3<Double>) -> Double {
        0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
    }

    // OKLab (Björn Ottosson, 2020).
    public static func linearToOklab(_ c: SIMD3<Double>) -> SIMD3<Double> {
        let l = 0.4122214708 * c.x + 0.5363325363 * c.y + 0.0514459929 * c.z
        let m = 0.2119034982 * c.x + 0.6806995451 * c.y + 0.1073969566 * c.z
        let s = 0.0883024619 * c.x + 0.2817188376 * c.y + 0.6299787005 * c.z
        let l_ = cbrt(l), m_ = cbrt(m), s_ = cbrt(s)
        return SIMD3(
            0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
            1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
            0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
        )
    }

    public static func oklabToLinear(_ lab: SIMD3<Double>) -> SIMD3<Double> {
        let l_ = lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z
        let m_ = lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z
        let s_ = lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z
        let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
        return SIMD3(
            4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        )
    }

    /// Interpolates two linear colors through OKLab.
    public static func mixOklab(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ t: Double) -> SIMD3<Double> {
        let la = linearToOklab(a), lb = linearToOklab(b)
        return simd_max(oklabToLinear(la + (lb - la) * t), SIMD3(repeating: 0))
    }
}
