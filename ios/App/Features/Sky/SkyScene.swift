import Foundation
import Observation
import simd
import SkyCore
import SkySensors
#if os(iOS)
import CoreMotion
#endif

/// Owns the catalog, time, observer and attitude; produces one `SkyFrame` per rendered frame.
@MainActor
@Observable
final class SkyScene {
    let catalog: SkyCatalog
    private(set) var observer: ObserverLocation = .seoul
    private(set) var observerIsDefault = true
    var useSensors = false
    var fovDeg: Double = 60
    private(set) var clock = SkyClock()
    var selected: SkyObjectRef?

    let manual = ManualAttitudeProvider(azimuthDeg: 180, altitudeDeg: 25)
    @ObservationIgnored let calibration = CalibrationStore()
    @ObservationIgnored private var filter = AttitudeFilter()
    @ObservationIgnored private var snapshot: SkySnapshot
    @ObservationIgnored private var snapshotUptime: TimeInterval = -1
    @ObservationIgnored private(set) var lastFrame: SkyFrame?
    @ObservationIgnored private(set) var lastAttitudeKind: FrameKind = .manual
    @ObservationIgnored let diagnostics = SkyDiagnostics()
    /// Motion session seen last frame; a new one resets per-session state.
    @ObservationIgnored private var motionSession = -1
    /// Last filtered sensor pose, held while a new motion frame waits for its first sample.
    @ObservationIgnored private var lastSensorSample: AttitudeSample?
    /// A sunset playback whose timing summary has not been logged yet.
    @ObservationIgnored private var playbackSummaryPending = false
    /// Between activate() and deactivate() (foreground); location callbacks may not start sensors otherwise.
    @ObservationIgnored private var isActive = false

    #if os(iOS)
    @ObservationIgnored let location = LocationProvider()
    #endif

    init() {
        guard let url = Bundle.main.url(forResource: "skypack-v1", withExtension: "bin"),
              let data = try? Data(contentsOf: url),
              let catalog = try? SkyPackDecoder.decode(data) else {
            fatalError("skypack-v1.bin missing from the app bundle")
        }
        self.catalog = catalog
        self.snapshot = SkySnapshot.build(catalog: catalog, date: Date(), observer: .seoul)
        #if os(iOS)
        location.onUpdate = { [weak self] obs in self?.setObserver(obs, isDefault: false) }
        location.onConditionChange = { [weak self] condition in
            // First launch starts motion before the permission answer (magnetic); move up to true north,
            // and retry true north after the first fix or a precision change.
            guard let self, self.useSensors, self.isActive else { return }
            CoreMotionAttitudeProvider.shared.locationConditionChanged(condition)
        }
        useSensors = CoreMotionAttitudeProvider.isAvailable
        #endif
    }

    // MARK: Lifecycle

    /// Launch arguments (only a developer can pass them, e.g. with `devicectl`):
    /// - `-diag`: diagnostics panel + stderr log (G3/G5). Also in Release, so G5 is measured with optimization.
    /// - DEBUG only, for screenshots and demo rehearsal: `-look <az>,<alt>` (manual view), `-fov <deg>`, `-playSunset`,
    ///   `-select <name>` (open the detail sheet: a body as `saturn` or `토성`, a star by its catalog name such as
    ///   `Sirius`, a constellation by abbreviation such as `Ori`).
    /// - DEBUG only, handled by `IndexStore.applyLaunchArguments`: `-openIndexSheet` (open the index sheet, large),
    ///   `-indexNow <ISO-8601>` (evaluate the chip's "tonight"/staleness at that instant, e.g. for the golden pack
    ///   `2026-10-12T21:00+09:00`; the sky itself stays live).
    func applyLaunchArguments(_ args: [String] = ProcessInfo.processInfo.arguments) {
        if args.contains("-diag") {
            diagnostics.showsPanel = true
            diagnostics.logsToConsole = true
        }
        #if DEBUG
        func value(after flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        if let look = value(after: "-look") {
            let parts = look.split(separator: ",").compactMap { Double($0) }
            if parts.count == 2 {
                useSensors = false
                manual.set(azimuthDeg: parts[0], altitudeDeg: parts[1])
            }
        }
        if let fov = value(after: "-fov").flatMap(Double.init) { fovDeg = min(100, max(20, fov)) }
        if args.contains("-playSunset") { playSunset() }
        if let name = value(after: "-select") { selected = objectRef(named: name) }
        #endif
    }

    /// Body by English or Korean name, star by catalog name, constellation by abbreviation or Korean name.
    func objectRef(named name: String) -> SkyObjectRef? {
        if let b = SkyBody.allCases.first(where: { $0.rawValue == name.lowercased() || $0.nameKo == name }) { return .body(b) }
        if let i = catalog.stars.firstIndex(where: { $0.name?.caseInsensitiveCompare(name) == .orderedSame }) { return .star(i) }
        if let i = catalog.constellations.firstIndex(where: { $0.abbr.caseInsensitiveCompare(name) == .orderedSame || $0.nameKo == name }) {
            return .constellation(i)
        }
        return nil
    }

    func activate() {
        isActive = true
        #if os(iOS)
        if location.authorization == .notDetermined { location.requestAuthorization() }
        location.startActive()
        if useSensors { CoreMotionAttitudeProvider.shared.start(condition: location.condition) }
        #endif
    }

    func deactivate() {
        isActive = false
        if playbackSummaryPending {
            // The uptime-based clock keeps running in the background; a later "finished" would be misleading.
            playbackSummaryPending = false
            diagnostics.endSegment(note: "interrupted (background)")
        }
        #if os(iOS)
        location.stopActive()
        CoreMotionAttitudeProvider.shared.stop()
        #endif
    }

    func setObserver(_ obs: ObserverLocation, isDefault: Bool) {
        observer = obs
        observerIsDefault = isDefault
        snapshotUptime = -1
    }

    func toggleSensors() {
        #if os(iOS)
        guard CoreMotionAttitudeProvider.isAvailable else { useSensors = false; return }
        useSensors.toggle()
        lastSensorSample = nil
        if useSensors {
            CoreMotionAttitudeProvider.shared.start(condition: location.condition)
        } else {
            CoreMotionAttitudeProvider.shared.stop()
        }
        #endif
    }

    // MARK: Time

    func playSunset(now: Date = Date()) {
        // Search from 6 h earlier so an evening tap replays *today's* sunset.
        guard let plan = SunsetPlaybackPlanner.plan(after: now.addingTimeInterval(-6 * 3600), observer: observer) else { return }
        clock.mode = .playing(plan, startUptime: ProcessInfo.processInfo.systemUptime)
        snapshotUptime = -1
        // G5 is judged on the playback (snapshot rebuilt every frame): time it as one segment.
        if playbackSummaryPending { diagnostics.endSegment(note: "restarted") }
        diagnostics.beginSegment(String(format: "sunset playback %.1f s", plan.totalRealSeconds))
        playbackSummaryPending = true
    }

    func goLive() {
        if playbackSummaryPending {
            playbackSummaryPending = false
            diagnostics.endSegment(note: "stopped early")
        }
        clock.mode = .live
        snapshotUptime = -1
    }

    var isPlaying: Bool { !clock.isLive }

    /// Time of the sky currently drawn (simulated during playback).
    var displayedDate: Date { snapshot.date }

    // MARK: Per frame

    /// Called from the TimelineView on every frame.
    func frame(size: CGSize, uptime: TimeInterval, now: Date) -> (SkyFrame, SkySnapshot) {
        let t = clock.date(atUptime: uptime, wallNow: now)
        // Diagnostics bookkeeping (percentile sorts, stderr) reports earlier frames and stays outside the
        // timed window below, so G5 numbers do not include the cost of measuring.
        if playbackSummaryPending, t.finished {
            playbackSummaryPending = false
            diagnostics.endSegment(note: "finished")
        }
        diagnostics.tick(uptime: uptime) { diagnosticsLines() }
        let t0 = DispatchTime.now().uptimeNanoseconds
        if !clock.isLive || uptime - snapshotUptime >= 1 || snapshotUptime < 0 {
            snapshot = SkySnapshot.build(catalog: catalog, date: t.date, observer: observer)
            snapshotUptime = uptime
        }
        let camera = CameraModel(viewportWidth: max(1, size.width), viewportHeight: max(1, size.height), fovVerticalDeg: fovDeg)
        let frame = SkyFrameBuilder.build(catalog: catalog, snapshot: snapshot, transform: currentTransform(), camera: camera)
        lastFrame = frame
        diagnostics.recordFrame(uptime: uptime, startNs: t0, buildMs: Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        return (frame, snapshot)
    }

    /// The sky as currently drawn, for the detail sheet. Unlike `frame(...)` it has no side effects: it neither
    /// replaces `lastFrame` (tap hit-testing would then use a 1×1 viewport) nor feeds the G5 diagnostics.
    /// Live, the ≤1 s old snapshot is reused; during playback (simulated time runs ×300–×850) one is built
    /// for the current simulated instant.
    func snapshotForDetails(now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> SkySnapshot {
        let t = clock.date(atUptime: uptime, wallNow: now).date
        if snapshot.observer == observer, abs(snapshot.date.timeIntervalSince(t)) <= 1 { return snapshot }
        return SkySnapshot.build(catalog: catalog, date: t, observer: observer)
    }

    private func currentTransform() -> FrameTransform {
        var sample: AttitudeSample?
        #if os(iOS)
        if useSensors {
            let motion = CoreMotionAttitudeProvider.shared
            // New session (start, fallback, upgrade): the filter state and the cmArbitrary ψ belong to the old
            // one. A session that `latest()` starts below returns no sample and is picked up next frame.
            if motion.sessionID != motionSession {
                motionSession = motion.sessionID
                filter.reset()
                calibration.motionRestarted()
            }
            if let s = motion.latest() {
                sample = filter.filter(s)
                lastSensorSample = sample
            } else if motion.isRunning {
                sample = lastSensorSample      // new frame waiting for its first sample (≤5 s): hold the last view
            } else {
                lastSensorSample = nil         // chain exhausted: manual view, drag enabled
            }
        }
        #endif
        let s = sample ?? manual.latest()!
        lastAttitudeKind = s.kind
        let psi = calibration.entry(for: s.kind)?.psiDeg ?? 0
        let declination = s.kind == .cmMagnetic ? (DeclinationTable.declination(id: "seoul") ?? 0) : 0
        return FrameTransform(kind: s.kind, referenceToDevice: s.referenceToDevice, psiDeg: psi, declinationDeg: declination)
    }

    /// Heading badge for the HUD (plan 4.1-4): CLHeading accuracy, else magnetometer calibration.
    var headingQuality: HeadingQuality {
        #if os(iOS)
        switch lastAttitudeKind {
        case .cmTrueNorth, .cmMagnetic:
            if let acc = location.headingAccuracy { return .from(headingAccuracy: acc) }
            guard let mag = CoreMotionAttitudeProvider.shared.magneticFieldAccuracy else { return .unknown }
            if mag == .high { return .good }
            if mag == .medium { return .fair }
            return mag == .low ? .poor : .invalid
        case .cmArbitrary:
            return .poor
        default:
            return .unknown
        }
        #else
        return .unknown
        #endif
    }

    // MARK: Interaction

    func hitTest(_ p: CGPoint) -> SkyObjectRef? {
        guard let targets = lastFrame?.hitTargets else { return nil }
        var best: (SkyObjectRef, Double)?
        for t in targets {
            let d = hypot(t.point.x - p.x, t.point.y - p.y)
            guard d <= 44 else { continue }
            let score = d - 4 * t.weight                   // prefer planets and bright stars
            if best == nil || score < best!.1 { best = (t.ref, score) }
        }
        return best?.0
    }

    /// Sensors move the view (manual drag is ignored) unless the motion chain ran out.
    var sensorsDriveView: Bool {
        #if os(iOS)
        useSensors && CoreMotionAttitudeProvider.shared.isRunning
        #else
        false
        #endif
    }

    func drag(dx: Double, dy: Double, size: CGSize) {
        if sensorsDriveView { return }
        manual.drag(dx: dx, dy: dy, camera: CameraModel(viewportWidth: size.width, viewportHeight: size.height, fovVerticalDeg: fovDeg))
    }
}
