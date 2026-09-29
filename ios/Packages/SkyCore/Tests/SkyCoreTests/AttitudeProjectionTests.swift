import Foundation
import Testing
import simd
@testable import SkyCore

/// T7: synthetic attitudes built from Apple's reference-frame definition
/// (identity = screen up, device x toward the reference x axis). The CoreMotion A/Aᵀ
/// convention itself is provisional until the on-device G2 session re-runs these.
@Suite("T7 합성 자세·투영")
struct AttitudeProjectionTests {
    let camera = CameraModel(viewportWidth: 390, viewportHeight: 844, fovVerticalDeg: 60)

    func centerAzAlt(_ ft: FrameTransform) -> (az: Double, alt: Double) {
        let d = Projector.unproject(camera.center, camera: camera)
        let (alt, az) = Horizontal.altAz(ft.toHorizontal(d))
        return (az, alt)
    }

    @Test("T-P1: portrait facing north → north horizon at center, screen right = east")
    func facingNorth() throws {
        let ft = FrameTransform(kind: .cmTrueNorth, referenceToDevice: attitude(x: E, y: U, z: -N))
        let p = try #require(Projector.project(ft.toDevice(N), camera: camera))
        #expect(simd_distance(p, camera.center) < 1e-6)
        let ne = Horizontal.vector(altitudeDeg: 0, azimuthDeg: 20)
        let q = try #require(Projector.project(ft.toDevice(ne), camera: camera))
        #expect(q.x > camera.center.x)
        #expect(abs(centerAzAlt(ft).az - 0) < 1e-9 || abs(centerAzAlt(ft).az - 360) < 1e-9)
    }

    @Test("T-P2: facing east → azimuth 90° at center")
    func facingEast() {
        let ft = FrameTransform(kind: .cmTrueNorth, referenceToDevice: attitude(x: S, y: U, z: W))
        let c = centerAzAlt(ft)
        #expect(abs(c.az - 90) < 1e-9)
        #expect(abs(c.alt) < 1e-9)
    }

    @Test("T-P3/T-P3b: one-tap calibration sign and accumulation")
    func calibration() throws {
        var ft = FrameTransform(kind: .cmTrueNorth, referenceToDevice: attitude(x: E, y: U, z: -N))
        // Reticle reads 0°, but the body the user aims at is truly at 10°.
        let reticle1 = centerAzAlt(ft).az
        ft.psiDeg = ft.calibratedPsi(trueAzimuthDeg: 10, reticleAzimuthDeg: reticle1)
        #expect(abs(ft.psiDeg - 10) < 1e-9)
        #expect(abs(centerAzAlt(ft).az - 10) < 1e-9)
        let target = Horizontal.vector(altitudeDeg: 0, azimuthDeg: 10)
        let p = try #require(Projector.project(ft.toDevice(target), camera: camera))
        #expect(simd_distance(p, camera.center) < 1e-6)
        // Tapping the same target again must not undo the correction.
        let before = ft.psiDeg
        ft.psiDeg = ft.calibratedPsi(trueAzimuthDeg: 10, reticleAzimuthDeg: centerAzAlt(ft).az)
        #expect(abs(ft.psiDeg - before) <= 0.1)
    }

    @Test("T-P4: declination applies only in .cmMagnetic")
    func declinationOnlyMagnetic() {
        let a = attitude(x: E, y: U, z: -N)
        let trueNorth = FrameTransform(kind: .cmTrueNorth, referenceToDevice: a, declinationDeg: -9.02)
        let magnetic = FrameTransform(kind: .cmMagnetic, referenceToDevice: a, declinationDeg: -9.02)
        let azTrue = centerAzAlt(trueNorth).az
        let azMag = centerAzAlt(magnetic).az
        #expect(abs(wrap180(azTrue - 0)) < 1e-9)
        // Magnetic north in Seoul lies 9.02° west of true north.
        #expect(abs(wrap180(azMag - (360 - 9.02))) < 1e-9)
        #expect(abs(abs(wrap180(azTrue - azMag)) - 9.02) <= 0.5)
        // East declination (e.g. Cupertino) has the opposite sign.
        let east = FrameTransform(kind: .cmMagnetic, referenceToDevice: a, declinationDeg: 13)
        #expect(abs(wrap180(centerAzAlt(east).az - 13)) < 1e-9)
    }

    @Test("T-P5: screen facing down → zenith at center, stable under roll ±30°")
    func zenithFacingDown() throws {
        for roll in [-30.0, 0.0, 30.0] {
            let r = roll * Double.pi / 180
            let x = cos(r) * W + sin(r) * N
            let y = -sin(r) * W + cos(r) * N
            let ft = FrameTransform(kind: .cmTrueNorth, referenceToDevice: attitude(x: x, y: y, z: -U))
            let p = try #require(Projector.project(ft.toDevice(U), camera: camera))
            #expect(simd_distance(p, camera.center) < 1e-6, "roll \(roll)")
        }
    }

    @Test("Identity attitude (screen up) looks at the nadir")
    func identityLooksDown() throws {
        let ft = FrameTransform(kind: .cmTrueNorth, referenceToDevice: matrix_identity_double3x3)
        let p = try #require(Projector.project(ft.toDevice(-U), camera: camera))
        #expect(simd_distance(p, camera.center) < 1e-6)
    }

    @Test("Manual frame ignores ψ; shader rows equal toHorizontal")
    func manualAndShaderRows() {
        let a = attitude(x: E, y: U, z: -N)
        let manual = FrameTransform(kind: .manual, referenceToDevice: a, psiDeg: 25, declinationDeg: -9)
        #expect(abs(wrap180(centerAzAlt(manual).az)) < 1e-9)
        let ft = FrameTransform(kind: .cmMagnetic, referenceToDevice: a, psiDeg: 7, declinationDeg: -9)
        let (r0, r1, r2) = ft.deviceToHorizontalRows
        let v = simd_normalize(SIMD3<Double>(0.3, -0.2, -1))
        let viaRows = SIMD3(simd_dot(r0, v), simd_dot(r1, v), simd_dot(r2, v))
        #expect(simd_distance(viaRows, ft.toHorizontal(v)) < 1e-12)
    }

    @Test("Projection round-trip ≤ 0.5 px")
    func projectionRoundTrip() throws {
        for x in stride(from: 10.0, through: 380.0, by: 61.0) {
            for y in stride(from: 10.0, through: 834.0, by: 137.0) {
                let p = SIMD2(x, y)
                let q = try #require(Projector.project(Projector.unproject(p, camera: camera), camera: camera))
                #expect(simd_distance(p, q) <= 0.5)
            }
        }
    }
}
