import Foundation
import simd
import SkyCore

/// Heading quality shown as a badge (plan 4.1-4).
public enum HeadingQuality: Sendable, Equatable {
    case good, fair, poor, invalid, unknown

    /// From CLHeading.headingAccuracy (degrees; negative = invalid). Thresholds are provisional (G2).
    public static func from(headingAccuracy acc: Double?) -> HeadingQuality {
        guard let acc else { return .unknown }
        if acc < 0 { return .invalid }
        if acc <= 10 { return .good }
        if acc <= 25 { return .fair }
        return .poor
    }
}

/// One attitude reading, already mapped to A (reference → device).
public struct AttitudeSample: Sendable {
    public var kind: FrameKind
    public var referenceToDevice: simd_double3x3
    public var timestamp: TimeInterval
    /// Rotation rate magnitude in °/s (drives the adaptive filter).
    public var angularSpeedDegPerSec: Double

    public init(kind: FrameKind, referenceToDevice: simd_double3x3, timestamp: TimeInterval, angularSpeedDegPerSec: Double = 0) {
        self.kind = kind
        self.referenceToDevice = referenceToDevice
        self.timestamp = timestamp
        self.angularSpeedDegPerSec = angularSpeedDegPerSec
    }
}

@MainActor
public protocol AttitudeProvider: AnyObject {
    var kind: FrameKind { get }
    func start()
    func stop()
    /// Latest reading (polled once per rendered frame).
    func latest() -> AttitudeSample?
}

/// Frame-rate independent low-pass: q ← slerp(q, q_raw, α), α = 1 − exp(−Δt/τ),
/// τ = clamp(0.14 s − c·|ω|, 0.02 s, 0.14 s) — fast motion follows quickly, rest is smooth.
public struct AttitudeFilter: Sendable {
    public var tauMax = 0.14
    public var tauMin = 0.02
    public var c = 0.0012          // s per °/s (tuned at G2)
    private var q: simd_quatd?
    private var lastTimestamp: TimeInterval?

    public init() {}

    public mutating func reset() { q = nil; lastTimestamp = nil }

    public mutating func filter(_ sample: AttitudeSample) -> AttitudeSample {
        let raw = simd_quatd(sample.referenceToDevice)
        guard let prev = q, let t0 = lastTimestamp else {
            q = raw; lastTimestamp = sample.timestamp
            return sample
        }
        let dt = max(0, sample.timestamp - t0)
        let tau = min(tauMax, max(tauMin, tauMax - c * sample.angularSpeedDegPerSec))
        let alpha = 1 - exp(-dt / tau)
        // Shortest-arc slerp.
        let target = simd_dot(prev.vector, raw.vector) < 0 ? simd_quatd(vector: -raw.vector) : raw
        let next = simd_slerp(prev, target, alpha)
        q = next
        lastTimestamp = sample.timestamp
        var out = sample
        out.referenceToDevice = simd_matrix3x3(next)
        return out
    }
}
