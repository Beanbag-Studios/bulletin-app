import Foundation
import CoreLocation
import UIKit

struct Event: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var title: String
    var category: Category
    var imageSymbol: String
    var bannerBase64: String?
    var galleryBase64: [String] = []
    var address: String
    var neighborhood: String
    var latitude: Double? = nil
    var longitude: Double? = nil
    var distance: String
    var dateText: String
    var timeText: String
    var eventDate: Date
    var organizerName: String
    var organizerInitials: String
    var description: String
    var creatorUid: String?
    var isFree: Bool
    var attendeeCount: Int = 0
    var createdAt: Date = Date()

    var bannerImage: UIImage? {
        guard let b64 = bannerBase64, let data = Data(base64Encoded: b64) else { return nil }
        return UIImage(data: data)
    }
    var galleryImages: [UIImage] {
        galleryBase64.compactMap { Data(base64Encoded: $0) }.compactMap { UIImage(data: $0) }
    }
    var allImages: [UIImage] {
        var out: [UIImage] = []
        if let b = bannerImage { out.append(b) }
        out.append(contentsOf: galleryImages)
        return out
    }
    var isPast: Bool { eventDate < Date() }

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    enum Category: String, CaseIterable, Identifiable, Codable {
        case all = "All"
        case garageSale = "Garage Sales"
        case popUp = "Pop-ups"
        case market = "Markets"
        case music = "Music"
        case blockParty = "Block Parties"
        case workshop = "Workshops"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .all: return "square.grid.2x2"
            case .garageSale: return "house.fill"
            case .popUp: return "storefront.fill"
            case .market: return "basket.fill"
            case .music: return "music.note"
            case .blockParty: return "party.popper.fill"
            case .workshop: return "hammer.fill"
            }
        }
    }

    func toDict() -> [String: Any] {
        var dict: [String: Any] = [
            "id": id.uuidString,
            "title": title,
            "category": category.rawValue,
            "imageSymbol": imageSymbol,
            "bannerBase64": bannerBase64 ?? "",
            "galleryBase64": galleryBase64,
            "address": address,
            "neighborhood": neighborhood,
            "distance": distance,
            "dateText": dateText,
            "timeText": timeText,
            "eventDate": eventDate.timeIntervalSince1970,
            "organizerName": organizerName,
            "organizerInitials": organizerInitials,
            "description": description,
            "isFree": isFree,
            "createdAt": createdAt.timeIntervalSince1970 * 1000
        ]
        if let creatorUid { dict["creatorUid"] = creatorUid }
        if let latitude { dict["latitude"] = latitude }
        if let longitude { dict["longitude"] = longitude }
        return dict
    }

    static func fromDict(_ dict: [String: Any]) -> Event? {
        guard let title = dict["title"] as? String else { return nil }
        let idStr = dict["id"] as? String ?? UUID().uuidString
        let catRaw = dict["category"] as? String ?? Category.garageSale.rawValue
        // Older records stored millisecond timestamps; new ones store seconds.
        let rawDate = (dict["eventDate"] as? Double) ?? Date().timeIntervalSince1970
        let eventInterval = rawDate > 100_000_000_000 ? rawDate / 1000 : rawDate
        let rawCreated = (dict["createdAt"] as? Double) ?? 0
        let createdInterval = rawCreated > 100_000_000_000 ? rawCreated / 1000 : rawCreated
        return Event(
            id: UUID(uuidString: idStr) ?? UUID(),
            title: title,
            category: Category(rawValue: catRaw) ?? .garageSale,
            imageSymbol: dict["imageSymbol"] as? String ?? "house.lodge.fill",
            bannerBase64: (dict["bannerBase64"] as? String)?.isEmpty == true ? nil : dict["bannerBase64"] as? String,
            galleryBase64: dict["galleryBase64"] as? [String] ?? [],
            address: dict["address"] as? String ?? "",
            neighborhood: dict["neighborhood"] as? String ?? "",
            latitude: dict["latitude"] as? Double,
            longitude: dict["longitude"] as? Double,
            distance: dict["distance"] as? String ?? "",
            dateText: dict["dateText"] as? String ?? "",
            timeText: dict["timeText"] as? String ?? "",
            eventDate: Date(timeIntervalSince1970: eventInterval),
            organizerName: dict["organizerName"] as? String ?? "You",
            organizerInitials: dict["organizerInitials"] as? String ?? "YY",
            description: dict["description"] as? String ?? "",
            creatorUid: dict["creatorUid"] as? String,
            isFree: dict["isFree"] as? Bool ?? true,
            attendeeCount: dict["attendeeCount"] as? Int ?? 0,
            createdAt: createdInterval > 0 ? Date(timeIntervalSince1970: createdInterval) : Date()
        )
    }
}
