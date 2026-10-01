import Foundation

/// Grade as written by backend `StarIndexCalculator.Grade`.
public enum IndexGrade: String, Sendable, CaseIterable {
    case poor = "POOR", fair = "FAIR", good = "GOOD", excellent = "EXCELLENT"

    /// Same thresholds as `StarIndexCalculator.grade(score)`; used when the pack's grade string is unknown.
    public static func from(score: Int) -> IndexGrade {
        score >= 80 ? .excellent : (score >= 60 ? .good : (score >= 40 ? .fair : .poor))
    }

    /// Chip wording. SERVICE-PLAN 4.5 avoids discouraging wording, so POOR reads "어려움" (not "나쁨").
    public var text: String {
        switch self {
        case .excellent: "매우 좋음"
        case .good: "좋음"
        case .fair: "보통"
        case .poor: "어려움"
        }
    }
}

/// Reason codes → short Korean phrases. Every code `StarIndexCalculator.reasons` and `PackPublisher` can emit
/// is mapped; an unknown (newer) code is hidden rather than shown raw.
public enum IndexReason {
    public static let phrases: [String: String] = [
        "PRECIP": "비 또는 눈",
        "CLOUD_CLEAR": "맑음",
        "CLOUD_MOSTLY": "구름많음",
        "CLOUD_OVERCAST": "흐림",
        "MOON_NONE": "달빛 영향 없음",
        "MOON_SOME": "달빛 조금",
        "MOON_BRIGHT": "밝은 달빛",
        "NO_FORECAST": "예보 없음",
    ]

    public static func phrase(_ code: String) -> String? { phrases[code] }
}

/// What the index chip and sheet show for one region of a pack (pure; T20a-style tests in SkyCore).
public struct IndexSummary: Sendable, Equatable {
    /// How the region was chosen (always on the device).
    public enum Basis: Sendable, Equatable {
        /// Nearest pack region to the observer.
        case nearest
        /// Observer unknown (location denied / not yet fixed): Seoul, explained by the HUD's "서울(기본 위치)" chip.
        case defaultLocation
        /// Observer outside the KMA grid or beyond `RegionLocator.maxGridDistance`: Seoul, with a note.
        case outsideKorea
    }

    public struct TwilightRow: Sendable, Equatable {
        public enum Source: Sendable, Equatable { case kasi, computed }
        public var label: String
        /// "18:25".
        public var time: String
        public var source: Source
        /// SERVICE-PLAN 4.5 source tags. "(계산)", not "(앱 계산)": these times are computed by the backend.
        public var sourceLabel: String { source == .kasi ? "(천문연)" : "(계산)" }
    }

    public var regionID: String
    public var regionName: String
    public var basis: Basis
    public var night: NightDate?
    public var score: Int?
    public var grade: IndexGrade?
    /// Grade wording for the chip; "관측 불가" when precipitation falls in the best window.
    public var gradeText: String?
    /// SERVICE-PLAN 4.5 verdict line.
    public var verdict: String
    /// "20:00–22:00".
    public var bestWindow: String?
    /// "17시 발표".
    public var issueLabel: String?
    /// "10/12 17시 발표".
    public var issueDateLabel: String?
    /// The pack is for the current night (`NightDate.of(now)`); otherwise it is a stored/older (or demo) night.
    public var isTonight: Bool
    /// Manifest written more than `staleAfter` ago (publishing stalled).
    public var isStale: Bool
    /// "8시간 전 발표 기준" when stale.
    public var staleLabel: String?
    public var reasons: [String]
    public var twilight: [TwilightRow]
    public var attribution: [String]
    /// One line for the HUD chip, e.g. "오늘 밤 72 · 좋음 · 17시 발표" or "저장된 예보 · 10/12 17시 발표 · 50 보통".
    public var chipText: String
    /// Extra chip line ("서울 기준 · 한국 밖") or nil.
    public var chipNote: String?

    /// SERVICE-PLAN 4.6: a pack older than 6 h gets a "N시간 전 발표 기준" badge.
    public static let staleAfter: TimeInterval = 6 * 3600

    /// - Parameters:
    ///   - observer: lat/lon of the observer, or nil when the app only has its default location.
    ///   - generatedAt: the manifest's `generatedAt` (nil when unknown, e.g. an old cache without it).
    public static func make(pack: IndexPack, observer: (latitude: Double, longitude: Double)?,
                            generatedAt: Date?, now: Date) -> IndexSummary? {
        var basis = Basis.nearest
        var region: IndexRegion?
        if let o = observer {
            region = RegionLocator.nearest(pack.regions, latitude: o.latitude, longitude: o.longitude)
            if region == nil { basis = .outsideKorea }
        } else {
            basis = .defaultLocation
        }
        guard let region = region ?? RegionLocator.seoul(pack.regions) ?? pack.regions.first else { return nil }
        return make(pack: pack, region: region, basis: basis, generatedAt: generatedAt, now: now)
    }

    public static func make(pack: IndexPack, region: IndexRegion, basis: Basis, generatedAt: Date?, now: Date) -> IndexSummary {
        let night = pack.night
        let issued = pack.issuedDate
        let isTonight = night == NightDate.of(now)
        let precip = region.reasons.contains("PRECIP")

        let grade = region.grade.flatMap(IndexGrade.init(rawValue:)) ?? region.score.map(IndexGrade.from(score:))
        let gradeText: String? = region.score == nil ? nil : (precip ? "관측 불가" : grade?.text)

        var bestWindow: String?
        if let b = region.best, b.count == 2, let from = KST.displayHHmm(b[0]), let to = KST.displayHHmm(b[1]) {
            bestWindow = "\(from)–\(to)"
        }

        let issueLabel = issued.map { KST.hourLabel($0) + " 발표" }
        let issueDateLabel = issued.map { KST.monthDay($0) + " " + KST.hourLabel($0) + " 발표" }

        let isStale = generatedAt.map { now.timeIntervalSince($0) > staleAfter } ?? false
        var staleLabel: String?
        if isStale, let ref = issued ?? generatedAt {
            let hours = max(0, Int(now.timeIntervalSince(ref) / 3600))
            staleLabel = issued != nil ? "\(hours)시간 전 발표 기준" : "\(hours)시간 전 갱신"
        }

        let scorePart = region.score.map { s in [String(s), gradeText].compactMap { $0 }.joined(separator: " · ") }
        let chipText: String
        if isTonight {
            chipText = (["오늘 밤 " + (scorePart ?? "예보 없음")] + [issueLabel].compactMap { $0 }).joined(separator: " · ")
        } else {
            let stored = "저장된 예보" + (issueDateLabel.map { " · " + $0 } ?? (night.map { " · \($0.label) 밤" } ?? ""))
            chipText = stored + " · " + (region.score.map { s in [String(s), gradeText].compactMap { $0 }.joined(separator: " ") } ?? "예보 없음")
        }
        let chipNote: String? = basis == .outsideKorea ? "한국 밖 · \(region.name) 기준" : nil

        return IndexSummary(
            regionID: region.id, regionName: region.name, basis: basis, night: night,
            score: region.score, grade: grade, gradeText: gradeText,
            verdict: verdict(region: region, pack: pack),
            bestWindow: bestWindow, issueLabel: issueLabel, issueDateLabel: issueDateLabel,
            isTonight: isTonight, isStale: isStale, staleLabel: staleLabel,
            reasons: region.reasons.compactMap(IndexReason.phrase),
            twilight: twilightRows(region.twilight),
            attribution: pack.attribution, chipText: chipText, chipNote: chipNote)
    }

    /// SERVICE-PLAN 4.5, in priority order.
    static func verdict(region: IndexRegion, pack: IndexPack) -> String {
        guard let score = region.score else { return "예보가 없어요" }
        let window = bestWindowSlots(region: region, pack: pack)
        let pty = window.compactMap { region.hourly?.pty?[safe: $0] ?? nil }
        if region.reasons.contains("PRECIP") || pty.contains(where: { $0 > 0 }) { return "관측 불가 · 비(또는 눈)" }
        let sky = window.compactMap { region.hourly?.sky?[safe: $0] ?? nil }
        if score < 40 || (!sky.isEmpty && sky.count == window.count && sky.allSatisfy { $0 == 4 }) { return "오늘 밤은 어려워요" }
        if score < 60 { return "밝은 별 위주로 보여요" }
        if score < 80 { return "나가 볼 만해요" }
        return "아주 좋은 밤이에요"
    }

    /// Indices into the hourly arrays covered by the best window [from, to). Times before 12:00 belong to the
    /// morning after the night date (the series starts at 12:00 KST of the night date).
    static func bestWindowSlots(region: IndexRegion, pack: IndexPack) -> [Int] {
        guard let night = pack.night, let b = region.best, b.count == 2,
              let t0 = region.hourly?.t0.flatMap(PackTime.parse),
              let from = clock(b[0], night), var to = clock(b[1], night) else { return [] }
        if to <= from { to += 24 * 3600 }
        let step = Double(max(1, pack.hourlyStep ?? 1)) * 3600
        var out: [Int] = []
        var t = from
        while t < to {
            let i = Int(((t.timeIntervalSince(t0)) / step).rounded(.down))
            if i >= 0 { out.append(i) }
            t += step
        }
        return out
    }

    private static func clock(_ hhmm: String, _ night: NightDate) -> Date? {
        guard KST.displayHHmm(hhmm) != nil, let v = Int(hhmm) else { return nil }
        let h = v / 100, m = v % 100
        let dayOffset = h < 12 ? 1 : 0
        return night.startKST.addingTimeInterval(Double(dayOffset * 86_400 + h * 3600 + m * 60))
    }

    /// Prefer KASI (천문연) per field, else the computed time; skip events that do not happen.
    static func twilightRows(_ t: IndexRegion.Twilight?) -> [TwilightRow] {
        guard let t else { return [] }
        let fields: [(String, KeyPath<IndexRegion.Twilight.Times, String?>)] = [
            ("일몰", \.sunset), ("시민박명 끝", \.civile), ("항해박명 끝", \.naute), ("천문박명 끝", \.aste),
            ("새벽 천문박명 시작", \.astm), ("일출", \.sunrise),
        ]
        return fields.compactMap { label, kp in
            if let k = KST.displayHHmm(t.kasi?[keyPath: kp]) { return TwilightRow(label: label, time: k, source: .kasi) }
            if let c = KST.displayHHmm(t.computed?[keyPath: kp]) { return TwilightRow(label: label, time: c, source: .computed) }
            return nil
        }
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
