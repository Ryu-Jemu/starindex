import Foundation
import Observation
import SkyCore

/// Tonight's index for the HUD chip and its sheet (PLAN W3 "앱 팩 클라이언트와 IndexChip").
///
/// - Base URL: Info.plist `StarIndexPackBaseURL` ← build setting `STARINDEX_PACK_BASE_URL` (project.yml).
///   Empty or malformed → `.unconfigured` ("지수 서버 미설정"), never a crash.
/// - Cold start / offline: the last verified pack is read from Caches synchronously in `init`.
/// - Refresh on activation and every 120 s while active (T19: a new pack must reach the phone within 5 min;
///   manifest max-age 60 s + 120 s poll ≤ 3 min). The loop is cancelled in the background.
@MainActor
@Observable
final class IndexStore {
    enum ChipState: Equatable {
        case unconfigured
        case loading
        case failed(String)
        /// `offline`: last refresh could not reach the server; `refreshError`: it reached it but failed.
        case ready(IndexSummary, offline: Bool, refreshError: String?)
    }

    static let pollInterval: Duration = .seconds(120)

    private(set) var loaded: LoadedIndexPack?
    private(set) var lastError: IndexPackClient.FetchError?
    private(set) var isRefreshing = false
    private(set) var lastCheck: Date?
    /// Why the store has no server ("미설정"), nil when configured.
    let unconfiguredReason: String?
    let baseURL: URL?

    @ObservationIgnored private let client: IndexPackClient?
    @ObservationIgnored private var poll: Task<Void, Never>?
    /// DEBUG `-indexNow`: evaluate "tonight"/staleness at another instant (screenshots, demo rehearsal).
    @ObservationIgnored private(set) var clockOffset: TimeInterval = 0
    @ObservationIgnored private var memo: (key: String, state: ChipState)?

    var now: Date { Date().addingTimeInterval(clockOffset) }

    init(bundle: Bundle = .main, cache: IndexPackCache = .standard) {
        let raw = (bundle.object(forInfoDictionaryKey: "StarIndexPackBaseURL") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch Self.parseBase(raw) {
        case .success(let url):
            baseURL = url
            unconfiguredReason = nil
            let cached = cache.load()
            loaded = cached?.loaded
            client = IndexPackClient(base: url, cache: cache, meta: cached?.meta)
        case .failure(let reason):
            baseURL = nil
            unconfiguredReason = reason.message
            client = nil
        }
    }

    enum BaseError: Error { case empty, malformed, insecure
        var message: String {
            switch self {
            case .empty: "StarIndexPackBaseURL이 비어 있어요"
            case .malformed: "StarIndexPackBaseURL 형식이 잘못됐어요"
            case .insecure: "Release 빌드는 https 주소만 써요"
            }
        }
    }

    static func parseBase(_ raw: String) -> Result<URL, BaseError> {
        // An unexpanded "$(STARINDEX_PACK_BASE_URL)" means the build setting is missing.
        guard !raw.isEmpty, !raw.hasPrefix("$(") else { return .failure(.empty) }
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), url.host() != nil,
              scheme == "https" || scheme == "http", url.query() == nil else { return .failure(.malformed) }
        #if !DEBUG
        // Release ATS stays strict even though Info.plist carries NSAllowsLocalNetworking (see project.yml).
        guard scheme == "https" else { return .failure(.insecure) }
        #endif
        return .success(url)
    }

    // MARK: Lifecycle

    /// DEBUG launch arguments (see `SkyScene.applyLaunchArguments` for the full list):
    /// `-indexNow <ISO-8601>` evaluates the chip at that instant. Returns true for `-openIndexSheet`.
    func applyLaunchArguments(_ args: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        #if DEBUG
        if let i = args.firstIndex(of: "-indexNow"), i + 1 < args.count, let d = PackTime.parse(args[i + 1]) {
            clockOffset = d.timeIntervalSinceNow
        }
        return args.contains("-openIndexSheet")
        #else
        return false
        #endif
    }

    /// App became active: refresh now (unless the manifest is still fresh), then every 120 s.
    func activate() {
        guard client != nil, poll == nil else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                do {    // scope: no strong reference to the store survives into the sleep
                    guard let store = self else { return }
                    await store.refresh()
                }
                try? await Task.sleep(for: IndexStore.pollInterval)
            }
        }
    }

    /// Background: no polling (no network use while the app is not on screen).
    func deactivate() {
        poll?.cancel()
        poll = nil
    }

    /// - Parameter force: ignore the manifest's max-age (user tapped "다시 시도").
    func refresh(force: Bool = false) async {
        guard let client, !isRefreshing else { return }
        isRefreshing = true                     // before any await: a second caller returns above
        defer { isRefreshing = false }
        // Respect the manifest's Cache-Control max-age: a re-activation within it does not hit the network.
        let maxAge = await client.manifestMaxAge
        if !force, lastError == nil, let last = lastCheck, Date().timeIntervalSince(last) < maxAge { return }
        let result = await client.refresh()
        switch result {
        case .success(.unchanged(let generatedAt)):
            if var l = loaded, l.generatedAt != generatedAt {
                l.generatedAt = generatedAt
                loaded = l
            }
            lastError = nil
            lastCheck = Date()
        case .success(.newPack(let pack)):
            loaded = pack
            lastError = nil
            lastCheck = Date()
        case .failure(let e):
            lastError = e
        }
    }

    // MARK: Chip

    /// Chip state for the observer. Called from the per-frame HUD, so it is memoized per minute and input.
    func chipState(observer: ObserverLocation, isDefault: Bool) -> ChipState {
        let now = self.now
        let cell = KMAGrid.toGrid(latitude: observer.latitude, longitude: observer.longitude)
        let key = "\(loaded?.entry.version ?? "-")|\(loaded?.generatedAt?.timeIntervalSince1970 ?? 0)|"
            + "\(cell.map { "\($0.nx),\($0.ny)" } ?? "out")|\(isDefault)|\(Int(now.timeIntervalSince1970 / 60))|"
            + "\(isRefreshing)|\(lastCheck != nil)|\(String(describing: lastError))"
        if let memo, memo.key == key { return memo.state }
        let state = computeChipState(observer: observer, isDefault: isDefault, now: now)
        memo = (key, state)
        return state
    }

    func summary(observer: ObserverLocation, isDefault: Bool) -> IndexSummary? {
        guard let l = loaded else { return nil }
        return IndexSummary.make(pack: l.pack, observer: isDefault ? nil : (observer.latitude, observer.longitude),
                                 generatedAt: l.generatedAt, now: now)
    }

    private func computeChipState(observer: ObserverLocation, isDefault: Bool, now: Date) -> ChipState {
        guard client != nil else { return .unconfigured }
        guard let summary = summary(observer: observer, isDefault: isDefault) else {
            if let e = lastError, !isRefreshing { return .failed(Self.message(e)) }
            return .loading
        }
        let offline = lastError == .offline
        let refreshError = lastError.flatMap { $0 == .offline ? nil : Self.message($0) }
        return .ready(summary, offline: offline, refreshError: refreshError)
    }

    static func message(_ e: IndexPackClient.FetchError) -> String {
        switch e {
        case .offline: "오프라인 · 예보를 받지 못했어요"
        case .network(let code): "네트워크 오류(\(code))"
        case .http(let code): "지수 서버 오류(HTTP \(code))"
        case .badManifest, .unsafePath: "지수 목록을 읽지 못했어요"
        case .integrity: "받은 지수 파일이 손상됐어요"
        }
    }
}
