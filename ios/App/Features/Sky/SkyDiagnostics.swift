import Foundation
import SkySensors
#if os(iOS)
import CoreLocation
#endif

/// Diagnostics for the on-device gates (plan 6.3):
/// - G3: which motion frame runs, time to first sample, CoreMotion error code, fallback history.
/// - G5: per-frame main-thread work (frame start → end of Canvas drawing), its build/draw parts and the
///   frame interval, p50/p95/max over the last 1500 frames (25 s at 60 Hz, longer than the ≤21 s playback).
///   A sunset playback is also timed as one segment and summarized when it ends.
/// Enabled with the launch argument `-diag` (Debug and Release) or, in Debug, a long press on the phase
/// title: shows a panel and writes one line every 2 s to stderr, which
/// `xcrun devicectl device process launch --console` streams to the Mac. Coordinates are never written (plan D4).
/// GPU time of the sky shader is not visible here; measure it with Instruments.
@MainActor
final class SkyDiagnostics {
    var showsPanel = false
    var logsToConsole = false {
        // A closed console pipe must not kill the app.
        didSet { if logsToConsole { signal(SIGPIPE, SIG_IGN) } }
    }
    private(set) var text = ""

    private static let capacity = 1500
    private var work = RollingPercentiles(capacity: capacity)
    private var build = RollingPercentiles(capacity: capacity)
    private var draw = RollingPercentiles(capacity: capacity)
    private var interval = RollingPercentiles(capacity: capacity)
    private var lastFrameUptime: TimeInterval?
    private var pendingFrameStartNs: UInt64?
    private var lastTextUptime: TimeInterval = -1
    private var lastLogUptime: TimeInterval = -1
    private var segment: String?
    private var lastSummary: String?
    private let launchUptime = ProcessInfo.processInfo.systemUptime

    #if DEBUG
    private static let configuration = "debug -Onone"
    #else
    private static let configuration = "release -O"
    #endif

    func recordFrame(uptime: TimeInterval, startNs: UInt64, buildMs: Double) {
        // Gaps over 1 s are app pauses, not dropped frames.
        if let last = lastFrameUptime, uptime - last < 1 { interval.add((uptime - last) * 1000) }
        lastFrameUptime = uptime
        build.add(buildMs)
        pendingFrameStartNs = startNs
    }

    func recordDraw(ms: Double) {
        draw.add(ms)
        // Pair with the frame that built this Canvas content; skipped renders leave no stale pairing.
        if let start = pendingFrameStartNs {
            work.add(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            pendingFrameStartNs = nil
        }
    }

    /// Starts timing a segment (e.g. the sunset playback) from empty windows.
    func beginSegment(_ label: String) {
        work = RollingPercentiles(capacity: Self.capacity)
        build = RollingPercentiles(capacity: Self.capacity)
        draw = RollingPercentiles(capacity: Self.capacity)
        interval = RollingPercentiles(capacity: Self.capacity)
        lastFrameUptime = nil
        pendingFrameStartNs = nil
        segment = label
    }

    /// Logs one summary line for the running segment and keeps it on the panel.
    func endSegment(note: String) {
        guard let label = segment else { return }
        segment = nil
        let summary = "summary \(label) (\(note), \(Self.configuration)): frames \(work.count)"
            + " · work p50 \(ms(work.percentile(50))) p95 \(ms(work.percentile(95))) max \(ms(work.maximum))"
            + " · build p95 \(ms(build.percentile(95))) · draw p95 \(ms(draw.percentile(95)))"
            + " · interval p50 \(ms(interval.percentile(50))) p95 \(ms(interval.percentile(95))) max \(ms(interval.maximum))"
            + " · thermal \(Self.thermalText)"
        lastSummary = summary
        write("[diag] " + summary + "\n")
    }

    /// Refreshes `text` twice a second and logs every 2 s; `lines` is only evaluated then.
    func tick(uptime: TimeInterval, lines: () -> [String]) {
        guard showsPanel || logsToConsole else { return }
        if uptime - lastTextUptime >= 0.5 {
            lastTextUptime = uptime
            text = (lines() + timingLines(uptime: uptime)).joined(separator: "\n")
        }
        if uptime - lastLogUptime >= 2 {
            lastLogUptime = uptime
            write("[diag] " + text.replacingOccurrences(of: "\n", with: " | ") + "\n")
        }
    }

    private func write(_ line: String) {
        guard logsToConsole else { return }
        do {
            try FileHandle.standardError.write(contentsOf: Data(line.utf8))
        } catch {
            logsToConsole = false
        }
    }

    private func timingLines(uptime: TimeInterval) -> [String] {
        var out = [
            "work ms (frame→draw end): p50 \(ms(work.percentile(50))) p95 \(ms(work.percentile(95))) max \(ms(work.maximum))"
                + " · build p95 \(ms(build.percentile(95))) · draw p95 \(ms(draw.percentile(95)))",
            "interval ms: p50 \(ms(interval.percentile(50))) p95 \(ms(interval.percentile(95))) max \(ms(interval.maximum)) · n \(interval.count)",
            "\(Self.configuration) · thermal \(Self.thermalText) · up \(Int(uptime - launchUptime)) s"
                + (segment.map { " · timing: \($0)" } ?? ""),
        ]
        if let lastSummary { out.append("last " + lastSummary) }
        return out
    }

    private func ms(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "–" }

    private static var thermalText: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}

extension SkyScene {
    /// Scene-side lines of the diagnostics panel (no coordinates).
    func diagnosticsLines() -> [String] {
        var out: [String] = []
        #if os(iOS)
        let m = CoreMotionAttitudeProvider.shared
        let state = !useSensors ? "off (manual)" : (m.isRunning ? m.kind.rawValue : (m.isExhausted ? "exhausted" : "stopped"))
        let first = m.firstSampleLatency.map { String(format: "%.2f s", $0) } ?? "–"
        let mag = m.magneticFieldAccuracy.map { String($0.rawValue) } ?? "–"
        out.append("motion: \(state) #\(m.sessionID) · first \(first) · err \(m.lastErrorCode.map(String.init) ?? "–") · mag \(mag) · cond \(m.condition)")
        out.append("history: " + (m.history.isEmpty ? "–" : m.history.suffix(3).joined(separator: " → ")))
        let auth: String = switch location.authorization {
        case .notDetermined: "notDetermined"
        case .denied: "denied"
        case .restricted: "restricted"
        case .authorizedWhenInUse: "whenInUse"
        case .authorizedAlways: "always"
        @unknown default: "unknown"
        }
        let precision = location.accuracyAuthorization == .reducedAccuracy ? "reduced" : "full"
        let hAcc = location.horizontalAccuracy.map { "±\(Int($0)) m" } ?? "no fix"
        let age = location.lastFix.map { "\(Int(Date().timeIntervalSince($0))) s ago" } ?? "–"
        let hdg = location.headingAccuracy.map { String(format: "±%.0f°", $0) } ?? "–"
        out.append("location: \(auth) · \(precision) · \(hAcc) · fix \(age) · heading \(hdg)")
        #endif
        let psi = calibration.entry(for: lastAttitudeKind)?.psiDeg ?? 0
        let az = lastFrame.map { String(format: "%.1f", $0.reticleAzimuth) } ?? "–"
        let alt = lastFrame.map { String(format: "%.1f", $0.reticleAltitude) } ?? "–"
        out.append("view: \(lastAttitudeKind.rawValue) ψ \(String(format: "%.1f", psi)) · reticle az \(az) alt \(alt) · fov \(Int(fovDeg))")
        out.append("clock: " + (isPlaying ? "playing, sky time \(displayedDate.formatted(date: .omitted, time: .shortened))" : "live"))
        return out
    }
}
