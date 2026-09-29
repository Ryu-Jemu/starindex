import Foundation
import SkySensors
#if os(iOS)
import CoreLocation
#endif

/// Diagnostics for the on-device gates (plan 6.3):
/// - G3: which motion frame runs, time to first sample, CoreMotion error code, fallback history.
/// - G5: frame build/draw time and frame interval, p50/p95/max over the last 600 frames.
/// Enabled with the DEBUG launch argument `-diag` (or a long press on the phase title): shows a panel
/// and writes one line every 2 s to stderr, which `xcrun devicectl device process launch --console`
/// streams to the Mac. Coordinates are never written (plan D4).
@MainActor
final class SkyDiagnostics {
    var showsPanel = false
    var logsToConsole = false
    private(set) var text = ""

    private var build = RollingPercentiles()
    private var draw = RollingPercentiles()
    private var interval = RollingPercentiles()
    private var lastFrameUptime: TimeInterval?
    private var lastTextUptime: TimeInterval = -1
    private var lastLogUptime: TimeInterval = -1
    private let launchUptime = ProcessInfo.processInfo.systemUptime

    func recordFrame(uptime: TimeInterval, buildMs: Double) {
        // Gaps over 1 s are app pauses, not dropped frames.
        if let last = lastFrameUptime, uptime - last < 1 { interval.add((uptime - last) * 1000) }
        lastFrameUptime = uptime
        build.add(buildMs)
    }

    func recordDraw(ms: Double) { draw.add(ms) }

    /// Refreshes `text` twice a second and logs every 2 s; `lines` is only evaluated then.
    func tick(uptime: TimeInterval, lines: () -> [String]) {
        guard showsPanel || logsToConsole else { return }
        if uptime - lastTextUptime >= 0.5 {
            lastTextUptime = uptime
            text = (lines() + timingLines(uptime: uptime)).joined(separator: "\n")
        }
        if logsToConsole, uptime - lastLogUptime >= 2 {
            lastLogUptime = uptime
            let line = "[diag] " + text.replacingOccurrences(of: "\n", with: " | ") + "\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
    }

    private func timingLines(uptime: TimeInterval) -> [String] {
        [
            "frame ms: build p50 \(ms(build.percentile(50))) p95 \(ms(build.percentile(95))) max \(ms(build.maximum))"
                + " · draw p50 \(ms(draw.percentile(50))) p95 \(ms(draw.percentile(95))) max \(ms(draw.maximum))",
            "interval ms: p50 \(ms(interval.percentile(50))) p95 \(ms(interval.percentile(95))) max \(ms(interval.maximum)) · n \(interval.count)",
            "thermal \(Self.thermalText) · up \(Int(uptime - launchUptime)) s",
        ]
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
        let state = !useSensors ? "off (manual)" : (m.isRunning ? m.kind.rawValue : "stopped")
        let first = m.firstSampleLatency.map { String(format: "%.2f s", $0) } ?? "–"
        let mag = m.magneticFieldAccuracy.map { String($0.rawValue) } ?? "–"
        out.append("motion: \(state) · first \(first) · err \(m.lastErrorCode.map(String.init) ?? "–") · mag \(mag)")
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
        return out
    }
}
