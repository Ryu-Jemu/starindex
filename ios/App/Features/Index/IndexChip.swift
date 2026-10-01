import SwiftUI
import SkyCore

/// HUD chip: "오늘 밤 72 · 좋음 · 17시 발표" for the pack region nearest the observer (chosen on the device).
/// A Button, so a tap opens the index sheet and never reaches the sky's tap handler underneath.
struct IndexChip: View {
    let store: IndexStore
    let observer: ObserverLocation
    let observerIsDefault: Bool
    let action: () -> Void

    var body: some View {
        let state = store.chipState(observer: observer, isDefault: observerIsDefault)
        Button(action: action) {
            content(state)
                .font(.caption)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.black.opacity(0.3), in: .rect(cornerRadius: 13))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint("오늘 밤 별 지수 자세히 보기")
    }

    @ViewBuilder
    private func content(_ state: IndexStore.ChipState) -> some View {
        switch state {
        case .unconfigured:
            Label("오늘 밤 지수 · 지수 서버 미설정", systemImage: "sparkles")
                .opacity(0.75)
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini).tint(.white)
                Text("오늘 밤 지수 받는 중…")
            }
        case .failed:
            Label("오늘 밤 지수를 받지 못했어요", systemImage: "exclamationmark.triangle")
        case .ready(let s, let offline, let refreshError):
            VStack(spacing: 2) {
                Label(s.chipText, systemImage: s.isTonight ? "sparkles" : "archivebox")
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                let warnings = Self.warnings(s, offline: offline, refreshError: refreshError)
                if s.chipNote != nil || !warnings.isEmpty {
                    HStack(spacing: 6) {
                        if let note = s.chipNote { Text(note).opacity(0.8) }
                        if !warnings.isEmpty {
                            // Subtle: a small yellow line, the score stays readable (SERVICE-PLAN 4.6 "배지").
                            Label(warnings.joined(separator: " · "), systemImage: offline ? "wifi.slash" : "clock.badge.exclamationmark")
                                .foregroundStyle(.yellow.opacity(0.9))
                        }
                    }
                    .font(.caption2)
                    .lineLimit(1)
                }
            }
        }
    }

    static func warnings(_ s: IndexSummary, offline: Bool, refreshError: String?) -> [String] {
        var out: [String] = []
        // A stored night already says which issue it is; the age badge is for tonight's pack.
        if s.isTonight, s.isStale, let label = s.staleLabel { out.append(label) }
        if offline { out.append("오프라인") } else if refreshError != nil { out.append("갱신 실패") }
        return out
    }
}
