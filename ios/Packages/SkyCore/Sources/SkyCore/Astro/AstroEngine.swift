import CAstronomy
import Foundation
import simd

/// The single entry point to Astronomy Engine's C API.
///
/// Every C call is serialized behind one lock: `Astronomy_Constellation` (and a few other
/// routines) lazily initialize `static` state without synchronization, so concurrent calls
/// from the 1 Hz snapshot builder, the HUD and search would race. A lock (rather than an
/// actor) keeps the API synchronous so the render loop can use it without `await`.
public final class AstroEngine: Sendable {
    public static let shared = AstroEngine()

    private let lock = NSLock()

    private init() {}

    // MARK: - Time

    /// Days since J2000 (2000-01-01T12:00:00Z) in UT → `astro_time_t`.
    static func astroTime(_ date: Date) -> astro_time_t {
        Astronomy_TimeFromDays(date.timeIntervalSince1970 / 86_400.0 - 10_957.5)
    }

    static func date(_ time: astro_time_t) -> Date {
        Date(timeIntervalSince1970: (time.ut + 10_957.5) * 86_400.0)
    }

    // MARK: - Rotation / refraction

    /// Rotation matrix taking J2000 equatorial (EQJ) vectors to the observer's horizontal frame
    /// (x = north, y = west, z = zenith). Built by rotating the basis vectors with
    /// `Astronomy_RotateVector`, so we never interpret AE's `rot[i][j]` indexing directly.
    public func rotationEQJtoHOR(date: Date, observer: ObserverLocation) -> simd_double3x3 {
        lock.withLock {
            var t = Self.astroTime(date)
            let rot = Astronomy_Rotation_EQJ_HOR(&t, observer.cObserver)
            precondition(rot.status == ASTRO_SUCCESS, "Rotation_EQJ_HOR failed: \(rot.status)")
            func column(_ x: Double, _ y: Double, _ z: Double) -> SIMD3<Double> {
                let v = Astronomy_RotateVector(rot, astro_vector_t(status: ASTRO_SUCCESS, x: x, y: y, z: z, t: t))
                return SIMD3(v.x, v.y, v.z)
            }
            return simd_double3x3(columns: (column(1, 0, 0), column(0, 1, 0), column(0, 0, 1)))
        }
    }

    /// Rotation matrix taking EQJ vectors to galactic coordinates.
    public func rotationEQJtoGAL() -> simd_double3x3 {
        lock.withLock {
            let rot = Astronomy_Rotation_EQJ_GAL()
            let t = Self.astroTime(Date(timeIntervalSince1970: 946_728_000))
            func column(_ x: Double, _ y: Double, _ z: Double) -> SIMD3<Double> {
                let v = Astronomy_RotateVector(rot, astro_vector_t(status: ASTRO_SUCCESS, x: x, y: y, z: z, t: t))
                return SIMD3(v.x, v.y, v.z)
            }
            return simd_double3x3(columns: (column(1, 0, 0), column(0, 1, 0), column(0, 0, 1)))
        }
    }

    /// Standard refraction (degrees to add) at a geometric altitude, continuous for all altitudes.
    /// Above 89.9° AE's Saemundsson formula turns slightly negative (non-physical, ≥ −3.2e-5°);
    /// it is treated as 0 there so refract/unrefract stay exact inverses at the zenith.
    public func refraction(altitudeDeg: Double) -> Double {
        guard altitudeDeg.isFinite else { return 0 }
        if altitudeDeg > 89.9 { return 0 }
        return Astronomy_Refraction(REFRACTION_NORMAL, altitudeDeg)
    }

    /// Inverse of `refraction`: degrees to add to an apparent (bent) altitude to get the geometric one.
    ///
    /// Implemented here with a bounded fixed-point iteration instead of calling
    /// `Astronomy_InverseRefraction`, whose `for(;;)` loop has no iteration cap and never
    /// terminates for bent altitudes above ≈ 89.99997° (no solution: R(90) < 0), for ~0.7 % of
    /// inputs in [−90°, −64°] (±1 ulp 2-cycle, since d(a+R)/da > 1 there and ulp > 1e-14) and
    /// for NaN. The map a ← b − R(a) is a contraction (|R′| ≤ 0.2), so it converges quickly.
    public func inverseRefraction(bentAltitudeDeg b: Double) -> Double {
        guard b.isFinite, b >= -90, b <= 90 else { return 0 }
        if b > 89.9 { return 0 }                  // |refraction| < 3e-5° up here
        var a = b - refraction(altitudeDeg: b)
        for _ in 0..<50 {
            let diff = (a + refraction(altitudeDeg: a)) - b
            if abs(diff) <= 1e-12 { break }
            a -= diff
        }
        return a - b
    }

    // MARK: - Positions

    /// Topocentric J2000 unit vector of a body (with aberration).
    public func equatorJ2000Vector(_ body: SkyBody, date: Date, observer: ObserverLocation) -> SIMD3<Double>? {
        lock.withLock {
            var t = Self.astroTime(date)
            let eq = Astronomy_Equator(body.cBody, &t, observer.cObserver, EQUATOR_J2000, ABERRATION)
            guard eq.status == ASTRO_SUCCESS else { return nil }
            return simd_normalize(SIMD3(eq.vec.x, eq.vec.y, eq.vec.z))
        }
    }

    /// Topocentric equatorial coordinates of date (RA in hours, Dec in degrees).
    public func equatorOfDate(_ body: SkyBody, date: Date, observer: ObserverLocation) -> (raHours: Double, decDeg: Double)? {
        lock.withLock {
            var t = Self.astroTime(date)
            let eq = Astronomy_Equator(body.cBody, &t, observer.cObserver, EQUATOR_OF_DATE, ABERRATION)
            guard eq.status == ASTRO_SUCCESS else { return nil }
            return (eq.ra, eq.dec)
        }
    }

    /// Horizontal coordinates from of-date RA/Dec (reference implementation used by tests).
    public func horizon(date: Date, observer: ObserverLocation, raHours: Double, decDeg: Double,
                        refracted: Bool) -> (azimuthDeg: Double, altitudeDeg: Double) {
        lock.withLock {
            var t = Self.astroTime(date)
            let h = Astronomy_Horizon(&t, observer.cObserver, raHours, decDeg,
                                      refracted ? REFRACTION_NORMAL : REFRACTION_NONE)
            return (h.azimuth, h.altitude)
        }
    }

    /// Geometric (unrefracted) altitude of the body's center, in degrees.
    public func geometricAltitude(_ body: SkyBody, date: Date, observer: ObserverLocation) -> Double? {
        lock.withLock {
            var t = Self.astroTime(date)
            let eq = Astronomy_Equator(body.cBody, &t, observer.cObserver, EQUATOR_OF_DATE, ABERRATION)
            guard eq.status == ASTRO_SUCCESS else { return nil }
            return Astronomy_Horizon(&t, observer.cObserver, eq.ra, eq.dec, REFRACTION_NONE).altitude
        }
    }

    /// Visual magnitude and illuminated fraction.
    public func illumination(_ body: SkyBody, date: Date) -> (magnitude: Double, phaseFraction: Double)? {
        lock.withLock {
            let il = Astronomy_Illumination(body.cBody, Self.astroTime(date))
            guard il.status == ASTRO_SUCCESS else { return nil }
            return (il.mag, il.phase_fraction)
        }
    }

    /// IAU constellation abbreviation (e.g. "UMi") for J2000 RA (hours) / Dec (degrees).
    public func constellation(raHours: Double, decDeg: Double) -> String? {
        lock.withLock {
            let c = Astronomy_Constellation(raHours, decDeg)
            guard c.status == ASTRO_SUCCESS, let symbol = c.symbol else { return nil }
            return String(cString: symbol)
        }
    }

    // MARK: - Searches

    public enum Direction: Sendable { case rise, set
        var c: astro_direction_t { self == .rise ? DIRECTION_RISE : DIRECTION_SET }
    }

    /// Rise/set with standard refraction and the body's apparent radius.
    public func searchRiseSet(_ body: SkyBody, observer: ObserverLocation, direction: Direction,
                              after date: Date, limitDays: Double) -> Date? {
        lock.withLock {
            let r = Astronomy_SearchRiseSetEx(body.cBody, observer.cObserver, direction.c,
                                              Self.astroTime(date), limitDays, 0.0)
            return r.status == ASTRO_SUCCESS ? Self.date(r.time) : nil
        }
    }

    /// When the body's center crosses a geometric (unrefracted) altitude.
    public func searchAltitude(_ body: SkyBody, observer: ObserverLocation, direction: Direction,
                               after date: Date, limitDays: Double, altitudeDeg: Double) -> Date? {
        lock.withLock {
            let r = Astronomy_SearchAltitude(body.cBody, observer.cObserver, direction.c,
                                             Self.astroTime(date), limitDays, altitudeDeg)
            return r.status == ASTRO_SUCCESS ? Self.date(r.time) : nil
        }
    }

    /// Next time the body reaches the given local hour angle (0 = upper culmination, 12 = lower).
    public func searchHourAngle(_ body: SkyBody, observer: ObserverLocation, hourAngle: Double,
                                after date: Date) -> Date? {
        lock.withLock {
            let r = Astronomy_SearchHourAngleEx(body.cBody, observer.cObserver, hourAngle, Self.astroTime(date), +1)
            return r.status == ASTRO_SUCCESS ? Self.date(r.time) : nil
        }
    }

    /// Upper culmination of a fixed J2000 star (used by transit tests).
    public func starCulmination(raHours: Double, decDeg: Double, observer: ObserverLocation,
                                after date: Date) -> Date? {
        lock.withLock {
            guard Astronomy_DefineStar(BODY_STAR1, raHours, decDeg, 1000.0) == ASTRO_SUCCESS else { return nil }
            let r = Astronomy_SearchHourAngleEx(BODY_STAR1, observer.cObserver, 0.0, Self.astroTime(date), +1)
            return r.status == ASTRO_SUCCESS ? Self.date(r.time) : nil
        }
    }
}
