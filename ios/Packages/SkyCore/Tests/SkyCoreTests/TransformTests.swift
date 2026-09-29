import Foundation
import Testing
import simd
@testable import SkyCore

@Suite("T1/T3/T4 좌표 변환·굴절")
struct TransformTests {
    @Test("T1: R is a proper rotation (R·Rᵀ ≈ I, det ≈ 1)")
    func rotationIsOrthonormal() {
        for obs in observers {
            for date in sampleDates {
                let r = HorizonTransform.make(date: date, observer: obs)
                let i = r * r.transpose
                for c in 0..<3 {
                    for k in 0..<3 {
                        #expect(abs(i[c][k] - (c == k ? 1 : 0)) < 1e-12)
                    }
                }
                #expect(abs(simd_determinant(r) - 1) < 1e-12)
            }
        }
    }

    @Test("T3: J2000→R→refraction matches Astronomy_Horizon(of-date, NORMAL) within 1′")
    func pipelineMatchesHorizon() {
        let engine = AstroEngine.shared
        for obs in observers {
            for date in sampleDates {
                let r = HorizonTransform.make(date: date, observer: obs)
                for body in SkyBody.allCases {
                    guard let v = engine.equatorJ2000Vector(body, date: date, observer: obs),
                          let eq = engine.equatorOfDate(body, date: date, observer: obs) else {
                        Issue.record("no position for \(body)"); continue
                    }
                    let ours = Refraction.refract(r * v)
                    let ref = engine.horizon(date: date, observer: obs, raHours: eq.raHours, decDeg: eq.decDeg, refracted: true)
                    let refVec = Horizontal.vector(altitudeDeg: ref.altitudeDeg, azimuthDeg: ref.azimuthDeg)
                    #expect(angleDeg(ours, refVec) <= 1.0 / 60.0, "\(body) \(obs) \(date)")
                }
            }
        }
    }

    @Test("T4: Saemundsson refraction golden values (degrees)")
    func refractionGolden() {
        let e = AstroEngine.shared
        // Computed from AE v2.1.19 source formula: (1.02 / tan(hd + 10.3/(hd + 5.11))) / 60,
        // hd clamped at −1°, then × (alt + 90)/89 below −1°.
        let golden: [(Double, Double)] = [(0.0, 0.4830321), (-0.57, 0.5732207), (-1.0, 0.6465806), (-2.0, 0.6393157)]
        for (alt, expected) in golden {
            #expect(abs(e.refraction(altitudeDeg: alt) - expected) <= 1e-6, "alt \(alt)")
        }
        // Continuous across −1° (no gate): a gate would jump by ~0.65°; the true slope there is
        // ≈ 0.17°/°, so 0.002° apart differs by ≈ 2e-4°.
        #expect(abs(e.refraction(altitudeDeg: -0.999) - e.refraction(altitudeDeg: -1.001)) < 1e-3)
    }

    @Test("T4: inverse refraction round-trip ≤ 0.01′ over the whole sky (dense sweep)",
          .timeLimit(.minutes(1)))
    func inverseRoundTrip() {
        let e = AstroEngine.shared
        var worst = 0.0
        for i in 0...18_000 {
            let alt = -90.0 + Double(i) * 0.01
            let bent = alt + e.refraction(altitudeDeg: alt)
            let back = bent + e.inverseRefraction(bentAltitudeDeg: bent)
            worst = max(worst, abs(back - alt) * 60)
        }
        #expect(worst <= 0.01, "worst \(worst)′")
    }

    @Test("Inverse refraction terminates at the zenith, the ±1-ulp band and NaN (AE loop has no cap)",
          .timeLimit(.minutes(1)))
    func inverseRefractionEdgeCases() {
        let e = AstroEngine.shared
        #expect(e.inverseRefraction(bentAltitudeDeg: 90.0) == 0)
        #expect(e.inverseRefraction(bentAltitudeDeg: 89.99997) == 0)
        #expect(abs(e.inverseRefraction(bentAltitudeDeg: 89.9)) < 1e-5)
        #expect(e.inverseRefraction(bentAltitudeDeg: .nan) == 0)
        #expect(e.inverseRefraction(bentAltitudeDeg: 95) == 0)
        for b in [-67.96672283963196, -89.85615852749538, -90.0] {
            let d = e.inverseRefraction(bentAltitudeDeg: b)
            #expect(d.isFinite)
            #expect(abs((b + d) + e.refraction(altitudeDeg: b + d) - b) < 1e-9, "b \(b)")
        }
        // Vectors: zenith stays the zenith; zero / NaN vectors are passed through, never turned into +90°.
        #expect(simd_distance(Refraction.unrefract(U), U) < 1e-12)
        #expect(simd_distance(Refraction.refract(U), U) < 1e-9)
        #expect(Refraction.unrefract(SIMD3<Double>(0, 0, 0)) == SIMD3<Double>(0, 0, 0))
        #expect(Horizontal.altAz(SIMD3<Double>(.nan, 0, 1)).altitudeDeg.isNaN)
        #expect(ConstellationLocator.locate(j2000: SIMD3<Double>(0, 0, 0)) == nil)
    }

    @Test("Time anchor: J2000 epoch is ut = 0 and Date ↔ astro_time_t round-trips")
    func timeAnchor() {
        #expect(AstroEngine.astroTime(utc("2000-01-01T12:00:00Z")).ut == 0)
        for d in sampleDates {
            #expect(abs(AstroEngine.date(AstroEngine.astroTime(d)).timeIntervalSince(d)) < 1e-3)
        }
    }

    /// External reference (independent of Astronomy Engine): JPL Horizons API, observer Seoul
    /// (126.9780E, 37.5665N, 0.038 km), APPARENT='AIRLESS', queried 2026-09-29.
    @Test("T6: geometric alt/az matches JPL Horizons (Sun/Jupiter ≤ 1′, Moon ≤ 2′)")
    func horizonsReference() throws {
        let engine = AstroEngine.shared
        let cases: [(SkyBody, String, Double, Double, Double)] = [
            (.sun, "2026-09-29T10:00:00Z", 273.767403677, -8.964608760, 1),
            (.moon, "2026-09-29T10:00:00Z", 60.828115419, -5.186596336, 2),
            (.sun, "2026-12-21T03:00:00Z", 172.168969086, 28.590124496, 1),
            (.jupiter, "2026-12-21T15:00:00Z", 92.929788008, 26.053041712, 1),
        ]
        for (body, iso, az, el, tolArcmin) in cases {
            let date = utc(iso)
            let v = try #require(engine.equatorJ2000Vector(body, date: date, observer: .seoul))
            let ours = HorizonTransform.make(date: date, observer: .seoul) * v
            let ref = Horizontal.vector(altitudeDeg: el, azimuthDeg: az)
            #expect(angleDeg(ours, ref) * 60 <= tolArcmin, "\(body) \(iso): \(angleDeg(ours, ref) * 60)′")
        }
    }

    @Test("T4: Polaris altitude ≈ latitude ± 1°")
    func polarisAltitude() {
        let polaris = j2000(raHours: 2 + 31.0 / 60 + 49.09 / 3600, decDeg: 89 + 15.0 / 60 + 50.8 / 3600)
        let obs = ObserverLocation.seoul
        for hour in stride(from: 0.0, to: 24.0, by: 3.0) {
            let date = utc("2026-10-01T00:00:00Z").addingTimeInterval(hour * 3600)
            let h = HorizonTransform.make(date: date, observer: obs) * polaris
            #expect(abs(Horizontal.altAz(h).altitudeDeg - obs.latitude) <= 1.0)
        }
    }

    @Test("T4: upper culmination azimuth — δ<φ → south (180°), δ>φ → north (0°)")
    func transitAzimuth() throws {
        let engine = AstroEngine.shared
        let obs = ObserverLocation.seoul
        let start = utc("2026-10-01T00:00:00Z")
        // Altair (δ ≈ +8.87° < φ) and Vega (δ ≈ +38.78° > φ = 37.57°), J2000.
        let cases: [(ra: Double, dec: Double, expectedAz: Double)] = [
            (19 + 50.0 / 60 + 47.0 / 3600, 8 + 52.0 / 60 + 6.0 / 3600, 180),
            (18 + 36.0 / 60 + 56.336 / 3600, 38 + 47.0 / 60 + 1.28 / 3600, 0),
        ]
        for c in cases {
            let t = try #require(engine.starCulmination(raHours: c.ra, decDeg: c.dec, observer: obs, after: start))
            let h = HorizonTransform.make(date: t, observer: obs) * j2000(raHours: c.ra, decDeg: c.dec)
            let az = Horizontal.altAz(h).azimuthDeg
            #expect(abs(wrap180(az - c.expectedAz)) <= 0.5, "az \(az) expected \(c.expectedAz)")
        }
    }

    @Test("Constellation lookup: Polaris → UMi, Betelgeuse → Ori")
    func constellations() {
        #expect(ConstellationLocator.locate(j2000: j2000(raHours: 2.530303, decDeg: 89.264111)) == "UMi")
        #expect(ConstellationLocator.locate(j2000: j2000(raHours: 5.919529, decDeg: 7.407064)) == "Ori")
    }
}
