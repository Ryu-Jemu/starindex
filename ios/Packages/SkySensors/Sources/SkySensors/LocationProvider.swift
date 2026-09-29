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
    /// CLHeading accuracy in degrees while heading updates run; −1 after a heading failure, nil when stopped.
    public private(set) var headingAccuracy: Double?
    /// Horizontal accuracy of the last fix in metres (diagnostics only; coordinates are never logged).
    public private(set) var horizontalAccuracy: Double?
    public var onUpdate: (@MainActor (ObserverLocation) -> Void)?
    /// Called when permission, precision or the first fix changes (motion may move up to true north).
    public var onConditionChange: (@MainActor (LocationCondition) -> Void)?

    private let manager = CLLocationManager()
    private var headingActive = false

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
    /// `.reducedAccuracy` unless the user turned on Precise Location.
    public var accuracyAuthorization: CLAccuracyAuthorization { manager.accuracyAuthorization }

    public var condition: LocationCondition {
        LocationCondition(authorized: isAuthorized, precise: accuracyAuthorization == .fullAccuracy, hasFix: lastFix != nil)
    }

    public func requestAuthorization() { manager.requestWhenInUseAuthorization() }

    /// While the sky screen is active: continuous updates (trueHeading needs them) + heading.
    public func startActive() {
        guard isAuthorized else { return }
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() {
            manager.startUpdatingHeading()
            headingActive = true
        }
    }

    public func stopActive() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        headingActive = false
        headingAccuracy = nil
    }

    /// Re-acquire when the app becomes active and the last fix is older than 30 min.
    public var needsRefresh: Bool { lastFix.map { Date().timeIntervalSince($0) > 30 * 60 } ?? true }

    nonisolated public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        let obs = ObserverLocation(latitude: l.coordinate.latitude, longitude: l.coordinate.longitude,
                                   heightMeters: max(0, l.altitude))
        let ts = l.timestamp
        let acc = l.horizontalAccuracy
        Task { @MainActor in
            let firstFix = self.lastFix == nil
            self.observer = obs
            self.lastFix = ts
            self.horizontalAccuracy = acc
            self.onUpdate?(obs)
            if firstFix { self.onConditionChange?(self.condition) }
        }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let acc = newHeading.headingAccuracy
        Task { @MainActor in
            if self.headingActive { self.headingAccuracy = acc }
        }
    }

    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            if self.isAuthorized { self.startActive() } else { self.stopActive() }
            self.onConditionChange?(self.condition)
        }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard (error as? CLError)?.code == .headingFailure else { return }
        Task { @MainActor in
            if self.headingActive { self.headingAccuracy = -1 }
        }
    }
}
#endif
