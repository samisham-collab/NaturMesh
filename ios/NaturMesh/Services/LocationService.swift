import Foundation
import CoreLocation
import Combine

/// Position is optional and only attached to SOS, check-ins and periodic shares the user turns on.
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var current: GeoPoint?
    @Published private(set) var heading: Double?
    @Published private(set) var authorized = false

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 15
        manager.pausesLocationUpdatesAutomatically = true
    }

    func requestAccess() { manager.requestWhenInUseAuthorization() }

    func start() {
        guard authorized else { requestAccess(); return }
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
    }

    func stop() { manager.stopUpdatingLocation(); manager.stopUpdatingHeading() }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        authorized = m.authorizationStatus == .authorizedWhenInUse || m.authorizationStatus == .authorizedAlways
        if authorized { start() }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last, l.horizontalAccuracy >= 0 else { return }
        current = GeoPoint(latitude: l.coordinate.latitude, longitude: l.coordinate.longitude,
                           accuracyMeters: UInt16(min(65535, max(0, l.horizontalAccuracy))))
    }

    func locationManager(_ m: CLLocationManager, didUpdateHeading h: CLHeading) {
        heading = h.trueHeading >= 0 ? h.trueHeading : h.magneticHeading
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}
}

extension GeoPoint {
    /// Great-circle distance in metres.
    func distance(to o: GeoPoint) -> Double {
        let r = 6_371_000.0
        let dLat = (o.latitude - latitude) * .pi / 180
        let dLon = (o.longitude - longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(latitude * .pi / 180) * cos(o.latitude * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * atan2(sqrt(a), sqrt(1 - a))
    }

    /// Initial bearing in degrees from north.
    func bearing(to o: GeoPoint) -> Double {
        let lat1 = latitude * .pi / 180, lat2 = o.latitude * .pi / 180
        let dLon = (o.longitude - longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let deg = atan2(y, x) * 180 / .pi
        return (deg + 360).truncatingRemainder(dividingBy: 360)
    }

    static func format(distanceMeters d: Double) -> String {
        if d < 1000 { return "\(Int(d.rounded())) m" }
        return String(format: "%.1f km", d / 1000)
    }
}
