import simd

/// Which reference frame the attitude comes from. Calibration offsets (ψ) are stored per kind.
public enum FrameKind: String, CaseIterable, Sendable, Codable {
    /// CoreMotion `.xTrueNorthZVertical`.
    case cmTrueNorth
    /// CoreMotion `.xMagneticNorthZVertical` + declination table.
    case cmMagnetic
    /// CoreMotion `.xArbitraryCorrectedZVertical`; ψ must be re-aligned every motion restart.
    case cmArbitrary
    /// ARKit `.gravityAndHeading`.
    case arkitGravityHeading
    /// ARKit `.gravity` + native yaw injection.
    case arkitGravityYaw
    /// Drag-to-look; no sensor, no ψ.
    case manual
}

/// Maps horizontal (HOR) vectors to device coordinates and back.
///
/// Forward: `v_dev = A · Rz(ψ) · Rz(D) · h`
/// Inverse: `h = Rz(−D) · Rz(−ψ) · Aᵀ · v_dev`
///
/// - `A` (`referenceToDevice`) maps reference-frame vectors into device coordinates
///   (device x = right, y = top of screen, z = out of the screen; the rear camera looks along −z).
///   Whether CoreMotion's `rotationMatrix` equals `A` or `Aᵀ` is fixed at gate G2 in SkySensors.
/// - `D` (declination, east positive) applies only to `.cmMagnetic`.
/// - `ψ` (user calibration) is ignored for `.manual`.
public struct FrameTransform: Sendable {
    public var kind: FrameKind
    public var referenceToDevice: simd_double3x3
    public var psiDeg: Double
    public var declinationDeg: Double

    public init(kind: FrameKind, referenceToDevice: simd_double3x3, psiDeg: Double = 0, declinationDeg: Double = 0) {
        self.kind = kind
        self.referenceToDevice = referenceToDevice
        self.psiDeg = psiDeg
        self.declinationDeg = declinationDeg
    }

    public var effectiveDeclinationDeg: Double { kind == .cmMagnetic ? declinationDeg : 0 }
    public var effectivePsiDeg: Double { kind == .manual ? 0 : psiDeg }

    /// Rz(ψ) · Rz(D)
    public var correction: simd_double3x3 {
        Rotation.z(effectivePsiDeg) * Rotation.z(effectiveDeclinationDeg)
    }

    /// M_f = A · Rz(ψ) · Rz(D) — build once per frame, then multiply every star by it.
    public var forward: simd_double3x3 { referenceToDevice * correction }

    public func toDevice(_ horizontal: SIMD3<Double>) -> SIMD3<Double> {
        forward * horizontal
    }

    /// Device direction → horizontal (true-north) vector. Used by the reticle HUD and hit tests.
    public func toHorizontal(_ device: SIMD3<Double>) -> SIMD3<Double> {
        Rotation.z(-effectiveDeclinationDeg) * Rotation.z(-effectivePsiDeg)
            * referenceToDevice.transpose * device
    }

    /// Accumulating one-tap calibration: after the user aims the reticle at a body whose true
    /// azimuth is `trueAzimuthDeg`, returns the new ψ. Re-tapping the same target yields no change.
    public func calibratedPsi(trueAzimuthDeg: Double, reticleAzimuthDeg: Double) -> Double {
        wrap180(psiDeg + wrap180(trueAzimuthDeg - reticleAzimuthDeg))
    }

    /// Rows of the device→HOR rotation, as passed to the sky-color shader (r0, r1, r2).
    public var deviceToHorizontalRows: (SIMD3<Double>, SIMD3<Double>, SIMD3<Double>) {
        let m = Rotation.z(-effectiveDeclinationDeg) * Rotation.z(-effectivePsiDeg) * referenceToDevice.transpose
        let t = m.transpose
        return (t.columns.0, t.columns.1, t.columns.2)
    }
}
