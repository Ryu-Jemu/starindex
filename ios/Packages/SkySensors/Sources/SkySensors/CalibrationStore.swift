import Foundation
import SkyCore

/// Persists the one-tap calibration offset ψ per frame kind (plan 4.1-5).
/// - `cmArbitrary` and `arkitGravityYaw` are per-session: never persisted.
/// - A stored ψ older than 30 min, or from another region, is only a suggestion (`isStale`).
public final class CalibrationStore: @unchecked Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var psiDeg: Double
        public var savedAt: Date
        public var regionId: String?
    }

    private let defaults: UserDefaults
    private let prefix = "calibration.psi."
    private var sessionOnly: [FrameKind: Entry] = [:]
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    static func isSessionOnly(_ kind: FrameKind) -> Bool { kind == .cmArbitrary || kind == .arkitGravityYaw }

    public func entry(for kind: FrameKind) -> Entry? {
        lock.withLock {
            if kind == .manual { return nil }
            if Self.isSessionOnly(kind) { return sessionOnly[kind] }
            guard let data = defaults.data(forKey: prefix + kind.rawValue) else { return nil }
            return try? JSONDecoder().decode(Entry.self, from: data)
        }
    }

    public func save(psiDeg: Double, for kind: FrameKind, regionId: String?, now: Date = Date()) {
        lock.withLock {
            guard kind != .manual else { return }
            let e = Entry(psiDeg: psiDeg, savedAt: now, regionId: regionId)
            if Self.isSessionOnly(kind) { sessionOnly[kind] = e; return }
            if let data = try? JSONEncoder().encode(e) { defaults.set(data, forKey: prefix + kind.rawValue) }
        }
    }

    public func reset(_ kind: FrameKind) {
        lock.withLock {
            sessionOnly[kind] = nil
            defaults.removeObject(forKey: prefix + kind.rawValue)
        }
    }

    /// Called when motion updates restart: arbitrary-frame offsets are meaningless afterwards.
    public func motionRestarted() {
        lock.withLock { sessionOnly[.cmArbitrary] = nil }
    }

    /// AR session restarted: gravity+yaw offsets reset.
    public func arSessionRestarted() {
        lock.withLock { sessionOnly[.arkitGravityYaw] = nil }
    }

    public func isStale(_ e: Entry, regionId: String?, now: Date = Date()) -> Bool {
        now.timeIntervalSince(e.savedAt) > 30 * 60 || (regionId != nil && e.regionId != regionId)
    }
}
