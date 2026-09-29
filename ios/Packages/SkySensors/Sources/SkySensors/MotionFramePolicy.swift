import Foundation
import SkyCore

/// Location state that decides whether `.xTrueNorthZVertical` is worth trying (plan 4.1-1, gate G3).
/// `CMErrorTrueNorthNotAvailable` usually means "no location yet", so a new fix or a permission change
/// is a new condition under which true north may be retried.
public struct LocationCondition: Hashable, Sendable, CustomStringConvertible {
    public var authorized: Bool
    public var precise: Bool
    public var hasFix: Bool

    public init(authorized: Bool, precise: Bool = false, hasFix: Bool = false) {
        self.authorized = authorized
        self.precise = authorized && precise
        self.hasFix = authorized && hasFix
    }

    public static let unauthorized = LocationCondition(authorized: false)

    public var description: String {
        authorized ? "\(precise ? "precise" : "reduced")/\(hasFix ? "fix" : "no fix")" : "unauthorized"
    }
}

/// CoreMotion reference-frame choice and fallback (plan 4.1-1, gate G3).
/// Pure logic so it runs under `swift test` on macOS; `CoreMotionAttitudeProvider` applies it.
///
/// Order: `.xTrueNorthZVertical` → `.xMagneticNorthZVertical` (+ declination) → `.xArbitraryCorrectedZVertical`
/// → nothing left (the app falls back to manual). True north needs location authorization.
public struct MotionFramePolicy: Sendable, Equatable {
    /// No sample this long after starting a frame → the frame counts as failed (G3: fallback within 5 s).
    public static let firstSampleTimeout: TimeInterval = 5
    public static let chain: [FrameKind] = [.cmTrueNorth, .cmMagnetic, .cmArbitrary]

    /// Location condition under which true north last failed. It is retried only under a different
    /// condition, so retries are bounded by the few distinct conditions.
    public private(set) var trueNorthFailedUnder: LocationCondition?

    public init() {}

    /// First usable frame, or nil when device motion offers none of the chain.
    public func initialKind(condition: LocationCondition, available: Set<FrameKind>) -> FrameKind? {
        Self.chain.first { usable($0, condition: condition, available: available) }
    }

    /// `kind` failed under `condition`: the next frame to try, or nil (→ manual).
    public mutating func fallback(from kind: FrameKind, condition: LocationCondition, available: Set<FrameKind>) -> FrameKind? {
        if kind == .cmTrueNorth { trueNorthFailedUnder = condition }
        guard let i = Self.chain.firstIndex(of: kind) else { return nil }
        return Self.chain[(i + 1)...].first { usable($0, condition: condition, available: available) }
    }

    /// The location condition changed while a lower frame runs: move up to true north if it is usable now.
    public func shouldUpgrade(from current: FrameKind, condition: LocationCondition, available: Set<FrameKind>) -> Bool {
        current != .cmTrueNorth && Self.chain.contains(current)
            && usable(.cmTrueNorth, condition: condition, available: available)
    }

    public static func timedOut(startedAt: TimeInterval, now: TimeInterval, hasSample: Bool) -> Bool {
        !hasSample && now - startedAt >= firstSampleTimeout
    }

    private func usable(_ kind: FrameKind, condition: LocationCondition, available: Set<FrameKind>) -> Bool {
        guard available.contains(kind) else { return false }
        return kind != .cmTrueNorth || (condition.authorized && condition != trueNorthFailedUnder)
    }
}

/// Fixed-size ring buffer with nearest-rank percentiles, for the G5 frame-time log.
public struct RollingPercentiles: Sendable {
    private var values: [Double]
    private var next = 0
    public private(set) var count = 0

    public init(capacity: Int = 600) {
        values = Array(repeating: 0, count: max(1, capacity))
    }

    public mutating func add(_ v: Double) {
        guard v.isFinite else { return }
        values[next] = v
        next = (next + 1) % values.count
        count = min(count + 1, values.count)
    }

    /// Nearest-rank percentile, `p` in 0...100; nil when empty.
    public func percentile(_ p: Double) -> Double? {
        guard count > 0 else { return nil }
        let sorted = values[0..<count].sorted()
        let rank = Int((min(100, max(0, p)) / 100 * Double(count)).rounded(.up))
        return sorted[max(0, rank - 1)]
    }

    public var maximum: Double? { count > 0 ? values[0..<count].max() : nil }
}
