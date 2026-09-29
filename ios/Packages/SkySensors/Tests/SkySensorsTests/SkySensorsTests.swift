import Foundation
import Testing
import simd
import SkyCore
@testable import SkySensors

@Suite("SkySensors")
struct SkySensorsTests {
    let camera = CameraModel(viewportWidth: 390, viewportHeight: 844)

    @Test("Manual attitude looks where it says", arguments: [(0.0, 0.0), (135.0, 28.0), (270.0, -10.0), (45.0, 85.0)])
    @MainActor
    func manualLooksAtTarget(az: Double, alt: Double) {
        let p = ManualAttitudeProvider(azimuthDeg: az, altitudeDeg: alt)
        let s = p.latest()!
        let ft = FrameTransform(kind: s.kind, referenceToDevice: s.referenceToDevice)
        let center = ft.toHorizontal(Projector.unproject(camera.center, camera: camera))
        let (a, h) = Horizontal.altAz(center)
        #expect(abs(wrap180(h - az)) < 1e-9 && abs(a - alt) < 1e-9)
        // Proper rotation.
        #expect(abs(simd_determinant(s.referenceToDevice) - 1) < 1e-12)
    }

    @Test("Manual drag: dragging right turns the view left; altitude is clamped")
    @MainActor
    func manualDrag() {
        let p = ManualAttitudeProvider(azimuthDeg: 180, altitudeDeg: 30)
        p.drag(dx: 100, dy: 0, camera: camera)
        #expect(p.azimuthDeg < 180)
        p.drag(dx: 0, dy: 10_000, camera: camera)
        #expect(p.altitudeDeg == 89.5)
    }

    @Test("Filter: frame-rate independent — 60 Hz and 30 Hz reach the same state after 0.5 s")
    func filterIndependentOfRate() {
        let start = ManualAttitudeProvider.referenceToDevice(azimuthDeg: 0, altitudeDeg: 0)
        let target = ManualAttitudeProvider.referenceToDevice(azimuthDeg: 40, altitudeDeg: 0)
        func run(hz: Double) -> simd_double3x3 {
            var f = AttitudeFilter()
            _ = f.filter(AttitudeSample(kind: .cmTrueNorth, referenceToDevice: start, timestamp: 0))
            var last = start
            var t = 0.0
            while t < 0.5 {
                t += 1 / hz
                last = f.filter(AttitudeSample(kind: .cmTrueNorth, referenceToDevice: target, timestamp: t)).referenceToDevice
            }
            return last
        }
        let a = run(hz: 60), b = run(hz: 30)
        let d = simd_quatd(a) * simd_quatd(b).inverse
        #expect(abs(d.angle) * 180 / .pi < 0.5)
    }

    @Test("Calibration store: per-kind, session-only kinds, manual never stored")
    func calibrationStore() throws {
        let suite = "starindex.tests.\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        let s = CalibrationStore(defaults: d)
        s.save(psiDeg: 7, for: .cmTrueNorth, regionId: "seoul")
        s.save(psiDeg: -3, for: .cmMagnetic, regionId: "seoul")
        s.save(psiDeg: 12, for: .cmArbitrary, regionId: "seoul")
        s.save(psiDeg: 99, for: .manual, regionId: "seoul")
        #expect(s.entry(for: .cmTrueNorth)?.psiDeg == 7)
        #expect(s.entry(for: .cmMagnetic)?.psiDeg == -3)
        #expect(s.entry(for: .cmArbitrary)?.psiDeg == 12)
        #expect(s.entry(for: .manual) == nil)
        s.motionRestarted()
        #expect(s.entry(for: .cmArbitrary) == nil)
        // Persisted kinds survive a new store instance; session-only kinds do not.
        let s2 = CalibrationStore(defaults: d)
        #expect(s2.entry(for: .cmTrueNorth)?.psiDeg == 7)
        let e = try #require(s2.entry(for: .cmTrueNorth))
        #expect(!s2.isStale(e, regionId: "seoul"))
        #expect(s2.isStale(e, regionId: "busan"))
        #expect(s2.isStale(e, regionId: "seoul", now: Date().addingTimeInterval(31 * 60)))
    }

    @Test("Motion frame policy: chain order, fallback, no retry of failed true north (G3)")
    func motionFramePolicy() {
        let all: Set<FrameKind> = [.cmTrueNorth, .cmMagnetic, .cmArbitrary]
        var p = MotionFramePolicy()
        // True north only with location authorization.
        #expect(p.initialKind(locationAuthorized: true, available: all) == .cmTrueNorth)
        #expect(p.initialKind(locationAuthorized: false, available: all) == .cmMagnetic)
        #expect(p.initialKind(locationAuthorized: true, available: [.cmArbitrary]) == .cmArbitrary)
        #expect(p.initialKind(locationAuthorized: true, available: []) == nil)
        // Authorization granted later: upgrade from magnetic, never from true north itself.
        #expect(p.shouldUpgrade(from: .cmMagnetic, locationAuthorized: true, available: all))
        #expect(!p.shouldUpgrade(from: .cmMagnetic, locationAuthorized: false, available: all))
        #expect(!p.shouldUpgrade(from: .cmTrueNorth, locationAuthorized: true, available: all))
        #expect(!p.shouldUpgrade(from: .manual, locationAuthorized: true, available: all))
        // Fallback walks the chain and ends in nil (→ manual).
        #expect(p.fallback(from: .cmTrueNorth, locationAuthorized: true, available: all) == .cmMagnetic)
        #expect(p.fallback(from: .cmMagnetic, locationAuthorized: true, available: all) == .cmArbitrary)
        #expect(p.fallback(from: .cmArbitrary, locationAuthorized: true, available: all) == nil)
        #expect(p.fallback(from: .cmTrueNorth, locationAuthorized: true, available: [.cmTrueNorth, .cmArbitrary]) == .cmArbitrary)
        // Once true north failed it is neither chosen nor upgraded to again.
        #expect(p.trueNorthFailed)
        #expect(p.initialKind(locationAuthorized: true, available: all) == .cmMagnetic)
        #expect(!p.shouldUpgrade(from: .cmMagnetic, locationAuthorized: true, available: all))
        // Watchdog: 5 s without a sample.
        #expect(!MotionFramePolicy.timedOut(startedAt: 10, now: 14.9, hasSample: false))
        #expect(MotionFramePolicy.timedOut(startedAt: 10, now: 15, hasSample: false))
        #expect(!MotionFramePolicy.timedOut(startedAt: 10, now: 60, hasSample: true))
    }

    @Test("Rolling percentiles: nearest rank, ring buffer wrap, non-finite ignored")
    func rollingPercentiles() {
        var r = RollingPercentiles(capacity: 100)
        #expect(r.percentile(95) == nil && r.maximum == nil)
        for v in 1...100 { r.add(Double(v)) }
        #expect(r.percentile(50) == 50 && r.percentile(95) == 95 && r.percentile(100) == 100 && r.percentile(0) == 1)
        // Wrap: the oldest 50 values (1...50) are replaced by 1000.
        for _ in 0..<50 { r.add(1000) }
        #expect(r.count == 100 && r.percentile(50) == 100 && r.percentile(51) == 1000 && r.maximum == 1000)
        r.add(.nan); r.add(.infinity)
        #expect(r.count == 100 && r.maximum == 1000)
    }

    @Test("Heading quality thresholds")
    func headingQuality() {
        #expect(HeadingQuality.from(headingAccuracy: -1) == .invalid)
        #expect(HeadingQuality.from(headingAccuracy: 8) == .good)
        #expect(HeadingQuality.from(headingAccuracy: 20) == .fair)
        #expect(HeadingQuality.from(headingAccuracy: 40) == .poor)
        #expect(HeadingQuality.from(headingAccuracy: nil) == .unknown)
    }
}
