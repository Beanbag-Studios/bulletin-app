import Foundation
import CoreLocation

struct FilterOptions: Equatable {

    enum LocationSource: String, CaseIterable, Identifiable {
        case myLocation = "My Location"
        case savedLocation = "Saved Location"
        case anywhere = "Anywhere"
        var id: String { rawValue }
    }

    enum FeeFilter: String, CaseIterable, Identifiable {
        case any = "Any"
        case freeOnly = "Free only"
        case paidOnly = "Paid only"
        var id: String { rawValue }
    }

    var locationSource: LocationSource = .myLocation
    var selectedSavedLocationId: UUID?
    var radiusMiles: Double = 20
    var eventType: Event.Category?
    var feeFilter: FeeFilter = .any

    /// Number of settings that differ from the defaults, shown as a badge.
    var activeCount: Int {
        var count = 0
        if locationSource != .myLocation { count += 1 }
        if radiusMiles != 20 { count += 1 }
        if eventType != nil { count += 1 }
        if feeFilter != .any { count += 1 }
        return count
    }

    func matches(
        event: Event,
        origin: CLLocationCoordinate2D?,
        eventCoordinate: CLLocationCoordinate2D? = nil
    ) -> Bool {
        switch feeFilter {
        case .freeOnly: if !event.isFree { return false }
        case .paidOnly: if event.isFree { return false }
        case .any: break
        }

        if let eventType, event.category != eventType { return false }

        // Distance is only applied when both points are known. Events saved
        // before coordinates existed are resolved by the feed and passed in.
        guard locationSource != .anywhere,
              let origin,
              let destination = eventCoordinate ?? event.coordinate else {
            return true
        }

        let from = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
        let to = CLLocation(latitude: destination.latitude, longitude: destination.longitude)
        let miles = from.distance(from: to) / 1_609.344
        return miles <= radiusMiles
    }
}
