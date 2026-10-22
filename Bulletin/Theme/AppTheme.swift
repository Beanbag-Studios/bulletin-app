import SwiftUI

enum AppTheme {
    static let blueMatte = Color(red: 47/255, green: 74/255, blue: 98/255)
    static let blueMatteLight = Color(red: 61/255, green: 90/255, blue: 116/255)
    static let blueMatteMid = Color(red: 74/255, green: 105/255, blue: 133/255)
    static let bluePale = Color(red: 232/255, green: 236/255, blue: 240/255)

    static let white = Color(.systemBackground)
    static let offWhite = Color(.systemBackground)
    static let cardBG = Color(.secondarySystemBackground)
    static let secondaryBG = Color(.secondarySystemBackground)
    static let tertiaryBG = Color(.tertiarySystemBackground)

    static let textPrimary = Color(.label)
    static let textSecondary = Color(.secondaryLabel)
    static let separator = Color(.separator)

    static func gradient(for category: Event.Category) -> LinearGradient {
        switch category {
        case .garageSale: return LinearGradient(colors: [blueMatte, blueMatteLight], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .popUp:      return LinearGradient(colors: [blueMatteLight, blueMatteMid], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .market:     return LinearGradient(colors: [blueMatte, blueMatteMid.opacity(0.9)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .music:      return LinearGradient(colors: [blueMatte, blueMatteLight.opacity(0.95)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .blockParty: return LinearGradient(colors: [blueMatteMid, blueMatte], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .workshop:   return LinearGradient(colors: [blueMatteLight, blueMatte], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .all:        return LinearGradient(colors: [blueMatte, blueMatteLight], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}
