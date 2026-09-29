#if canImport(CoreMotion) && os(iOS)
import CoreMotion
import Foundation
import simd
import SkyCore

/// CoreMotion attitude with the frame fallback chain of plan 4.1:
/// `.xTrueNorthZVertical` → `.xMagneticNorthZVertical` (+ declination table) → `.xArbitraryCorrectedZVertical`.
/// One `CMMotionManager` per app (Apple). Poll `latest()` from the render loop.
@MainActor
public final class CoreMotionAttitudeProvider: AttitudeProvider {
    public static let shared = CoreMotionAttitudeProvider()

    public private(set) var kind: FrameKind = .cmTrueNorth
    public private(set) var lastError: Error?
    private let manager = CMMotionManager()
    private var running = false

    private init() {}

    public static var isAvailable: Bool { CMMotionManager().isDeviceMotionAvailable }

    /// - Parameter locationAuthorized: xTrueNorthZVertical needs location services.
    public func start(locationAuthorized: Bool) {
        guard manager.isDeviceMotionAvailable, !running else { return }
        let available = CMMotionManager.availableAttitudeReferenceFrames()
        let frame: CMAttitudeReferenceFrame
        if locationAuthorized && available.contains(.xTrueNorthZVertical) {
            frame = .xTrueNorthZVertical; kind = .cmTrueNorth
        } else if available.contains(.xMagneticNorthZVertical) {
            frame = .xMagneticNorthZVertical; kind = .cmMagnetic
        } else {
            frame = .xArbitraryCorrectedZVertical; kind = .cmArbitrary
        }
        manager.deviceMotionUpdateInterval = 1.0 / 60.0
        manager.showsDeviceMovementDisplay = true
        manager.startDeviceMotionUpdates(using: frame)
        running = true
    }

    public func start() { start(locationAuthorized: true) }

    public func stop() {
        guard running else { return }
        manager.stopDeviceMotionUpdates()
        running = false
    }

    public func latest() -> AttitudeSample? {
        guard let m = manager.deviceMotion else { return nil }
        let q = m.attitude.quaternion
        let quat = simd_quatd(ix: q.x, iy: q.y, iz: q.z, r: q.w)
        let a = AttitudeConvention.current.referenceToDeviceMatrix(simd_matrix3x3(quat))
        let r = m.rotationRate
        let speed = sqrt(r.x * r.x + r.y * r.y + r.z * r.z) * 180 / Double.pi
        return AttitudeSample(kind: kind, referenceToDevice: a, timestamp: m.timestamp, angularSpeedDegPerSec: speed)
    }

    /// Magnetic field calibration accuracy (for the "move in a figure-8" coach mark).
    public var magneticFieldAccuracy: CMMagneticFieldCalibrationAccuracy? {
        manager.deviceMotion?.magneticField.accuracy
    }
}
#endif
