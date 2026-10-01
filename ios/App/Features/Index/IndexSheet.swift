import SwiftUI
import SkyCore

/// Index details for the chip's region: score, verdict, best window, reasons, twilight times, issue time and
/// the attribution the data licenses require (KMA 공공누리 1유형: source must be shown).
struct IndexSheet: View {
    let store: IndexStore
    let observer: ObserverLocation
    let observerIsDefault: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let state = store.chipState(observer: observer, isDefault: observerIsDefault)
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(title(state)).font(.title3.bold())
                Spacer()
                Button("닫기", systemImage: "xmark") { dismiss() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
            }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    content(state)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.bottom, 24)
            }
        }
    }

    private func title(_ state: IndexStore.ChipState) -> String {
        if case .ready(let s, _, _) = state {
            return s.regionName + (s.night.map { " · \($0.label) 밤" } ?? "")
        }
        return "오늘 밤 별 지수"
    }

    @ViewBuilder
    private func content(_ state: IndexStore.ChipState) -> some View {
        switch state {
        case .unconfigured:
            notice("지수 서버가 설정되지 않았어요", systemImage: "gearshape",
                   detail: (store.unconfiguredReason ?? "") + "\n빌드 설정 STARINDEX_PACK_BASE_URL(project.yml)을 채워 주세요.")
        case .loading:
            HStack(spacing: 10) { ProgressView(); Text("예보 받는 중…") }
                .foregroundStyle(.secondary)
        case .failed(let message):
            notice("오늘 밤 지수를 받지 못했어요", systemImage: "exclamationmark.triangle", detail: message)
            retryButton
        case .ready(let s, let offline, let refreshError):
            ready(s, offline: offline, refreshError: refreshError)
        }
    }

    @ViewBuilder
    private func ready(_ s: IndexSummary, offline: Bool, refreshError: String?) -> some View {
        Text(basisText(s)).font(.subheadline).foregroundStyle(.secondary)

        if !s.isTonight {
            banner("저장된 예보 · \(s.issueDateLabel ?? "발표 시각 없음")", systemImage: "archivebox",
                   detail: "오늘 밤(\(NightDate.of(store.now).label)) 예보가 아니에요.")
        } else if s.isStale, let label = s.staleLabel {
            banner(label, systemImage: "clock.badge.exclamationmark", detail: "새 예보 발행이 늦어지고 있어요.")
        }
        if offline {
            banner("오프라인", systemImage: "wifi.slash", detail: "마지막으로 받은 지수를 보여 줘요.")
        } else if let refreshError {
            banner("갱신 실패", systemImage: "exclamationmark.triangle", detail: refreshError)
        }

        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(s.score.map(String.init) ?? "–")
                .font(.system(size: 52, weight: .bold, design: .rounded))
                .monospacedDigit()
            VStack(alignment: .leading, spacing: 2) {
                if let g = s.gradeText { Text(g).font(.title3.weight(.semibold)) }
                Text(s.verdict).foregroundStyle(.secondary)
            }
        }

        section("오늘 밤") {
            row("최적 시간", s.bestWindow ?? "–")
            if !s.reasons.isEmpty { row("이유", s.reasons.joined(separator: " · ")) }
            row("예보", "기상청 단기예보 " + (s.issueDateLabel ?? "발표 시각 없음"))
        }

        if !s.twilight.isEmpty {
            section("일몰·박명·일출") {
                ForEach(s.twilight, id: \.label) { t in
                    row(t.label, "\(t.time) \(t.sourceLabel)")
                }
            }
        }

        if let l = store.loaded {
            section("팩") {
                row("버전", l.entry.version)
                if let g = l.generatedAt { row("발행", KST.monthDay(g) + " " + KST.hhmm(g)) }
            }
        }
        if offline || refreshError != nil { retryButton }

        VStack(alignment: .leading, spacing: 4) {
            Text("지수는 참고용 추정이에요. 위치를 저희 서버로 보내지 않아요. 지역은 기기 안에서 골라요.")
            Text("출처").fontWeight(.semibold).padding(.top, 4)
            ForEach(s.attribution, id: \.self) { Text("· " + $0) }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func basisText(_ s: IndexSummary) -> String {
        switch s.basis {
        case .nearest: "내 위치에서 가장 가까운 예보 지점: \(s.regionName)"
        case .defaultLocation: "위치를 몰라 \(s.regionName) 기준으로 보여 줘요"
        case .outsideKorea: "한국 밖이에요 · 예보 지수는 한국 지역만 제공해요(\(s.regionName) 기준 표시)"
        }
    }

    private var retryButton: some View {
        Button {
            Task { await store.refresh(force: true) }
        } label: {
            Label(store.isRefreshing ? "확인 중…" : "다시 시도", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.bordered)
        .disabled(store.isRefreshing)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ rows: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            rows()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).monospacedDigit().multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }

    private func banner(_ title: String, systemImage: String, detail: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage).foregroundStyle(.yellow)
        }
        .font(.subheadline)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.yellow.opacity(0.12), in: .rect(cornerRadius: 10))
    }

    private func notice(_ title: String, systemImage: String, detail: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage)
        }
    }
}
