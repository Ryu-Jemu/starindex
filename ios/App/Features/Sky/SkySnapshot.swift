import Foundation
import simd
import SkyCore

/// Time control: live, or the ~20 s sunset playback (plan 4.4).
struct SkyClock: Sendable {
    enum Mode: Sendable {
        case live
        case playing(SunsetPlaybackPlan, startUptime: TimeInterval)
    }

    var mode: Mode = .live

    var isLive: Bool { if case .live = mode { return true } else { return false } }

    /// Simulated date for a monotonic uptime. `finished` once playback passes the plan end.
    func date(atUptime u: TimeInterval, wallNow: Date) -> (date: Date, finished: Bool) {
        switch mode {
        case .live:
            return (wallNow, false)
        case .playing(let plan, let start):
            var e = max(0, u - start)
            for s in plan.segments {
                if e <= s.realSeconds { return (s.from.addingTimeInterval(e * s.speed), false) }
                e -= s.realSeconds
            }
            return (plan.end, true)
        }
    }
}

struct BodyDraw: Sendable {
    var body: SkyBody
    var horizontal: SIMD3<Double>      // refracted, horizontal frame
    var magnitude: Double
    var phaseFraction: Double
    var alpha: Double
}

/// Everything that depends only on (time, observer): rebuilt at 1 Hz live, every frame in playback.
struct SkySnapshot: Sendable {
    var date: Date
    var observer: ObserverLocation
    var rotation: simd_double3x3          // EQJ → HOR
    var starsHOR: [SIMD3<Float>]          // refracted, parallel to catalog.stars
    var starAlpha: [Float]                // limiting-magnitude opacity (0 = hidden)
    var anchorsHOR: [SIMD3<Float>]        // constellation label anchors
    var bodies: [BodyDraw]
    var sun: SolarState
    var palette: SkyPaletteSample
    var night: SIMD3<Double>
    var ground: SIMD3<Double>
    var limitingMagnitude: Double
    var lineAlpha: Double                 // stick figures fade in through civil twilight

    /// m_base when the pack has no light-pollution class yet (plan 4.3).
    static let defaultMagnitudeBase = 5.5

    static func build(catalog: SkyCatalog, date: Date, observer: ObserverLocation,
                      engine: AstroEngine = .shared) -> SkySnapshot {
        let r = engine.rotationEQJtoHOR(date: date, observer: observer)
        let rf = simd_float3x3(columns: (SIMD3<Float>(r.columns.0), SIMD3<Float>(r.columns.1), SIMD3<Float>(r.columns.2)))
        let sun = SolarState.compute(date: date, observer: observer, engine: engine)
            ?? SolarState(geometricAltitudeDeg: -30, altitudeRateDegPerMin: -0.1, apparentHorizontal: SIMD3(0, 0, -1))

        var bodies = EphemerisService.bodies(date: date, observer: observer, engine: engine).map {
            BodyDraw(body: $0.body, horizontal: Refraction.refract(r * $0.j2000, engine: engine),
                     magnitude: $0.magnitude, phaseFraction: $0.phaseFraction, alpha: 1)
        }
        let moon = bodies.first { $0.body == .moon }
        let moonAlt = moon.map { Horizontal.altAz($0.horizontal).altitudeDeg } ?? -90
        let moonK = moon?.phaseFraction ?? 0

        let mLim = LimitingMagnitude.limit(base: defaultMagnitudeBase, moonIllumination: moonK,
                                           moonAltitudeDeg: moonAlt, sunGeometricAltitudeDeg: sun.geometricAltitudeDeg)
        for i in bodies.indices where bodies[i].body != .sun && bodies[i].body != .moon {
            bodies[i].alpha = LimitingMagnitude.starAlpha(magnitude: bodies[i].magnitude,
                                                          limit: LimitingMagnitude.planetLimit(mLim))
        }

        var starsHOR = [SIMD3<Float>](repeating: .zero, count: catalog.stars.count)
        var alpha = [Float](repeating: 0, count: catalog.stars.count)
        for (i, s) in catalog.stars.enumerated() {
            starsHOR[i] = Refraction.fastRefract(rf * s.j2000)
            alpha[i] = s.isLineOnly ? 0 : Float(LimitingMagnitude.starAlpha(magnitude: Double(s.magnitude), limit: mLim))
        }
        let anchors = catalog.constellations.map { Refraction.fastRefract(rf * $0.anchor) }

        let palette = SkyPalette.eval(sunGeometricAltitudeDeg: sun.geometricAltitudeDeg)
        return SkySnapshot(
            date: date, observer: observer, rotation: r, starsHOR: starsHOR, starAlpha: alpha,
            anchorsHOR: anchors, bodies: bodies, sun: sun, palette: palette,
            night: SkyPalette.nightColor(moonIllumination: moonK, moonAltitudeDeg: moonAlt, lightPollution: 0),
            ground: SkyPalette.groundColor(palette), limitingMagnitude: mLim,
            lineAlpha: 1 - smoothstep(-6, SkyPhase.sunsetAltitude, sun.geometricAltitudeDeg))
    }
}
