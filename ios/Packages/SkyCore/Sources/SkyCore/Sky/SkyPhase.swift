/// Twilight phase classification by the Sun's *geometric* altitude (no refraction), matching the
/// USNO / KASI definitions (−6°, −12°, −18° of the Sun's center; sunrise/sunset at −0.833°).
public enum OfficialPhase: String, Sendable {
    case day, civil, nautical, astronomical, night

    public var nameKo: String {
        switch self {
        case .day: return "낮"
        case .civil: return "시민박명"
        case .nautical: return "항해박명"
        case .astronomical: return "천문박명"
        case .night: return "밤"
        }
    }
}

/// Photographic conventions (not official definitions; sources disagree on the bounds).
public enum ConventionTag: String, Sendable {
    case goldenHour, blueHour
    public var nameKo: String { self == .goldenHour ? "골든아워" : "블루아워" }
}

public enum PhaseEvent: String, Sendable {
    case sunset, sunrise
    public var nameKo: String { self == .sunset ? "일몰" : "일출" }
}

public struct SkyPhaseInfo: Sendable, Equatable {
    public var official: OfficialPhase
    public var tag: ConventionTag?
    public var event: PhaseEvent?
    /// true when the Sun is descending (dh/dt < 0).
    public var isEvening: Bool

    /// One-line HUD text, e.g. "저녁 시민박명 · 블루아워", "일몰", "낮 · 골든아워", "밤".
    public var hudText: String {
        if let event { return event.nameKo }
        var text: String
        switch official {
        case .day: text = "낮"
        case .night: text = "밤"
        default: text = (isEvening ? "저녁 " : "새벽 ") + official.nameKo
        }
        if let tag { text += " · " + tag.nameKo }
        return text
    }
}

public enum SkyPhase {
    public static let sunsetAltitude = -0.833
    public static let eventHalfWidth = 0.25

    /// - Parameters:
    ///   - hGeoDeg: Sun's geometric altitude in degrees.
    ///   - dhdt: sign of the altitude rate (negative in the evening).
    public static func classify(hGeoDeg h: Double, dhdt: Double) -> SkyPhaseInfo {
        // Official phases: non-overlapping half-open intervals.
        let official: OfficialPhase
        if h > sunsetAltitude { official = .day }
        else if h > -6 { official = .civil }
        else if h > -12 { official = .nautical }
        else if h > -18 { official = .astronomical }
        else { official = .night }

        // Convention tags.
        let tag: ConventionTag?
        if h > sunsetAltitude && h <= 6 { tag = .goldenHour }
        else if h > -6 && h <= -4 { tag = .blueHour }
        else { tag = nil }

        let evening = dhdt < 0
        let event: PhaseEvent? = abs(h - sunsetAltitude) < eventHalfWidth ? (evening ? .sunset : .sunrise) : nil
        return SkyPhaseInfo(official: official, tag: tag, event: event, isEvening: evening)
    }
}
