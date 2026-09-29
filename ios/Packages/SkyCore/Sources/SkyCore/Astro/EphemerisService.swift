import Foundation
import simd

public struct BodyState: Sendable {
    public var body: SkyBody
    /// Topocentric J2000 unit vector (goes through the same R → refraction path as stars).
    public var j2000: SIMD3<Double>
    public var magnitude: Double
    public var phaseFraction: Double
}

public enum EphemerisService {
    /// Sun, Moon and planets. Recompute every ~5 s normally; every frame (or each simulated
    /// minute) during time-travel playback.
    public static func bodies(date: Date, observer: ObserverLocation,
                              engine: AstroEngine = .shared) -> [BodyState] {
        SkyBody.allCases.compactMap { body in
            guard let v = engine.equatorJ2000Vector(body, date: date, observer: observer) else { return nil }
            let il = engine.illumination(body, date: date)
            return BodyState(body: body, j2000: v, magnitude: il?.magnitude ?? 0,
                             phaseFraction: il?.phaseFraction ?? 1)
        }
    }
}

public enum ConstellationLocator {
    /// IAU abbreviation for a J2000 direction.
    public static func locate(j2000 v: SIMD3<Double>, engine: AstroEngine = .shared) -> String? {
        let n = simd_normalize(v)
        var ra = atan2(n.y, n.x) * 12 / Double.pi
        if ra < 0 { ra += 24 }
        let dec = asin(max(-1, min(1, n.z))) * 180 / Double.pi
        return engine.constellation(raHours: ra, decDeg: dec)
    }
}
