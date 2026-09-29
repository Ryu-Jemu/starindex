#if canImport(CoreLocation) && os(iOS)
import CoreLocation
import Foundation
import SkyCore

/// Approximate location for the sky view. Coordinates never leave the device (plan D4).
/// Info.plist sets `NSLocationDefaultAccuracyReduced = YES`.
@MainActor
public final class LocationProvider: NSObject, CLLocationManagerDelegate {
    public private(set) var observer: ObserverLocation?
    public private(set) var lastFix: Date?
    public private(set) var headingAccuracy: Double?
    public var onUpdate: (@MainActor (ObserverLocation) -> Void)?

    private let manager = CLLocationManager()

    public override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyReduced
        manager.distanceFilter = 1000
    }

    public var authorization: CLAuthorizationStatus { manager.authorizationStatus }
    public var isAuthorized: Bool {
        authorization == .authorizedWhenInUse || authorization == .authorizedAlways
    }

    public func requestAuthorization() { manager.requestWhenInUseAuthorization() }

    /// While the sky screen is active: continuous updates (trueHeading needs them) + heading.
    public func startActive() {
        guard isAuthorized else { return }
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
    }

    public func stopActive() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
    }

    /// Re-acquire when the app becomes active and the last fix is older than 30 min.
    public var needsRefresh: Bool { lastFix.map { Date().timeIntervalSince($0) > 30 * 60 } ?? true }

    nonisolated public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        let obs = ObserverLocation(latitude: l.coordinate.latitude, longitude: l.coordinate.longitude,
                                   heightMeters: max(0, l.altitude))
        let ts = l.timestamp
        Task { @MainActor in
            self.observer = obs
            self.lastFix = ts
            self.onUpdate?(obs)
        }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let acc = newHeading.headingAccuracy
        Task { @MainActor in self.headingAccuracy = acc }
    }

    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            if self.isAuthorized { self.startActive() }
        }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
#endif
