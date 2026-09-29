import Foundation
import SkyCore

/// CoreMotion reference-frame choice and fallback (plan 4.1-1, gate G3).
/// Pure logic so it runs under `swift test` on macOS; `CoreMotionAttitudeProvider` applies it.
///
/// Order: `.xTrueNorthZVertical` → `.xMagneticNorthZVertical` (+ declination) → `.xArbitraryCorrectedZVertical`
/// → nothing left (the app falls back to manual). True north needs location authorization.
public struct MotionFramePolicy: Sendable, Equatable {
    /// No sample this long after starting a frame → the frame counts as failed (G3: fallback within 5 s).
    public static let firstSampleTimeout: TimeInterval = 5
    public static let chain: [FrameKind] = [.cmTrueNorth, .cmMagnetic, .cmArbitrary]

    /// True north failed once in this process (error or timeout); it is not retried.
    public private(set) var trueNorthFailed = false

    public init() {}

    /// First usable frame, or nil when device motion offers none of the chain.
    public func initialKind(locationAuthorized: Bool, available: Set<FrameKind>) -> FrameKind? {
        Self.chain.first { usable($0, locationAuthorized: locationAuthorized, available: available) }
    }

    /// `kind` failed: the next frame to try, or nil (→ manual).
    public mutating func fallback(from kind: FrameKind, locationAuthorized: Bool, available: Set<FrameKind>) -> FrameKind? {
        if kind == .cmTrueNorth { trueNorthFailed = true }
        guard let i = Self.chain.firstIndex(of: kind) else { return nil }
        return Self.chain[(i + 1)...].first { usable($0, locationAuthorized: locationAuthorized, available: available) }
    }

    /// Location became authorized while a lower frame runs: move up to true north unless it already failed.
    public func shouldUpgrade(from current: FrameKind, locationAuthorized: Bool, available: Set<FrameKind>) -> Bool {
        current != .cmTrueNorth && Self.chain.contains(current)
            && usable(.cmTrueNorth, locationAuthorized: locationAuthorized, available: available)
    }

    public static func timedOut(startedAt: TimeInterval, now: TimeInterval, hasSample: Bool) -> Bool {
        !hasSample && now - startedAt >= firstSampleTimeout
    }

    private func usable(_ kind: FrameKind, locationAuthorized: Bool, available: Set<FrameKind>) -> Bool {
        guard available.contains(kind) else { return false }
        return kind != .cmTrueNorth || (locationAuthorized && !trueNorthFailed)
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
