import Foundation

/// Plans the ~20 s "해질녘 재생" (sunset playback): sunset −45 min → end of twilight.
public struct SunsetPlaybackPlan: Sendable, Equatable {
    public enum EndReason: String, Sendable { case astronomicalDusk, lowerCulmination, sunsetPlus3h }

    public struct Segment: Sendable, Equatable {
        public var from: Date
        public var to: Date
        /// Simulated seconds per real second.
        public var speed: Double
        public var realSeconds: Double { to.timeIntervalSince(from) / speed }
    }

    public var sunset: Date
    public var start: Date
    public var end: Date
    public var endReason: EndReason
    public var segments: [Segment]
    /// Show "오늘은 천문박명이 끝나지 않음" only when the Sun's minimum altitude stays above −18°.
    public var showsNoAstronomicalDuskNotice: Bool

    public var totalRealSeconds: Double { segments.reduce(0) { $0 + $1.realSeconds } }
}

public enum SunsetPlaybackPlanner {
    public static let leadMinutes = 45.0
    public static let segment1MaxSeconds = 15.0
    public static let segment1BaseSpeed = 300.0
    public static let segment2Seconds = 6.0
    public static let singleSegmentSeconds = 20.0
    public static let capHours = 3.0

    /// Returns nil when there is no sunset (polar day/night) within the next day.
    public static func plan(after date: Date, observer: ObserverLocation,
                            engine: AstroEngine = .shared) -> SunsetPlaybackPlan? {
        guard let sunset = RiseSetService.sunset(after: date, observer: observer, engine: engine),
              let lowerCulm = RiseSetService.lowerCulmination(after: sunset, observer: observer, engine: engine)
        else { return nil }

        let start = sunset.addingTimeInterval(-leadMinutes * 60)
        let cap = sunset.addingTimeInterval(capHours * 3600)

        // −18° only counts if reached before the Sun's lowest point (otherwise it is next night's).
        let astroDusk = RiseSetService.duskCrossing(altitudeDeg: -18, after: sunset, observer: observer, engine: engine)
            .flatMap { $0 <= lowerCulm ? $0 : nil }

        var end = cap
        var reason = SunsetPlaybackPlan.EndReason.sunsetPlus3h
        if lowerCulm < end { end = lowerCulm; reason = .lowerCulmination }
        if let astroDusk, astroDusk < end { end = astroDusk; reason = .astronomicalDusk }

        let minAltitude = engine.geometricAltitude(.sun, date: lowerCulm, observer: observer) ?? -90
        let showsNotice = minAltitude > -18

        let t6 = RiseSetService.duskCrossing(altitudeDeg: -6, after: sunset, observer: observer, engine: engine)
            .flatMap { $0 < end && $0 <= lowerCulm ? $0 : nil }

        var segments: [SunsetPlaybackPlan.Segment] = []
        if let t6 {
            let span1 = t6.timeIntervalSince(start)
            let speed1 = max(segment1BaseSpeed, span1 / segment1MaxSeconds)
            segments.append(.init(from: start, to: t6, speed: speed1))
            let span2 = end.timeIntervalSince(t6)
            segments.append(.init(from: t6, to: end, speed: max(span2 / segment2Seconds, 1)))
        } else {
            let span = end.timeIntervalSince(start)
            segments.append(.init(from: start, to: end, speed: max(span / singleSegmentSeconds, 1)))
        }

        return SunsetPlaybackPlan(sunset: sunset, start: start, end: end, endReason: reason,
                                  segments: segments, showsNoAstronomicalDuskNotice: showsNotice)
    }
}
