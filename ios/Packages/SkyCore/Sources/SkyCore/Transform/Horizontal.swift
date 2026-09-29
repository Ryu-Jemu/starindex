import Foundation
import simd

/// Helpers for the horizontal frame used everywhere in SkyCore:
/// x = north, y = west, z = zenith (identical to Astronomy Engine's HOR frame and to
/// CoreMotion's `.xTrueNorthZVertical` reference frame).
public enum Horizontal {
    static let degPerRad = 180.0 / Double.pi

    /// Altitude (−90…90) and azimuth (0…360, north = 0, east = 90) in degrees.
    /// Non-finite or zero-length input yields (NaN, NaN) — it must never be mistaken for the zenith.
    public static func altAz(_ v: SIMD3<Double>) -> (altitudeDeg: Double, azimuthDeg: Double) {
        let len = simd_length(v)
        guard len.isFinite, len > 0 else { return (.nan, .nan) }
        let n = v / len
        let alt = asin(max(-1, min(1, n.z))) * degPerRad
        var az = atan2(-n.y, n.x) * degPerRad
        if az < 0 { az += 360 }
        if az >= 360 { az -= 360 }
        return (alt, az)
    }

    /// Unit vector for an altitude/azimuth pair (degrees).
    public static func vector(altitudeDeg: Double, azimuthDeg: Double) -> SIMD3<Double> {
        let a = altitudeDeg / degPerRad, z = azimuthDeg / degPerRad
        return SIMD3(cos(a) * cos(z), -cos(a) * sin(z), sin(a))
    }
}

public enum Rotation {
    /// Counter-clockwise rotation about +z by `degrees`. In the horizontal frame this maps
    /// azimuth A → A − degrees.
    public static func z(_ degrees: Double) -> simd_double3x3 {
        let t = degrees * Double.pi / 180, c = cos(t), s = sin(t)
        return simd_double3x3(columns: (SIMD3(c, s, 0), SIMD3(-s, c, 0), SIMD3(0, 0, 1)))
    }
}

/// Wraps an angle to (−180, 180].
public func wrap180(_ degrees: Double) -> Double {
    var d = degrees.truncatingRemainder(dividingBy: 360)
    if d <= -180 { d += 360 }
    if d > 180 { d -= 360 }
    return d
}

public enum HorizonTransform {
    /// R: EQJ → HOR for the given instant and observer (see `AstroEngine.rotationEQJtoHOR`).
    public static func make(date: Date, observer: ObserverLocation,
                            engine: AstroEngine = .shared) -> simd_double3x3 {
        engine.rotationEQJtoHOR(date: date, observer: observer)
    }
}

public enum Refraction {
    /// Applies standard refraction to a geometric horizontal vector (all altitudes; AE tapers
    /// the correction continuously below −1°). Azimuth is preserved.
    public static func refract(_ h: SIMD3<Double>, engine: AstroEngine = .shared) -> SIMD3<Double> {
        let (alt, az) = Horizontal.altAz(h)
        guard alt.isFinite else { return h }
        let bent = min(90, max(-90, alt + engine.refraction(altitudeDeg: alt)))
        return Horizontal.vector(altitudeDeg: bent, azimuthDeg: az)
    }

    /// Removes standard refraction from an apparent horizontal vector.
    public static func unrefract(_ h: SIMD3<Double>, engine: AstroEngine = .shared) -> SIMD3<Double> {
        let (alt, az) = Horizontal.altAz(h)
        guard alt.isFinite else { return h }
        let geometric = min(90, max(-90, alt + engine.inverseRefraction(bentAltitudeDeg: alt)))
        return Horizontal.vector(altitudeDeg: geometric, azimuthDeg: az)
    }
}
