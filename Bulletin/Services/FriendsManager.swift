import Foundation
import Contacts
import Combine
import UIKit

/// A friend is a phone contact whose email address or phone number belongs to a
/// Bulletin account. Names and photos come from the local address book; matches
/// are made with one-way hashes, so the address book never leaves the device.
struct ContactFriend: Identifiable, Equatable {
    let id: String        // Firebase uid of the matched account
    let name: String
    let email: String?
    let phone: String?
    let imageData: Data?

    var initials: String {
        let letters = name
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first }
        let result = String(letters).uppercased()
        if !result.isEmpty { return result }
        return String((email ?? phone ?? "?").prefix(1)).uppercased()
    }

    /// Email when the contact has one, otherwise their formatted phone number.
    var subtitle: String {
        email ?? phone ?? ""
    }

    var avatarImage: UIImage? {
        imageData.flatMap(UIImage.init(data:))
    }

    func merging(_ candidate: ContactCandidate) -> ContactFriend {
        ContactFriend(
            id: id,
            name: name.isEmpty ? candidate.name : name,
            email: email ?? candidate.email,
            phone: phone ?? candidate.phone,
            imageData: imageData ?? candidate.imageData
        )
    }
}

/// One hash plus the local contact details needed to display a match. A contact
/// with both an email and a phone produces two candidates; the display fields
/// are merged after a match is found.
struct ContactCandidate {
    let hash: String
    let name: String
    let email: String?
    let phone: String?
    let imageData: Data?
}

/// Matches the device's contacts against registered accounts and tracks which
/// events those friends have joined.
@MainActor
final class FriendsManager: ObservableObject {
    static let shared = FriendsManager()

    @Published private(set) var authorization: CNAuthorizationStatus =
        CNContactStore.authorizationStatus(for: .contacts)
    @Published private(set) var friends: [String: ContactFriend] = [:]
    @Published private(set) var joinedEventIDsByUID: [String: Set<String>] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var errorText: String?

    private let store = CNContactStore()
    private var lastUpdated: Date?
    private let refreshInterval: TimeInterval = 60
    private let maxFriends = 150

    var hasAccess: Bool {
        authorization == .authorized || authorization == .limited
    }

    var isDenied: Bool {
        authorization == .denied || authorization == .restricted
    }

    var needsPermission: Bool {
        authorization == .notDetermined
    }

    var authorizationLabel: String {
        switch authorization {
        case .authorized: return "On"
        case .limited: return "Limited"
        case .denied, .restricted: return "Off"
        case .notDetermined: return "Not set"
        @unknown default: return "Unknown"
        }
    }

    // MARK: - Permission

    /// Shows the system contacts prompt (once) and loads matches if granted.
    @discardableResult
    func requestAccess() async -> Bool {
        let granted: Bool = await withCheckedContinuation { continuation in
            store.requestAccess(for: .contacts) { granted, _ in
                continuation.resume(returning: granted)
            }
        }

        authorization = CNContactStore.authorizationStatus(for: .contacts)
        guard granted || authorization == .limited else { return false }

        await refresh(force: true)
        return true
    }

    // MARK: - Matching

    /// Rebuilds the friend list and their joined events. Throttled unless
    /// `force` is true.
    func refresh(force: Bool = false) async {
        authorization = CNContactStore.authorizationStatus(for: .contacts)

        guard hasAccess, !isLoading else { return }
        guard let uid = FirebaseManager.shared.uid else { return }
        if !force, let lastUpdated, Date().timeIntervalSince(lastUpdated) < refreshInterval {
            return
        }

        isLoading = true
        defer { isLoading = false }

        await FirebaseManager.shared.publishDirectoryEntry()

        let contacts = await Task.detached(priority: .userInitiated) {
            FriendsManager.matchingCandidates()
        }.value

        guard !contacts.isEmpty else {
            friends = [:]
            joinedEventIDsByUID = [:]
            lastUpdated = Date()
            return
        }

        let directory = await FirebaseManager.shared.fetchDirectory()

        var matched: [String: ContactFriend] = [:]
        for candidate in contacts {
            guard let uids = directory[candidate.hash] else { continue }
            for friendUID in uids where friendUID != uid {
                if let existing = matched[friendUID] {
                    matched[friendUID] = existing.merging(candidate)
                } else {
                    matched[friendUID] = ContactFriend(
                        id: friendUID,
                        name: candidate.name,
                        email: candidate.email,
                        phone: candidate.phone,
                        imageData: candidate.imageData
                    )
                }
            }
        }

        let limited = Dictionary(
            uniqueKeysWithValues: matched.keys.prefix(maxFriends).map { ($0, Set<String>()) }
        )

        // Fetch each friend's RSVP list in parallel.
        let attendance = await withTaskGroup(
            of: (String, Set<String>).self,
            returning: [String: Set<String>].self
        ) { group in
            for friendUID in limited.keys {
                group.addTask {
                    let ids = await FirebaseManager.shared.fetchJoinedEventIDs(for: friendUID)
                    return (friendUID, ids)
                }
            }

            var result: [String: Set<String>] = [:]
            for await (friendUID, ids) in group {
                result[friendUID] = ids
            }
            return result
        }

        friends = matched
        joinedEventIDsByUID = attendance
        lastUpdated = Date()
        errorText = nil
    }

    /// Drops cached matches — used on sign-out and when access is revoked.
    func reset() {
        friends = [:]
        joinedEventIDsByUID = [:]
        lastUpdated = nil
        errorText = nil
        authorization = CNContactStore.authorizationStatus(for: .contacts)
    }

    // MARK: - Queries

    func friendsGoing(to eventID: UUID) -> [ContactFriend] {
        let key = eventID.uuidString
        return joinedEventIDsByUID
            .compactMap { uid, ids in ids.contains(key) ? friends[uid] : nil }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The matched friend behind an event's creator, if the organizer is in the
    /// device's contacts.
    func friend(uid: String?) -> ContactFriend? {
        guard let uid else { return nil }
        return friends[uid]
    }

    func isOrganizerFriend(_ event: Event) -> Bool {
        friend(uid: event.creatorUid) != nil
    }

    /// Everyone going plus the organizer. Including the organizer explicitly
    /// means a friend still appears when their own joined list hasn't synced
    /// yet (for example, right after they post an event).
    func friendsForEvent(_ event: Event) -> [ContactFriend] {
        var list = friendsGoing(to: event.id)
        if let organizer = friend(uid: event.creatorUid),
           !list.contains(where: { $0.id == organizer.id }) {
            list.insert(organizer, at: 0)
        }
        return list
    }

    // MARK: - Address book

    /// Reads contact names, email addresses, phone numbers, and thumbnails, and
    /// hashes the emails and numbers. Runs off the main actor because address
    /// books can be large. Photos and names are only ever shown on this device.
    nonisolated private static func matchingCandidates() -> [ContactCandidate] {
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)

        var candidates: [ContactCandidate] = []
        var seenHashes = Set<String>()

        do {
            try store.enumerateContacts(with: request) { contact, _ in
                let name = [contact.givenName, contact.familyName]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")

                var values: [(hash: String, email: String?, phone: String?)] = []

                for entry in contact.emailAddresses {
                    let email = (entry.value as String)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    guard email.contains("@") else { continue }

                    values.append((
                        hash: FirebaseManager.emailHash(email),
                        email: email,
                        phone: nil
                    ))
                }

                for entry in contact.phoneNumbers {
                    let raw = entry.value.stringValue
                    guard let normalized = FirebaseManager.normalizePhone(raw) else { continue }

                    let display = FirebaseManager.formatPhone(normalized)
                    for hash in FirebaseManager.phoneHashVariants(normalized) {
                        values.append((
                            hash: hash,
                            email: nil,
                            phone: display
                        ))
                    }
                }

                for value in values {
                    guard seenHashes.insert(value.hash).inserted else { continue }

                    let fallback = value.email ?? value.phone ?? "Contact"
                    candidates.append(ContactCandidate(
                        hash: value.hash,
                        name: name.isEmpty ? fallback : name,
                        email: value.email,
                        phone: value.phone,
                        imageData: contact.thumbnailImageData
                    ))
                }
            }
        } catch {
            return []
        }

        return candidates
    }
}
