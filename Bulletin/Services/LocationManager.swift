import Foundation
import CoreLocation
import MapKit
import Combine

@MainActor
final class LocationManager: NSObject, ObservableObject {
    static let shared = LocationManager()

    @Published var authorization: CLAuthorizationStatus = .notDetermined
    @Published var currentLocation: CLLocation?
    @Published var savedLocations: [SavedLocation] = []
    @Published var selectedLocation: SavedLocation?
    @Published var isLoading = false

    private let manager = CLLocationManager()
    private let savedKey = "bulletin_saved_locations_v1"
    private let selectedKey = "bulletin_selected_location_id"

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        loadSaved()
        authorization = manager.authorizationStatus
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    func requestCurrentLocation() {
        guard authorization == .authorizedWhenInUse || authorization == .authorizedAlways else {
            requestPermission()
            return
        }
        manager.requestLocation()
    }

    private func loadSaved() {
        if let data = UserDefaults.standard.data(forKey: savedKey),
           let decoded = try? JSONDecoder().decode([SavedLocation].self, from: data) {
            savedLocations = decoded
        }

        // The app's default search radius moved from 10 to 20 miles. Upgrade
        // locations that still carry the old default exactly once.
        let radiusMigrationKey = "bulletin_radius_default_v2"
        if !UserDefaults.standard.bool(forKey: radiusMigrationKey) {
            var changed = false
            for index in savedLocations.indices where savedLocations[index].radiusMiles == 10 {
                savedLocations[index].radiusMiles = 20
                changed = true
            }
            UserDefaults.standard.set(true, forKey: radiusMigrationKey)
            if changed, let data = try? JSONEncoder().encode(savedLocations) {
                UserDefaults.standard.set(data, forKey: savedKey)
            }
        }

        if let selId = UserDefaults.standard.string(forKey: selectedKey),
           let found = savedLocations.first(where: { $0.id.uuidString == selId }) {
            selectedLocation = found
        } else {
            selectedLocation = savedLocations.first
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(savedLocations) {
            UserDefaults.standard.set(data, forKey: savedKey)
        }
        if let sel = selectedLocation {
            UserDefaults.standard.set(sel.id.uuidString, forKey: selectedKey)
        }
    }

    func addLocation(_ loc: SavedLocation) {
        savedLocations.append(loc)
        selectedLocation = loc
        persist()
    }

    func updateRadius(for id: UUID, miles: Double) {
        guard let idx = savedLocations.firstIndex(where: { $0.id == id }) else { return }
        savedLocations[idx].radiusMiles = miles
        if selectedLocation?.id == id { selectedLocation?.radiusMiles = miles }
        persist()
    }

    func select(_ loc: SavedLocation) {
        selectedLocation = loc
        persist()
    }

    func delete(_ loc: SavedLocation) {
        savedLocations.removeAll { $0.id == loc.id }
        if selectedLocation?.id == loc.id { selectedLocation = savedLocations.first }
        persist()
    }

    func searchAppleMaps(query: String) async -> [MKMapItem] {
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = query
        if let loc = currentLocation { req.region = MKCoordinateRegion(center: loc.coordinate, latitudinalMeters: 50000, longitudinalMeters: 50000) }
        let search = MKLocalSearch(request: req)
        let resp = try? await search.start()
        return resp?.mapItems ?? []
    }

    /// Forward-geocodes a typed address into a map item (name, address, coordinates).
    func geocodeMapItem(_ address: String) async -> MKMapItem? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let request = MKGeocodingRequest(addressString: trimmed) {
            if let loc = currentLocation ?? selectedLocation.map({ CLLocation(latitude: $0.latitude, longitude: $0.longitude) }) {
                request.region = MKCoordinateRegion(
                    center: loc.coordinate,
                    latitudinalMeters: 80_000,
                    longitudinalMeters: 80_000
                )
            }
            if let items = try? await request.mapItems, let first = items.first {
                return first
            }
        }

        // Fall back to a natural-language search if the strict geocoder misses.
        return await searchAppleMaps(query: trimmed).first
    }

    /// Turns the device's coordinates into a readable address.
    func reverseGeocode(_ location: CLLocation) async -> MKMapItem? {
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        let items = try? await request.mapItems
        return items?.first
    }

    /// Resolves just the coordinate, used for events saved before coordinates existed.
    func coordinate(for address: String) async -> CLLocationCoordinate2D? {
        await geocodeMapItem(address)?.location.coordinate
    }
}

extension LocationManager: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.authorization = manager.authorizationStatus
            if authorization == .authorizedWhenInUse || authorization == .authorizedAlways {
                manager.requestLocation()
            }
        }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in self.currentLocation = locations.last }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { }
}
