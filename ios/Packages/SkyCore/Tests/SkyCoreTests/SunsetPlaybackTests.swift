import Foundation
import Testing
@testable import SkyCore

@Suite("T17 해질녘 재생")
struct SunsetPlaybackTests {
    /// Local mean noon (UTC) for a date and longitude, so the search finds that evening's sunset.
    func localNoon(_ day: String, longitude: Double) -> Date {
        utc("\(day)T12:00:00Z").addingTimeInterval(-longitude / 15 * 3600)
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

    @Test("High latitudes in June stay ≤ 21 s without division by zero", arguments: [55.0, 60.0, 62.0])
    func highLatitude(lat: Double) throws {
        let obs = ObserverLocation(latitude: lat, longitude: 25.0)
        let plan = try #require(SunsetPlaybackPlanner.plan(after: localNoon("2026-06-21", longitude: 25), observer: obs))
        #expect(plan.totalRealSeconds <= 21, "lat \(lat): \(plan.totalRealSeconds)")
        for s in plan.segments { #expect(s.speed.isFinite && s.speed >= 1) }
        #expect(plan.showsNoAstronomicalDuskNotice)   // Sun never reaches −18° there in June
    }

    @Test("48°N in June: stopped by the 3 h cap, notice not shown")
    func capNotNotice() throws {
        let obs = ObserverLocation(latitude: 48.0, longitude: 11.0)
        let plan = try #require(SunsetPlaybackPlanner.plan(after: localNoon("2026-06-21", longitude: 11), observer: obs))
        #expect(!plan.showsNoAstronomicalDuskNotice)
        #expect(plan.totalRealSeconds <= 21)
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
