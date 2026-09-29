import Foundation
import simd

/// Sun/Moon event searches built on Astronomy Engine. Searches look 2 days ahead: the next
/// sunset can be more than 24 h away (days lengthen), so a 1-day window briefly fails right
/// after sunset and would be mistaken for polar day/night.
public enum RiseSetService {
    /// Next sunset (upper limb, standard refraction).
    public static func sunset(after date: Date, observer: ObserverLocation,
                              engine: AstroEngine = .shared) -> Date? {
        engine.searchRiseSet(.sun, observer: observer, direction: .set, after: date, limitDays: 2.0)
    }

    public static func sunrise(after date: Date, observer: ObserverLocation,
                               engine: AstroEngine = .shared) -> Date? {
        engine.searchRiseSet(.sun, observer: observer, direction: .rise, after: date, limitDays: 2.0)
    }

    /// Evening time the Sun's center descends through a geometric altitude (e.g. −6, −12, −18).
    public static func duskCrossing(altitudeDeg: Double, after date: Date, observer: ObserverLocation,
                                    engine: AstroEngine = .shared) -> Date? {
        engine.searchAltitude(.sun, observer: observer, direction: .set, after: date,
                              limitDays: 2.0, altitudeDeg: altitudeDeg)
    }

    /// Lower culmination of the Sun (hour angle 12h) — the minimum altitude of the night.
    /// `SearchAltitude` cannot find extrema, so this uses the hour-angle search.
    public static func lowerCulmination(after date: Date, observer: ObserverLocation,
                                        engine: AstroEngine = .shared) -> Date? {
        engine.searchHourAngle(.sun, observer: observer, hourAngle: 12.0, after: date)
    }
}

/// Sun geometry for rendering and phase classification.
public struct SolarState: Sendable {
    /// Geometric (unrefracted) altitude of the Sun's center, degrees.
    public var geometricAltitudeDeg: Double
    /// Altitude rate in degrees per minute (negative in the evening).
    public var altitudeRateDegPerMin: Double
    /// Unit vector toward the refracted Sun in the horizontal frame.
    public var apparentHorizontal: SIMD3<Double>

    public init(geometricAltitudeDeg: Double, altitudeRateDegPerMin: Double, apparentHorizontal: SIMD3<Double>) {
        self.geometricAltitudeDeg = geometricAltitudeDeg
        self.altitudeRateDegPerMin = altitudeRateDegPerMin
        self.apparentHorizontal = apparentHorizontal
    }

    public static func compute(date: Date, observer: ObserverLocation, engine: AstroEngine = .shared) -> SolarState? {
        guard let h0 = engine.geometricAltitude(.sun, date: date, observer: observer),
              let h1 = engine.geometricAltitude(.sun, date: date.addingTimeInterval(60), observer: observer),
              let eqj = engine.equatorJ2000Vector(.sun, date: date, observer: observer) else { return nil }
        let r = engine.rotationEQJtoHOR(date: date, observer: observer)
        let apparent = Refraction.refract(r * eqj, engine: engine)
        return SolarState(geometricAltitudeDeg: h0, altitudeRateDegPerMin: h1 - h0, apparentHorizontal: apparent)
    }

    public var phase: SkyPhaseInfo {
        SkyPhase.classify(hGeoDeg: geometricAltitudeDeg, dhdt: altitudeRateDegPerMin)
    }
}
