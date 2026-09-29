#if canImport(CoreMotion) && os(iOS)
import CoreMotion
import Foundation
import simd
import SkyCore

/// CoreMotion attitude with the frame fallback chain of plan 4.1 (`MotionFramePolicy`):
/// `.xTrueNorthZVertical` → `.xMagneticNorthZVertical` (+ declination table) → `.xArbitraryCorrectedZVertical`.
/// One `CMMotionManager` per app (Apple). Samples arrive on the main queue so errors such as
/// `CMErrorTrueNorthNotAvailable` are seen; the render loop reads the newest one with `latest()`.
@MainActor
public final class CoreMotionAttitudeProvider: AttitudeProvider {
    public static let shared = CoreMotionAttitudeProvider()

    public private(set) var kind: FrameKind = .cmTrueNorth
    public private(set) var isRunning = false
    /// Last CoreMotion error code for the current frame (G3 smoke log).
    public private(set) var lastErrorCode: Int?
    /// Seconds from starting the current frame to its first sample (G3 smoke log).
    public private(set) var firstSampleLatency: TimeInterval?
    /// Frames started in this process with the reason, oldest first (G3 smoke log).
    public private(set) var history: [String] = []

    private struct Raw: Sendable {
        var q: simd_quatd
        var speedDegPerSec: Double
        var timestamp: TimeInterval
        var magneticAccuracy: Int32
    }

    private let manager = CMMotionManager()
    private var policy = MotionFramePolicy()
    private var locationAuthorized = false
    private var startedAt: TimeInterval = 0
    private var raw: Raw?

    private init() {}

    public static var isAvailable: Bool { CMMotionManager().isDeviceMotionAvailable }

    private static var availableKinds: Set<FrameKind> {
        let frames = CMMotionManager.availableAttitudeReferenceFrames()
        var kinds: Set<FrameKind> = []
        if frames.contains(.xTrueNorthZVertical) { kinds.insert(.cmTrueNorth) }
        if frames.contains(.xMagneticNorthZVertical) { kinds.insert(.cmMagnetic) }
        if frames.contains(.xArbitraryCorrectedZVertical) { kinds.insert(.cmArbitrary) }
        return kinds
    }

    private static func referenceFrame(for kind: FrameKind) -> CMAttitudeReferenceFrame {
        switch kind {
        case .cmTrueNorth: .xTrueNorthZVertical
        case .cmMagnetic: .xMagneticNorthZVertical
        default: .xArbitraryCorrectedZVertical
        }
    }

    /// - Parameter locationAuthorized: `.xTrueNorthZVertical` needs location services.
    public func start(locationAuthorized: Bool) {
        self.locationAuthorized = locationAuthorized
        guard manager.isDeviceMotionAvailable, !isRunning,
              let k = policy.initialKind(locationAuthorized: locationAuthorized, available: Self.availableKinds) else { return }
        run(k, reason: "start")
    }

    public func start() { start(locationAuthorized: true) }

    public func stop() {
        guard isRunning else { return }
        manager.stopDeviceMotionUpdates()
        isRunning = false
        raw = nil
    }

    /// Location authorization changed: move up to true north when that becomes possible.
    public func locationAuthorizationChanged(authorized: Bool) {
        locationAuthorized = authorized
        guard isRunning, policy.shouldUpgrade(from: kind, locationAuthorized: authorized, available: Self.availableKinds) else { return }
        manager.stopDeviceMotionUpdates()
        run(.cmTrueNorth, reason: "location authorized")
    }

    public func latest() -> AttitudeSample? {
        guard isRunning else { return nil }
        guard let raw else {
            if MotionFramePolicy.timedOut(startedAt: startedAt, now: ProcessInfo.processInfo.systemUptime, hasSample: false) {
                fail("no sample in \(Int(MotionFramePolicy.firstSampleTimeout)) s")
            }
            return nil
        }
        let a = AttitudeConvention.current.referenceToDeviceMatrix(simd_matrix3x3(raw.q))
        return AttitudeSample(kind: kind, referenceToDevice: a, timestamp: raw.timestamp, angularSpeedDegPerSec: raw.speedDegPerSec)
    }

    /// Magnetic field calibration accuracy (magnetometer frames only).
    public var magneticFieldAccuracy: CMMagneticFieldCalibrationAccuracy? {
        raw.flatMap { CMMagneticFieldCalibrationAccuracy(rawValue: $0.magneticAccuracy) }
    }

    private func run(_ k: FrameKind, reason: String) {
        kind = k
        raw = nil
        lastErrorCode = nil
        firstSampleLatency = nil
        startedAt = ProcessInfo.processInfo.systemUptime
        history.append("\(k.rawValue) (\(reason))")
        manager.deviceMotionUpdateInterval = 1.0 / 60.0
        manager.showsDeviceMovementDisplay = true
        manager.startDeviceMotionUpdates(using: Self.referenceFrame(for: k), to: .main) { [weak self] motion, error in
            let sample = motion.map { m in
                let q = m.attitude.quaternion, r = m.rotationRate
                return Raw(q: simd_quatd(ix: q.x, iy: q.y, iz: q.z, r: q.w),
                           speedDegPerSec: (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot() * 180 / .pi,
                           timestamp: m.timestamp,
                           magneticAccuracy: m.magneticField.accuracy.rawValue)
            }
            let code = (error as NSError?)?.code
            guard let self else { return }
            MainActor.assumeIsolated { self.ingest(sample, errorCode: code) }
        }
        isRunning = true
    }

    private func ingest(_ sample: Raw?, errorCode: Int?) {
        guard isRunning else { return }
        if let errorCode {
            lastErrorCode = errorCode
            if kind == .cmTrueNorth, errorCode == Int(CMErrorTrueNorthNotAvailable.rawValue) {
                fail("CMErrorTrueNorthNotAvailable")
                return
            }
        }
        guard let sample else { return }
        if raw == nil { firstSampleLatency = ProcessInfo.processInfo.systemUptime - startedAt }
        raw = sample
    }

    private func fail(_ reason: String) {
        let failed = kind
        manager.stopDeviceMotionUpdates()
        isRunning = false
        raw = nil
        if let next = policy.fallback(from: failed, locationAuthorized: locationAuthorized, available: Self.availableKinds) {
            run(next, reason: "\(failed.rawValue) failed: \(reason)")
        } else {
            history.append("no motion frame left (\(failed.rawValue): \(reason))")
        }
    }
}
#endif
