import Foundation
import Testing
@testable import SkyCore

@Suite("T17 해질녘 재생")
struct SunsetPlaybackTests {
    /// Local mean noon (UTC) for a date and longitude, so the search finds that evening's sunset.
    func localNoon(_ day: String, longitude: Double) -> Date {
        utc("\(day)T12:00:00Z").addingTimeInterval(-longitude / 15 * 3600)
    }

    func plan(_ day: String, lat: Double, lon: Double) -> SunsetPlaybackPlan? {
        SunsetPlaybackPlanner.plan(after: localNoon(day, longitude: lon), observer: ObserverLocation(latitude: lat, longitude: lon))
    }

    @Test("Seoul: about 20 s, ends at astronomical dusk", arguments: ["2026-09-29", "2026-06-21", "2026-12-21"])
    func seoul(day: String) throws {
        let obs = ObserverLocation.seoul
        let plan = try #require(SunsetPlaybackPlanner.plan(after: localNoon(day, longitude: obs.longitude), observer: obs))
        #expect(plan.totalRealSeconds >= 18 && plan.totalRealSeconds <= 21, "\(day): \(plan.totalRealSeconds)")
        #expect(plan.endReason == .astronomicalDusk)
        #expect(plan.segments.count == 2)
        #expect(plan.segments[0].speed >= 300)
        #expect(!plan.showsNoAstronomicalDuskNotice)
    }

    @Test("High latitudes in June: 18–21 s, expected end reason, no division by zero",
          arguments: [(55.0, SunsetPlaybackPlan.EndReason.sunsetPlus3h, 2),
                      (60.0, .lowerCulmination, 2),
                      (62.0, .lowerCulmination, 1)])
    func highLatitude(lat: Double, reason: SunsetPlaybackPlan.EndReason, segments: Int) throws {
        let p = try #require(plan("2026-06-21", lat: lat, lon: 25))
        #expect(p.totalRealSeconds >= 18 && p.totalRealSeconds <= 21, "lat \(lat): \(p.totalRealSeconds)")
        #expect(p.endReason == reason, "lat \(lat): \(p.endReason)")
        #expect(p.segments.count == segments)
        for s in p.segments { #expect(s.speed.isFinite && s.speed >= 1) }
        #expect(p.showsNoAstronomicalDuskNotice)          // the Sun never reaches −18° there in June
        if segments == 1 { #expect(abs(p.totalRealSeconds - 20) < 1e-6) }
    }

    @Test("48°N in June: stopped by the 3 h cap, notice not shown")
    func capNotNotice() throws {
        let p = try #require(plan("2026-06-21", lat: 48.0, lon: 11.0))
        #expect(p.endReason == .sunsetPlus3h)
        #expect(abs(p.end.timeIntervalSince(p.sunset) - 3 * 3600) < 1e-3)
        #expect(!p.showsNoAstronomicalDuskNotice)
        #expect(p.totalRealSeconds >= 18 && p.totalRealSeconds <= 21)
    }

    @Test("Polar day (70°N, June): no sunset → nil")
    func polarDay() {
        #expect(plan("2026-06-21", lat: 70.0, lon: 25) == nil)
    }

    @Test("Right after sunset the next evening is still found (2-day search window)")
    func rightAfterSunset() throws {
        let obs = ObserverLocation.seoul
        let sunset = try #require(RiseSetService.sunset(after: localNoon("2027-03-20", longitude: obs.longitude), observer: obs))
        for minutes in [1.0, 5, 30] {
            #expect(SunsetPlaybackPlanner.plan(after: sunset.addingTimeInterval(minutes * 60), observer: obs) != nil)
        }
    }

    @Test("Twilight crossings are ordered: sunset < −6° < −12° < −18° (Seoul)")
    func ordering() throws {
        let obs = ObserverLocation.seoul
        let noon = localNoon("2026-09-29", longitude: obs.longitude)
        let sunset = try #require(RiseSetService.sunset(after: noon, observer: obs))
        let c6 = try #require(RiseSetService.duskCrossing(altitudeDeg: -6, after: sunset, observer: obs))
        let c12 = try #require(RiseSetService.duskCrossing(altitudeDeg: -12, after: sunset, observer: obs))
        let c18 = try #require(RiseSetService.duskCrossing(altitudeDeg: -18, after: sunset, observer: obs))
        #expect(sunset < c6 && c6 < c12 && c12 < c18)
        // Civil twilight in Seoul lasts roughly 24–30 minutes at this time of year.
        let civil = c6.timeIntervalSince(sunset) / 60
        #expect(civil > 20 && civil < 35, "civil \(civil) min")
        let state = try #require(SolarState.compute(date: c6.addingTimeInterval(60), observer: obs))
        #expect(state.phase.official == .nautical)
        #expect(state.phase.isEvening)
    }
}
