import Foundation
import Contacts
import Combine

/// A friend is a phone contact whose email belongs to a Bulletin account.
/// Names come from the local address book; Bulletins are matched by a one-way
/// email hash so the address book never leaves the device.
struct ContactFriend: Identifiable, Equatable {
    let id: String        // Firebase uid of the matched account
    let name: String
    let email: String

    var initials: String {
        let letters = name
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first }
        let result = String(letters).uppercased()
        return result.isEmpty ? String(email.prefix(1)).uppercased() : result
    }
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
            for friendUID in uids where friendUID != uid && matched[friendUID] == nil {
                matched[friendUID] = ContactFriend(
                    id: friendUID,
                    name: candidate.name,
                    email: candidate.email
                )
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

    // MARK: - Address book

    /// Reads contact names and email addresses and hashes the emails. Runs off
    /// the main actor because address books can be large.
    nonisolated private static func matchingCandidates() -> [(hash: String, name: String, email: String)] {
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)

        var candidates: [(hash: String, name: String, email: String)] = []
        var seenHashes = Set<String>()

        do {
            try store.enumerateContacts(with: request) { contact, _ in
                let name = [contact.givenName, contact.familyName]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")

                for entry in contact.emailAddresses {
                    let email = (entry.value as String)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    guard email.contains("@") else { continue }

                    let hash = FirebaseManager.emailHash(email)
                    guard seenHashes.insert(hash).inserted else { continue }

                    candidates.append((
                        hash: hash,
                        name: name.isEmpty ? email : name,
                        email: email
                    ))
                }
            }
        } catch {
            return []
        }

        return candidates
    }
}
