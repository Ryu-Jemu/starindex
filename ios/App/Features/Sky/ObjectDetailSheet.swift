import SwiftUI
import simd
import SkyCore

/// Minimal detail sheet for a tapped object (M0): names, magnitude, current altitude/azimuth, constellation.
struct ObjectDetailSheet: View {
    let scene: SkyScene
    let ref: SkyObjectRef

    var body: some View {
        let info = details()
        VStack(alignment: .leading, spacing: 10) {
            Text(info.title).font(.title2.bold())
            if let sub = info.subtitle { Text(sub).foregroundStyle(.secondary) }
            Divider()
            ForEach(info.rows, id: \.0) { row in
                HStack { Text(row.0).foregroundStyle(.secondary); Spacer(); Text(row.1).monospacedDigit() }
            }
            Spacer()
            Text("천체 위치: Astronomy Engine · 별: Yale BSC5P(NASA HEASARC) · 별자리: IAU/d3-celestial")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(20)
    }

    private struct Info { var title: String; var subtitle: String?; var rows: [(String, String)] }

    private func details() -> Info {
        let snap = scene.frame(size: CGSize(width: 1, height: 1), uptime: ProcessInfo.processInfo.systemUptime, now: Date()).1
        func altAzRows(_ h: SIMD3<Double>) -> [(String, String)] {
            let (alt, az) = Horizontal.altAz(h)
            return [("고도", String(format: "%.1f°", alt)), ("방위", String(format: "%.1f° %@", az, SkyHUD.compass(az)))]
        }
        func constellationName(_ eqj: SIMD3<Double>) -> String {
            guard let a = ConstellationLocator.locate(j2000: eqj) else { return "-" }
            return scene.catalog.constellations.first { $0.abbr == a }?.nameKo ?? a
        }
        switch ref {
        case .body(let b):
            guard let d = snap.bodies.first(where: { $0.body == b }) else { return Info(title: b.nameKo, rows: []) }
            var rows = altAzRows(d.horizontal)
            rows.append(("등급", String(format: "%.1f", d.magnitude)))
            if b == .moon { rows.append(("밝은 면", String(format: "%.0f%%", d.phaseFraction * 100))) }
            let eqj = snap.rotation.transpose * Refraction.unrefract(d.horizontal)
            rows.append(("별자리", constellationName(eqj)))
            return Info(title: b.nameKo, subtitle: b == .sun ? "태양을 직접 보지 마세요" : nil, rows: rows)
        case .star(let i):
            let s = scene.catalog.stars[i]
            var rows = altAzRows(SIMD3<Double>(snap.starsHOR[i]))
            rows.append(("등급", String(format: "%.2f", s.magnitude)))
            rows.append(("별자리", constellationName(SIMD3<Double>(s.j2000))))
            return Info(title: s.name ?? "HR \(s.hr)", subtitle: s.name != nil ? "HR \(s.hr)" : nil, rows: rows)
        case .constellation(let i):
            let c = scene.catalog.constellations[i]
            return Info(title: c.nameKo ?? c.abbr, subtitle: [c.nameLatin, c.abbr].compactMap { $0 }.joined(separator: " · "),
                        rows: altAzRows(SIMD3<Double>(snap.anchorsHOR[i])))
        }
    }
}
