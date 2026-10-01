import SwiftUI
import simd
import SkyCore

/// Detail sheet for a tapped object (M0): names, magnitude, current altitude/azimuth, constellation, and for the
/// Sun, Moon, planets and stars the '뜸·남중·짐' times of the next 24 h (KST).
struct ObjectDetailSheet: View {
    let scene: SkyScene
    let ref: SkyObjectRef
    @State private var riseSet: [Row]?

    private struct Row: Sendable, Hashable { var label: String; var value: String }

    /// Recompute when the object or the observer changes (not on every re-render).
    private struct RiseSetKey: Equatable { var ref: SkyObjectRef; var observer: ObserverLocation }

    var body: some View {
        let snap = scene.snapshotForDetails()
        let info = details(snap)
        VStack(alignment: .leading, spacing: 10) {
            Text(info.title).font(.title2.bold())
            if let sub = info.subtitle { Text(sub).foregroundStyle(.secondary) }
            Divider()
            ForEach(info.rows, id: \.0) { row in
                HStack { Text(row.0).foregroundStyle(.secondary); Spacer(); Text(row.1).monospacedDigit() }
            }
            if info.target != nil {
                Divider()
                if let riseSet {
                    ForEach(riseSet, id: \.self) { row in
                        HStack { Text(row.label).foregroundStyle(.secondary); Spacer(); Text(row.value).monospacedDigit() }
                    }
                } else {
                    HStack { Text("뜸·남중·짐").foregroundStyle(.secondary); Spacer(); ProgressView().controlSize(.small) }
                }
            }
            Spacer()
            Text("천체 위치: Astronomy Engine · 별: Yale BSC5P(NASA HEASARC) · 별자리: IAU/d3-celestial")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(20)
        .task(id: RiseSetKey(ref: ref, observer: scene.observer)) {
            riseSet = nil
            guard let target = info.target else { return }
            // From the drawn sky's instant (simulated during playback), so the rows agree with the altitude above.
            let observer = snap.observer, from = snap.date
            // Three AE searches (a few ms) off the main thread; AstroEngine serializes C calls with its lock.
            let result = await Task.detached(priority: .userInitiated) {
                RiseTransitSet.next24h(target, observer: observer, from: from)
            }.value
            guard !Task.isCancelled else { return }
            riseSet = result?.rows(now: from).map { Row(label: $0.label, value: $0.value) }
                ?? [Row(label: "뜸·남중·짐", value: "계산할 수 없어요")]
        }
    }

    private struct Info {
        var title: String
        var subtitle: String?
        var rows: [(String, String)]
        /// What rise/transit/set is computed for (nil for constellations).
        var target: SkyTarget?
    }

    private func details(_ snap: SkySnapshot) -> Info {
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
            guard let d = snap.bodies.first(where: { $0.body == b }) else { return Info(title: b.nameKo, rows: [], target: .body(b)) }
            var rows = altAzRows(d.horizontal)
            rows.append(("등급", String(format: "%.1f", d.magnitude)))
            if b == .moon { rows.append(("밝은 면", String(format: "%.0f%%", d.phaseFraction * 100))) }
            let eqj = snap.rotation.transpose * Refraction.unrefract(d.horizontal)
            rows.append(("별자리", constellationName(eqj)))
            return Info(title: b.nameKo, subtitle: b == .sun ? "태양을 직접 보지 마세요" : nil, rows: rows, target: .body(b))
        case .star(let i):
            let s = scene.catalog.stars[i]
            var rows = altAzRows(SIMD3<Double>(snap.starsHOR[i]))
            rows.append(("등급", String(format: "%.2f", s.magnitude)))
            rows.append(("별자리", constellationName(SIMD3<Double>(s.j2000))))
            return Info(title: s.name ?? "HR \(s.hr)", subtitle: s.name != nil ? "HR \(s.hr)" : nil, rows: rows,
                        target: SkyTarget(starJ2000: SIMD3<Double>(s.j2000)))
        case .constellation(let i):
            let c = scene.catalog.constellations[i]
            return Info(title: c.nameKo ?? c.abbr, subtitle: [c.nameLatin, c.abbr].compactMap { $0 }.joined(separator: " · "),
                        rows: altAzRows(SIMD3<Double>(snap.anchorsHOR[i])), target: nil)
        }
    }
}
