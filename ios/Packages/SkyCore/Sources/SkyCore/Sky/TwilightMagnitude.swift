import Foundation

/// Limiting magnitude rules: stars appear in order of brightness as twilight deepens.
public enum LimitingMagnitude {
    /// Piecewise-linear twilight limit m_tw(h_geo). All knots are finite:
    /// h ≥ −3° → −5 (stars hidden), −6° → 0, −12° → 3, −18° → 7, h < −18° → 7.
    static let twilightKnots: [(h: Double, m: Double)] = [(-3, -5), (-6, 0), (-12, 3), (-18, 7)]

    public static func twilight(sunGeometricAltitudeDeg h: Double) -> Double {
        let k = twilightKnots
        if h >= k[0].h { return k[0].m }
        for i in 1..<k.count where h >= k[i].h {
            let t = (k[i - 1].h - h) / (k[i - 1].h - k[i].h)
            return k[i - 1].m + (k[i].m - k[i - 1].m) * t
        }
        return k[k.count - 1].m
    }

    /// Night limit: light pollution base minus moonlight, clamped to [3.0, 6.5].
    /// - Parameters:
    ///   - base: m_base from the light-pollution class (dark ≈ 6.5, city ≈ 4.0).
    ///   - moonIllumination: illuminated fraction k (0…1).
    ///   - moonAltitudeDeg: Moon altitude; below the horizon it has no effect.
    public static func night(base: Double, moonIllumination k: Double, moonAltitudeDeg: Double) -> Double {
        let moonTerm = 0.5 * k * max(0, sin(moonAltitudeDeg * Double.pi / 180))
        return min(6.5, max(3.0, base - moonTerm))
    }

    /// m_lim = min(m_night, m_tw).
    public static func limit(base: Double, moonIllumination k: Double, moonAltitudeDeg: Double,
                             sunGeometricAltitudeDeg: Double) -> Double {
        min(night(base: base, moonIllumination: k, moonAltitudeDeg: moonAltitudeDeg),
            twilight(sunGeometricAltitudeDeg: sunGeometricAltitudeDeg))
    }

    /// Star opacity: 1 − smoothstep(m_lim − 0.6, m_lim, m). Zero for m ≥ m_lim.
    public static func starAlpha(magnitude m: Double, limit: Double) -> Double {
        1 - smoothstep(limit - 0.6, limit, m)
    }

    /// Planets follow m_lim but never below −5.
    public static func planetLimit(_ limit: Double) -> Double { max(limit, -5) }
}

/// Hermite smoothstep with edge0 < edge1.
public func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
    precondition(edge0 < edge1, "smoothstep requires edge0 < edge1")
    let t = min(1, max(0, (x - edge0) / (edge1 - edge0)))
    return t * t * (3 - 2 * t)
}
