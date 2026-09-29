import SwiftUI
import SkyCore
import SkySensors

/// First screen: the sky around the user, following the phone's orientation (plan 4.0).
struct SkyScreen: View {
    @State private var scene = SkyScene()
    @State private var lastDrag: CGSize = .zero
    @State private var pinchBase: Double?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { timeline in
                let (frame, snap) = scene.frame(size: geo.size, uptime: ProcessInfo.processInfo.systemUptime, now: timeline.date)
                ZStack {
                    Canvas { ctx, _ in
                        let t0 = DispatchTime.now().uptimeNanoseconds
                        SkyRenderer.draw(frame, in: &ctx)
                        scene.diagnostics.recordDraw(ms: Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
                    }
                    SkyHUD(scene: scene, frame: frame, snapshot: snap)
                    if scene.diagnostics.showsPanel { DiagnosticsPanel(text: scene.diagnostics.text) }
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(size: geo.size))
            .simultaneousGesture(pinchGesture)
            .onTapGesture { p in scene.selected = scene.hitTest(p) }
        }
        .ignoresSafeArea()
        .sheet(item: Binding(get: { scene.selected.map(Selection.init) }, set: { scene.selected = $0?.ref })) { sel in
            ObjectDetailSheet(scene: scene, ref: sel.ref)
                .presentationDetents([.fraction(0.32), .medium])
        }
        .task { prewarmShader() }
        .onAppear {
            scene.activate()
            scene.applyDebugLaunchArguments()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { scene.activate() } else { scene.deactivate() }
        }
    }

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { v in
                let dx = v.translation.width - lastDrag.width, dy = v.translation.height - lastDrag.height
                lastDrag = v.translation
                scene.drag(dx: dx, dy: dy, size: size)
            }
            .onEnded { _ in lastDrag = .zero }
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { v in
                if pinchBase == nil { pinchBase = scene.fovDeg }
                scene.fovDeg = min(100, max(20, (pinchBase ?? 60) / v.magnification))
            }
            .onEnded { _ in pinchBase = nil }
    }

    /// Compile the sky shader ahead of the first frame (iOS 18+ API).
    private func prewarmShader() {
        let s = SkyRenderer.skyShader(.init(
            rect: CGRect(x: 0, y: 0, width: 1, height: 1), focal: 1,
            rows: (SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)), sun: SIMD3(0, 0, 1),
            zenith: .zero, anti: .zero, sunSide: .zero, night: .zero, ground: .zero, misc: .zero))
        Task { try? await s.compile(as: .shapeStyle) }
    }

    private struct Selection: Identifiable {
        let ref: SkyObjectRef
        var id: SkyObjectRef { ref }
    }
}

/// Attitude source and heading accuracy (plan 4.1-4): green ≤10°, yellow ≤25°, red otherwise.
struct HeadingBadge: View {
    let kind: FrameKind
    let quality: HeadingQuality

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.caption2)
        }
        .opacity(0.9)
    }

    private var label: String {
        switch kind {
        case .cmTrueNorth: "진북 기준"
        case .cmMagnetic: "자북 + 편각 보정"
        case .cmArbitrary: "방위 기준 없음 · 천체로 맞추세요"
        case .manual: "수동"
        default: kind.rawValue
        }
    }

    private var color: Color {
        switch quality {
        case .good: .green
        case .fair: .yellow
        case .poor, .invalid: .red
        case .unknown: .gray
        }
    }
}

/// DEBUG diagnostics text (G3/G5), see `SkyDiagnostics`.
struct DiagnosticsPanel: View {
    let text: String

    var body: some View {
        VStack {
            Spacer()
            Text(text)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.green)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.black.opacity(0.6), in: .rect(cornerRadius: 8))
                .padding(.horizontal, 8)
                .padding(.bottom, 100)
        }
        .allowsHitTesting(false)
    }
}

/// Heads-up display over the sky.
struct SkyHUD: View {
    let scene: SkyScene
    let frame: SkyFrame
    let snapshot: SkySnapshot

    var body: some View {
        VStack(spacing: 10) {
            // Top: twilight phase, index chip, time/location badges.
            VStack(spacing: 6) {
                Text(snapshot.sun.phase.hudText)
                    .font(.headline)
                    #if DEBUG
                    .onLongPressGesture {
                        let d = scene.diagnostics
                        d.showsPanel.toggle()
                        d.logsToConsole = d.showsPanel
                    }
                    #endif
                HStack(spacing: 8) {
                    chip("오늘 밤 지수 · ETL 연결 예정", systemImage: "sparkles")
                    if scene.observerIsDefault { chip("서울(기본 위치)", systemImage: "location.slash") }
                }
                if scene.isPlaying {
                    chip("재생 중 · " + snapshot.date.formatted(date: .omitted, time: .shortened), systemImage: "clock.arrow.circlepath")
                }
            }
            .padding(.top, 58)

            Spacer()

            // Center reticle.
            VStack(spacing: 4) {
                Image(systemName: "plus").font(.system(size: 18, weight: .light)).opacity(0.8)
                HeadingBadge(kind: scene.lastAttitudeKind, quality: scene.headingQuality)
                Text("\(Self.compass(frame.reticleAzimuth)) \(Int(frame.reticleAzimuth.rounded()))° · 고도 \(Int(frame.reticleAltitude.rounded()))°")
                    .font(.caption.monospacedDigit())
                if let c = frame.reticleConstellation { Text(c).font(.caption2).opacity(0.8) }
            }
            .padding(8)
            .background(.black.opacity(0.25), in: .rect(cornerRadius: 10))
            .allowsHitTesting(false)

            Spacer()

            // Bottom controls.
            HStack(spacing: 12) {
                Button { scene.playSunset() } label: { Label("해질녘 재생", systemImage: "sunset") }
                if scene.isPlaying { Button { scene.goLive() } label: { Label("지금", systemImage: "clock") } }
                Button { scene.toggleSensors() } label: {
                    Label(scene.useSensors ? "센서" : "수동", systemImage: scene.useSensors ? "gyroscope" : "hand.draw")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.white.opacity(0.18))
            .padding(.bottom, 40)
        }
        .foregroundStyle(.white)
    }

    private func chip(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.black.opacity(0.3), in: .capsule)
    }

    static func compass(_ az: Double) -> String {
        let names = ["북", "북북동", "북동", "동북동", "동", "동남동", "남동", "남남동",
                     "남", "남남서", "남서", "서남서", "서", "서북서", "북서", "북북서"]
        guard az.isFinite else { return "" }
        return names[Int((az / 22.5).rounded()) % 16]
    }
}
