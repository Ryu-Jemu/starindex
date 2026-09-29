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
        location.onAuthorizationChange = { [weak self] authorized in
            // First launch starts motion before the permission answer (magnetic); move up to true north.
            guard let self, self.useSensors else { return }
            CoreMotionAttitudeProvider.shared.locationAuthorizationChanged(authorized: authorized)
        }
        useSensors = CoreMotionAttitudeProvider.isAvailable
        #endif
    }

    // MARK: Lifecycle

    /// DEBUG-only launch arguments for automated screenshots / demo rehearsal:
    /// `-look <az>,<alt>` (manual view), `-fov <deg>`, `-playSunset`, `-diag` (panel + stderr log, G3/G5).
    func applyDebugLaunchArguments(_ args: [String] = ProcessInfo.processInfo.arguments) {
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
        if args.contains("-diag") {
            diagnostics.showsPanel = true
            diagnostics.logsToConsole = true
        }
        #endif
    }

    func activate() {
        #if os(iOS)
        if location.authorization == .notDetermined { location.requestAuthorization() }
        location.startActive()
        if useSensors { CoreMotionAttitudeProvider.shared.start(locationAuthorized: location.isAuthorized) }
        #endif
    }

    func deactivate() {
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
        filter.reset()
        if useSensors {
            CoreMotionAttitudeProvider.shared.start(locationAuthorized: location.isAuthorized)
            calibration.motionRestarted()
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
    }

    func goLive() {
        clock.mode = .live
        snapshotUptime = -1
    }

    var isPlaying: Bool { !clock.isLive }

    // MARK: Per frame

    /// Called from the TimelineView on every frame.
    func frame(size: CGSize, uptime: TimeInterval, now: Date) -> (SkyFrame, SkySnapshot) {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let t = clock.date(atUptime: uptime, wallNow: now)
        if !clock.isLive || uptime - snapshotUptime >= 1 || snapshotUptime < 0 {
            snapshot = SkySnapshot.build(catalog: catalog, date: t.date, observer: observer)
            snapshotUptime = uptime
        }
        let camera = CameraModel(viewportWidth: max(1, size.width), viewportHeight: max(1, size.height), fovVerticalDeg: fovDeg)
        let frame = SkyFrameBuilder.build(catalog: catalog, snapshot: snapshot, transform: currentTransform(), camera: camera)
        lastFrame = frame
        diagnostics.recordFrame(uptime: uptime, buildMs: Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        diagnostics.tick(uptime: uptime) { diagnosticsLines() }
        return (frame, snapshot)
    }

    private func currentTransform() -> FrameTransform {
        var sample: AttitudeSample?
        #if os(iOS)
        if useSensors, let s = CoreMotionAttitudeProvider.shared.latest() {
            // A frame change (fallback or upgrade) makes the old filter state meaningless.
            if s.kind != lastAttitudeKind { filter.reset() }
            sample = filter.filter(s)
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

    func drag(dx: Double, dy: Double, size: CGSize) {
        if useSensors { return }
        manual.drag(dx: dx, dy: dy, camera: CameraModel(viewportWidth: size.width, viewportHeight: size.height, fovVerticalDeg: fovDeg))
    }
}
