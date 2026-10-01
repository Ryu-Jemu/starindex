import Foundation
import simd

/// Something the sky view can ask rise/transit/set times for.
public enum SkyTarget: Sendable, Equatable {
    case body(SkyBody)
    /// Fixed star at J2000 (EQJ) right ascension (hours) and declination (degrees).
    case star(raHours: Double, decDeg: Double)

    /// From a catalog star's J2000 unit vector (the skypack already applied proper motion to its epoch).
    public init(starJ2000 v: SIMD3<Double>) {
        let n = simd_normalize(v)
        var ra = atan2(n.y, n.x) * 12 / .pi
        if ra < 0 { ra += 24 }
        self = .star(raHours: ra, decDeg: asin(max(-1, min(1, n.z))) * 180 / .pi)
    }
}

/// Rise, upper culmination (남중) and set within a window (detail sheet '뜸·남중·짐', SERVICE-PLAN M0-a).
public struct RiseTransitSet: Sendable, Equatable {
    public enum Visibility: Sendable, Equatable {
        case risesAndSets
        /// No rise or set in the window and above the horizon: circumpolar ("지지 않음").
        case alwaysUp
        /// No rise or set in the window and below the horizon ("뜨지 않음").
        case neverUp
    }

    public var rise: Date?
    public var transit: Date?
    /// Apparent (refracted) altitude at the culmination, degrees.
    public var transitAltitudeDeg: Double?
    public var set: Date?
    public var visibility: Visibility

    public init(rise: Date?, transit: Date?, transitAltitudeDeg: Double?, set: Date?, visibility: Visibility) {
        self.rise = rise
        self.transit = transit
        self.transitAltitudeDeg = transitAltitudeDeg
        self.set = set
        self.visibility = visibility
    }

    /// Next 24 h from `date`.
    public static func next24h(_ target: SkyTarget, observer: ObserverLocation, from date: Date,
                               engine: AstroEngine = .shared) -> RiseTransitSet? {
        engine.riseTransitSet(target, observer: observer, after: date, windowDays: 1.0)
    }

    /// Rows for the detail sheet, times in KST ("내일 05:57" past midnight).
    public func rows(now: Date) -> [(label: String, value: String)] {
        let none = "24시간 안에 없음"
        var transitText = none
        if let t = transit {
            transitText = KST.timeRelative(t, now: now)
            if let alt = transitAltitudeDeg {
                transitText += alt > 0 ? String(format: " · 고도 %.0f°", alt) : " · 지평선 아래"
            }
        }
        switch visibility {
        case .alwaysUp:
            return [("뜸·짐", "지지 않음"), ("남중", transitText)]
        case .neverUp:
            return [("뜸·짐", "뜨지 않음"), ("남중", transitText)]
        case .risesAndSets:
            return [("뜸", rise.map { KST.timeRelative($0, now: now) } ?? none),
                    ("남중", transitText),
                    ("짐", set.map { KST.timeRelative($0, now: now) } ?? none)]
        }
    }
}
