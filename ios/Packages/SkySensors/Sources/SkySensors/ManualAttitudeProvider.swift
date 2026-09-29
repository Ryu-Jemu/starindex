import Foundation
import simd
import SkyCore

/// Drag-to-look attitude (no sensors; also the simulator default). Produces a portrait phone
/// whose rear camera looks at (azimuth, altitude).
@MainActor
public final class ManualAttitudeProvider: AttitudeProvider {
    public let kind: FrameKind = .manual
    public private(set) var azimuthDeg: Double
    public private(set) var altitudeDeg: Double
    private var velocity = SIMD2<Double>(0, 0)       // °/s (az, alt) for inertia
    private var lastTick: TimeInterval?

    public init(azimuthDeg: Double = 180, altitudeDeg: Double = 30) {
        self.azimuthDeg = azimuthDeg
        self.altitudeDeg = altitudeDeg
    }

    public func start() {}
    public func stop() { velocity = .zero }

    /// Drag by screen points: Δaz = −dx/W·φh, Δalt = dy/H·φv (drag right → look left, like a map).
    public func drag(dx: Double, dy: Double, camera: CameraModel) {
        let fovH = 2 * atan(tan(camera.fovVerticalDeg * Double.pi / 360) * camera.viewportWidth / camera.viewportHeight) * 180 / Double.pi
        set(azimuthDeg: azimuthDeg - dx / camera.viewportWidth * fovH,
            altitudeDeg: altitudeDeg + dy / camera.viewportHeight * camera.fovVerticalDeg)
    }

    public func fling(velocityPoints v: SIMD2<Double>, camera: CameraModel) {
        velocity = SIMD2(-v.x / camera.viewportWidth * 60, v.y / camera.viewportHeight * camera.fovVerticalDeg)
    }

    public func set(azimuthDeg: Double, altitudeDeg: Double) {
        var az = azimuthDeg.truncatingRemainder(dividingBy: 360)
        if az < 0 { az += 360 }
        self.azimuthDeg = az
        self.altitudeDeg = min(89.5, max(-89.5, altitudeDeg))
    }

    public func latest() -> AttitudeSample? {
        let now = ProcessInfo.processInfo.systemUptime
        if let t0 = lastTick, simd_length(velocity) > 0.5 {
            let dt = now - t0
            set(azimuthDeg: azimuthDeg + velocity.x * dt, altitudeDeg: altitudeDeg + velocity.y * dt)
            velocity *= exp(-dt / 0.35)
        }
        lastTick = now
        return AttitudeSample(kind: .manual,
                              referenceToDevice: Self.referenceToDevice(azimuthDeg: azimuthDeg, altitudeDeg: altitudeDeg),
                              timestamp: now)
    }

    /// A for a portrait phone looking at (az, alt) with the screen's top toward the zenith side.
    nonisolated public static func referenceToDevice(azimuthDeg: Double, altitudeDeg: Double) -> simd_double3x3 {
        let fwd = Horizontal.vector(altitudeDeg: altitudeDeg, azimuthDeg: azimuthDeg)
        let right = Horizontal.vector(altitudeDeg: 0, azimuthDeg: azimuthDeg + 90)
        let z = -fwd
        let y = simd_normalize(simd_cross(z, right))
        let x = simd_cross(y, z)
        return simd_double3x3(columns: (x, y, z)).transpose
    }
}
