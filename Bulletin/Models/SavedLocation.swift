import Foundation
import CoreLocation

struct SavedLocation: Identifiable, Codable, Equatable, Hashable {
    var id: UUID = UUID()
    var name: String
    var address: String
    var latitude: Double
    var longitude: Double
    var radiusMiles: Double
    var isHome: Bool = false

    var coordinate: CLLocationCoordinate2D {
        .init(latitude: latitude, longitude: longitude)
    }
}
