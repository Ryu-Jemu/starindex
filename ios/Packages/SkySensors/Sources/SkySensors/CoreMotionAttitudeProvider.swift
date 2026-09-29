#if canImport(CoreMotion) && os(iOS)
import CoreMotion
import Foundation
import simd
import Synchronization
import SkyCore

/// CoreMotion attitude with the frame fallback chain of plan 4.1 (`MotionFramePolicy`):
/// `.xTrueNorthZVertical` → `.xMagneticNorthZVertical` (+ declination table) → `.xArbitraryCorrectedZVertical`.
/// One `CMMotionManager` per app (Apple). Samples and errors (e.g. `CMErrorTrueNorthNotAvailable`) arrive on a
/// private queue and land in `MotionInbox`; the render loop reads the newest one with `latest()`.
@MainActor
public final class CoreMotionAttitudeProvider: AttitudeProvider {
    public static let shared = CoreMotionAttitudeProvider()

    public private(set) var kind: FrameKind = .cmTrueNorth
    public private(set) var isRunning = false
    /// Every frame of the chain failed: the app shows the manual view until the next start or location change.
    public private(set) var isExhausted = false
    /// Increments on every start of motion updates (start, fallback, upgrade). Per-session state such as the
    /// attitude filter and the cmArbitrary ψ must be reset when it changes.
    public private(set) var sessionID = 0
    public private(set) var condition = LocationCondition.unauthorized
    /// Last CoreMotion error code of the current session (G3 smoke log).
    public private(set) var lastErrorCode: Int?
    /// Seconds from starting the current session to its first sample (G3 smoke log).
    public private(set) var firstSampleLatency: TimeInterval?
    /// Sessions started in this process with the reason, oldest first, last 12 kept (G3 smoke log).
    public private(set) var history: [String] = []

    private let manager = CMMotionManager()
    /// Stopping updates cancels every operation on the queue passed in, so CMMotionManager.h recommends a
    /// queue that is not used in other contexts.
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "starindex.coremotion"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInteractive
        return q
    }()
    private let inbox = MotionInbox()
    private var policy = MotionFramePolicy()
    private var startedAt: TimeInterval = 0
    private var reportedRequiresMovement = false

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

    public func start(condition: LocationCondition) {
        self.condition = condition
        guard manager.isDeviceMotionAvailable, !isRunning else { return }
        guard let k = policy.initialKind(condition: condition, available: Self.availableKinds) else {
            isExhausted = true
            appendHistory("no motion frame available")
            return
        }
        run(k, reason: "start")
    }

    public func start() { start(condition: condition) }

    public func stop() {
        guard isRunning else { return }
        manager.stopDeviceMotionUpdates()
        isRunning = false
        inbox.reset(generation: -1)
    }

    /// Location permission, precision or first fix changed: move up to true north when it becomes usable,
    /// or retry the chain after it ran out.
    public func locationConditionChanged(_ c: LocationCondition) {
        guard c != condition else { return }
        condition = c
        if isRunning {
            guard policy.shouldUpgrade(from: kind, condition: c, available: Self.availableKinds) else { return }
            manager.stopDeviceMotionUpdates()
            run(.cmTrueNorth, reason: "location \(c)")
        } else if isExhausted {
            start(condition: c)
        }
    }

    public func latest() -> AttitudeSample? {
        guard isRunning else { return nil }
        let s = inbox.snapshot()
        if let code = s.errorCode { lastErrorCode = code }
        if s.sawRequiresMovement, !reportedRequiresMovement {
            reportedRequiresMovement = true
            appendHistory("\(kind.rawValue): requires movement (101)")
        }
        if kind == .cmTrueNorth, s.errorCode == Int(CMErrorTrueNorthNotAvailable.rawValue) {
            fail("CMErrorTrueNorthNotAvailable")
            return nil
        }
        guard let raw = s.raw else {
            if MotionFramePolicy.timedOut(startedAt: startedAt, now: ProcessInfo.processInfo.systemUptime, hasSample: false) {
                fail("no sample in \(Int(MotionFramePolicy.firstSampleTimeout)) s" + (s.errorCode.map { ", last err \($0)" } ?? ""))
            }
            return nil
        }
        if firstSampleLatency == nil, let t = s.firstSampleUptime { firstSampleLatency = t - startedAt }
        let a = AttitudeConvention.current.referenceToDeviceMatrix(simd_matrix3x3(raw.q))
        return AttitudeSample(kind: kind, referenceToDevice: a, timestamp: raw.timestamp, angularSpeedDegPerSec: raw.speedDegPerSec)
    }

    /// Magnetic field calibration accuracy of the newest sample (magnetometer frames only).
    public var magneticFieldAccuracy: CMMagneticFieldCalibrationAccuracy? {
        guard isRunning, let raw = inbox.snapshot().raw else { return nil }
        return CMMagneticFieldCalibrationAccuracy(rawValue: raw.magneticAccuracy)
    }

    private func run(_ k: FrameKind, reason: String) {
        sessionID &+= 1
        let generation = sessionID
        inbox.reset(generation: generation)
        kind = k
        isRunning = true
        isExhausted = false
        lastErrorCode = nil
        firstSampleLatency = nil
        reportedRequiresMovement = false
        startedAt = ProcessInfo.processInfo.systemUptime
        appendHistory("\(k.rawValue) (\(reason))")
        manager.deviceMotionUpdateInterval = 1.0 / 60.0
        manager.showsDeviceMovementDisplay = true
        manager.startDeviceMotionUpdates(using: Self.referenceFrame(for: k), to: queue,
                                         withHandler: Self.handler(inbox: inbox, generation: generation))
    }

    private func fail(_ reason: String) {
        let failed = kind
        manager.stopDeviceMotionUpdates()
        isRunning = false
        inbox.reset(generation: -1)
        if let next = policy.fallback(from: failed, condition: condition, available: Self.availableKinds) {
            run(next, reason: "\(failed.rawValue) failed: \(reason)")
        } else {
            isExhausted = true
            appendHistory("no motion frame left (\(failed.rawValue): \(reason))")
        }
    }

    private func appendHistory(_ entry: String) {
        history.append(entry)
        if history.count > 12 { history.removeFirst(history.count - 12) }
    }

    /// Built outside the main actor: the handler runs on `queue`, never on the main thread.
    nonisolated private static func handler(inbox: MotionInbox, generation: Int) -> CMDeviceMotionHandler {
        { motion, error in
            let sample = motion.map { m in
                let q = m.attitude.quaternion, r = m.rotationRate
                return MotionInbox.Raw(q: simd_quatd(ix: q.x, iy: q.y, iz: q.z, r: q.w),
                                       speedDegPerSec: (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot() * 180 / .pi,
                                       timestamp: m.timestamp,
                                       magneticAccuracy: m.magneticField.accuracy.rawValue)
            }
            inbox.deliver(sample, errorCode: (error as NSError?)?.code, generation: generation,
                          now: ProcessInfo.processInfo.systemUptime)
        }
    }
}

/// Written on the motion queue, read by the render loop. The generation drops callbacks of an earlier
/// session that are still queued or running when the frame changes or updates stop.
final class MotionInbox: Sendable {
    struct Raw: Sendable {
        var q: simd_quatd
        var speedDegPerSec: Double
        var timestamp: TimeInterval
        var magneticAccuracy: Int32
    }

    struct State: Sendable {
        var generation = -1
        var raw: Raw?
        var errorCode: Int?
        var firstSampleUptime: TimeInterval?
        var sawRequiresMovement = false
    }

    private let state = Mutex(State())

    func reset(generation: Int) {
        state.withLock { $0 = State(generation: generation) }
    }

    func snapshot() -> State { state.withLock { $0 } }

    func deliver(_ sample: Raw?, errorCode: Int?, generation: Int, now: TimeInterval) {
        state.withLock { s in
            guard s.generation == generation else { return }
            if let errorCode {
                s.errorCode = errorCode
                if errorCode == Int(CMErrorDeviceRequiresMovement.rawValue) { s.sawRequiresMovement = true }
            }
            if let sample {
                if s.raw == nil { s.firstSampleUptime = now }
                s.raw = sample
            }
        }
    }
}
#endif
