import Foundation
import CoreLocation

/// Provides human-readable location labels for GPT question generation.
/// Per PRD LOC-02: format as "Near {town}, {state} ({major city} area)".
/// Per PRD LOC-05: NEVER send raw coordinates to GPT.
class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {

    static let shared = LocationService()

    @Published private(set) var currentLocationLabel: String?
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

    private let locationManager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var lastLocation: CLLocation?

    private override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer // area-level, not precise
        locationManager.distanceFilter = 5000 // Update every ~5km
    }

    // MARK: - Authorization

    func requestAuthorization() {
        locationManager.requestWhenInUseAuthorization()
    }

    func startUpdating() {
        locationManager.startUpdatingLocation()
    }

    func stopUpdating() {
        locationManager.stopUpdatingLocation()
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        lastLocation = location
        reverseGeocode(location)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if manager.authorizationStatus == .authorizedWhenInUse ||
           manager.authorizationStatus == .authorizedAlways {
            startUpdating()
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // PRD LOC-03 / INT-005: fallback to last known label or broad region
        if currentLocationLabel == nil {
            currentLocationLabel = "somewhere in the United States"
        }
    }

    // MARK: - Reverse Geocoding

    /// Converts coordinates to human-readable label per PRD LOC-02 format.
    /// Never exposes raw coordinates — only the label is sent to GPT.
    private func reverseGeocode(_ location: CLLocation) {
        geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, error in
            guard let placemark = placemarks?.first else {
                // Fallback: keep last label or use state-level
                return
            }

            let label = Self.formatLocationLabel(from: placemark)
            DispatchQueue.main.async {
                self?.currentLocationLabel = label
            }
        }
    }

    /// Formats: "Near {town}, {state} ({major city} area)"
    /// Falls back gracefully: town → city → state → country
    static func formatLocationLabel(from placemark: CLPlacemark) -> String {
        let town = placemark.locality
        let state = placemark.administrativeArea
        let majorCity = placemark.subAdministrativeArea

        if let town, let state {
            if let majorCity, majorCity != town {
                return "Near \(town), \(state) (\(majorCity) area)"
            }
            return "Near \(town), \(state)"
        }

        if let state {
            return "Somewhere in \(state)"
        }

        if let country = placemark.country {
            return "Somewhere in \(country)"
        }

        return "somewhere in the United States"
    }
}
