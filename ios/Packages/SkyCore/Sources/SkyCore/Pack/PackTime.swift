import Foundation

/// Korea Standard Time helpers. A fixed +09:00 offset (no DST since 1988) rather than "Asia/Seoul",
/// so results never depend on the device's tz database.
public enum KST {
    public static let timeZone = TimeZone(secondsFromGMT: 9 * 3600)!

    public static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        c.locale = Locale(identifier: "ko_KR")
        return c
    }()

    static let weekdays = ["일", "월", "화", "수", "목", "금", "토"]

    public static func components(_ date: Date) -> DateComponents {
        calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: date)
    }

    /// "05:57". Formatted from calendar components: no DateFormatter, cheap enough for a per-frame HUD.
    public static func hhmm(_ date: Date) -> String {
        let c = components(date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// "17시" on the hour, otherwise "17:30".
    public static func hourLabel(_ date: Date) -> String {
        let c = components(date)
        let h = c.hour ?? 0, m = c.minute ?? 0
        return m == 0 ? "\(h)시" : String(format: "%d:%02d", h, m)
    }

    /// "10/12".
    public static func monthDay(_ date: Date) -> String {
        let c = components(date)
        return "\(c.month ?? 0)/\(c.day ?? 0)"
    }

    /// `hhmm(date)`, prefixed with "내일" when it falls on the KST day after `now` (rise/set rows look 24 h ahead).
    public static func timeRelative(_ date: Date, now: Date) -> String {
        let day = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        switch day {
        case 0: return hhmm(date)
        case 1: return "내일 " + hhmm(date)
        case -1: return "어제 " + hhmm(date)
        default: return monthDay(date) + " " + hhmm(date)
        }
    }

    /// "HHmm" (pack format) → "HH:mm"; nil when malformed.
    public static func displayHHmm(_ s: String?) -> String? {
        guard let s, s.count == 4, s.allSatisfy(\.isASCII), let v = Int(s) else { return nil }
        let h = v / 100, m = v % 100
        guard (0...23).contains(h), (0...59).contains(m) else { return nil }
        return String(format: "%02d:%02d", h, m)
    }
}

/// The night a moment belongs to: the KST date of the preceding 12:00 (backend `IndexService.nightDateOf`,
/// SERVICE-PLAN 4.2). After midnight it is still "tonight", not "last night".
public struct NightDate: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// Parses "yyyy-MM-dd".
    public init?(_ s: String) {
        let p = s.split(separator: "-", omittingEmptySubsequences: false)
        guard p.count == 3, p[0].count == 4, p[1].count == 2, p[2].count == 2,
              let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    /// Same rule as the backend: `now (KST) − 12 h → local date`.
    public static func of(_ date: Date) -> NightDate {
        let c = KST.calendar.dateComponents([.year, .month, .day], from: date.addingTimeInterval(-12 * 3600))
        return NightDate(year: c.year!, month: c.month!, day: c.day!)
    }

    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }

    /// 00:00 KST of this date.
    public var startKST: Date {
        KST.calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    /// "10/12(월)".
    public var label: String {
        let wd = KST.calendar.component(.weekday, from: startKST)
        return "\(month)/\(day)(\(KST.weekdays[wd - 1]))"
    }

    public static func < (a: NightDate, b: NightDate) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }
}

/// Timestamps in packs come from Java's `OffsetDateTime.toString()`, which drops zero seconds
/// ("2026-10-12T17:00+09:00") and may add fractions ("…:04.5+09:00"). ISO8601DateFormatter rejects the
/// first form, hence this small parser: `yyyy-MM-ddTHH:mm[:ss[.f…]](Z|±HH:mm)`.
public enum PackTime {
    public static func parse(_ s: String) -> Date? {
        let u = Array(s.utf8)
        func num(_ from: Int, _ len: Int) -> Int? {
            guard from + len <= u.count else { return nil }
            var v = 0
            for b in u[from..<(from + len)] {
                guard b >= 48, b <= 57 else { return nil }
                v = v * 10 + Int(b - 48)
            }
            return v
        }
        func at(_ i: Int, _ ch: Character) -> Bool { i < u.count && u[i] == ch.asciiValue! }
        guard u.count >= 17, let y = num(0, 4), at(4, "-"), let mo = num(5, 2), at(7, "-"), let d = num(8, 2),
              at(10, "T"), let h = num(11, 2), at(13, ":"), let mi = num(14, 2) else { return nil }
        var i = 16
        var sec = 0.0
        if at(i, ":") {
            guard let ss = num(i + 1, 2) else { return nil }
            sec = Double(ss)
            i += 3
            if at(i, ".") {
                var j = i + 1, frac = 0.0, scale = 0.1
                while j < u.count, u[j] >= 48, u[j] <= 57 { frac += Double(u[j] - 48) * scale; scale /= 10; j += 1 }
                guard j > i + 1 else { return nil }
                sec += frac
                i = j
            }
        }
        var offset = 0
        if at(i, "Z") {
            i += 1
        } else if at(i, "+") || at(i, "-") {
            let sign = at(i, "-") ? -1 : 1
            guard let oh = num(i + 1, 2), at(i + 3, ":"), let om = num(i + 4, 2) else { return nil }
            offset = sign * (oh * 3600 + om * 60)
            i += 6
        } else {
            return nil
        }
        guard i == u.count, (1...12).contains(mo), (1...31).contains(d), (0...23).contains(h), (0...59).contains(mi),
              sec < 61 else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let base = cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi)) else { return nil }
        return base.addingTimeInterval(sec - Double(offset))
    }
}
