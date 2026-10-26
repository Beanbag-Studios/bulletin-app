import Foundation

/// Everything the legal pages and support links need in one place.
///
/// Replace `supportEmail` with an address you actually monitor before shipping
/// or submitting to the App Store. If you publish under a company or LLC, set
/// `operatorName` to that legal name instead of the app name.
enum LegalConfig {
    static let appName = "Bulletin"
    static let operatorName = "Bulletin"
    static let supportEmail = "support@example.com"

    static let effectiveDate = "October 26, 2026"
    static let termsVersion = "2026-10-26"
    static let jurisdiction = "State of New York, United States"

    static var supportURL: URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = supportEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: "\(appName) Support")
        ]
        return components.url
    }

    static func reportURL(for event: Event) -> URL? {
        let body = [
            "Event ID: \(event.id.uuidString)",
            "Event title: \(event.title)",
            "Organizer: \(event.organizerName)",
            "Address: \(event.address)",
            "",
            "Describe the problem:"
        ]
        .joined(separator: "\n")

        var components = URLComponents()
        components.scheme = "mailto"
        components.path = supportEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: "Report event: \(event.title)"),
            URLQueryItem(name: "body", value: body)
        ]
        return components.url
    }
}
