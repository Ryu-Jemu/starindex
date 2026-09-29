import Foundation
import simd

/// Pinhole camera looking along device −z. Screen coordinates: x to the right, y downward.
public struct CameraModel: Sendable, Equatable {
    public var viewportWidth: Double
    public var viewportHeight: Double
    /// Vertical field of view in degrees (default 60°, pinch range 20–100°).
    public var fovVerticalDeg: Double

    public init(viewportWidth: Double, viewportHeight: Double, fovVerticalDeg: Double = 60) {
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
        self.fovVerticalDeg = min(100, max(20, fovVerticalDeg))
    }

    /// Focal length in points: f = (H/2) / tan(φv/2).
    public var focal: Double { (viewportHeight / 2) / tan(fovVerticalDeg * Double.pi / 360) }
    public var center: SIMD2<Double> { SIMD2(viewportWidth / 2, viewportHeight / 2) }
    /// Half-angle of the screen diagonal.
    public var diagonalHalfAngleRad: Double { atan(hypot(viewportWidth / 2, viewportHeight / 2) / focal) }
}

public enum Projector {
    /// Projects a device-space direction to the screen, or nil when outside the view cone
    /// (diagonal half-angle + margin).
    public static func project(_ v: SIMD3<Double>, camera: CameraModel, marginDeg: Double = 5) -> SIMD2<Double>? {
        let len = simd_length(v)
        guard len > 0 else { return nil }
        let forwardComponent = -v.z
        let limit = min(camera.diagonalHalfAngleRad + marginDeg * Double.pi / 180, Double.pi / 2 - 1e-6)
        guard forwardComponent > len * cos(limit) else { return nil }
        let f = camera.focal, c = camera.center
        return SIMD2(c.x + f * v.x / forwardComponent, c.y - f * v.y / forwardComponent)
    }

    /// Screen point → unit direction in device space.
    public static func unproject(_ p: SIMD2<Double>, camera: CameraModel) -> SIMD3<Double> {
        let f = camera.focal, c = camera.center
        return simd_normalize(SIMD3((p.x - c.x) / f, -(p.y - c.y) / f, -1))
    }
}
