import Foundation
import Combine
import CryptoKit

// MARK: - Errors

struct FirebaseRESTError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The signed-in user's private profile. The raw phone number stays in the
/// iOS Keychain on the device; only a one-way hash is published for friend
/// matching.
struct UserProfile: Equatable {
    var phoneNumber: String
}

// MARK: - Manager

/// A dependency-free Firebase backend.
///
/// The Firebase iOS SDK is not linked into this target, so this class talks to
/// Firebase directly over its public REST APIs:
///   • Identity Toolkit  → email/password auth + password reset
///   • Secure Token      → refresh the short-lived ID token
///   • Realtime Database → events + per-user data
///
/// If the SDK is ever added later, the `#if canImport(FirebaseDatabase)` block
/// at the bottom takes over automatically.
@MainActor
final class FirebaseManager: ObservableObject {

    static let shared = FirebaseManager()

    // MARK: Published state

    @Published private(set) var isSignedIn: Bool = false
    @Published private(set) var userEmail: String?
    @Published private(set) var uid: String?
    @Published private(set) var idToken: String?

    /// Loaded from the Keychain (with a database fallback). Missing until
    /// `loadProfile()` runs.
    @Published private(set) var profile: UserProfile?
    @Published private(set) var isProfileLoaded = false

    var phoneNumber: String? {
        profile?.phoneNumber
    }

    /// True only after a real profile fetch, so the app never flashes a prompt
    /// while the session is still restoring.
    var needsPhoneNumber: Bool {
        isSignedIn && isProfileLoaded && (phoneNumber ?? "").isEmpty
    }

    // MARK: Private state

    private var refreshToken: String?
    private var tokenExpiry: Date?
    private let session: URLSession

    private let apiKey: String
    private let databaseURL: String

    private enum StoreKey {
        static let uid = "bulletin.auth.uid"
        static let email = "bulletin.auth.email"
        static let idToken = "bulletin.auth.idToken"
        static let refreshToken = "bulletin.auth.refreshToken"
        static let expiry = "bulletin.auth.expiry"

        static func phone(uid: String) -> String {
            "bulletin.profile.phone.\(uid)"
        }
    }

    // MARK: Init

    private init() {
        let config = FirebaseManager.loadConfig()
        self.apiKey = config.apiKey
        self.databaseURL = config.databaseURL

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 25
        cfg.timeoutIntervalForResource = 45
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: cfg)

        restoreSession()
    }

    /// Reads API_KEY and DATABASE_URL out of GoogleService-Info.plist.
    /// Falls back to the known project values so a missing resource file can
    /// never leave the app in a broken state.
    nonisolated private static func loadConfig() -> (apiKey: String, databaseURL: String) {
        let fallbackKey = "AIzaSyCCXeECZQ83BKaFP0XguoPumRs_uPe-Cz0"
        let fallbackDB = "https://bulletinback-63a08-default-rtdb.firebaseio.com"

        guard
            let url = Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist"),
            let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            return (fallbackKey, fallbackDB)
        }

        let key = (plist["API_KEY"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackKey
        let db = (plist["DATABASE_URL"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackDB
        return (key, db.hasSuffix("/") ? String(db.dropLast()) : db)
    }

    // MARK: - Auth

    func signUp(email: String, password: String, phoneNumber: String) async throws {
        let data = try await postIdentity(
            "signUp",
            body: ["email": email, "password": password, "returnSecureToken": true]
        )
        let payload = try decodeAuth(data)
        apply(payload, fallbackEmail: email)

        // Best-effort profile bootstrap. Never block a successful sign-up on it.
        try? await writeProfile(email: email)
        // The phone number is collected during sign-up so contacts can match
        // this account from the very first launch.
        try? await savePhoneNumber(phoneNumber, publish: false)
        await publishDirectoryEntry()
        await publishAttendanceForJoinedEvents()
    }

    func signIn(email: String, password: String) async throws {
        let data = try await postIdentity(
            "signInWithPassword",
            body: ["email": email, "password": password, "returnSecureToken": true]
        )
        let payload = try decodeAuth(data)
        apply(payload, fallbackEmail: email)
        await loadProfile()
        await publishDirectoryEntry()
        await publishAttendanceForJoinedEvents()
    }

    func signOut() {
        // Best-effort cleanup before the session is cleared. Subscriptions and
        // push tokens must not keep delivering alerts after someone signs out.
        if let uid, let token = idToken {
            let pushToken = NotificationManager.shared.deviceToken
            Task {
                try? await self.deletePath(
                    "public/friendSubscriptions/\(uid)",
                    token: token
                )
                try? await self.deletePath(
                    "users/\(uid)/notificationArea",
                    token: token
                )
                if let pushToken {
                    try? await self.deletePath(
                        "users/\(uid)/pushTokens/\(pushToken)",
                        token: token
                    )
                }
            }
        }

        isSignedIn = false
        userEmail = nil
        uid = nil
        idToken = nil
        refreshToken = nil
        tokenExpiry = nil
        profile = nil
        isProfileLoaded = false
        clearSession()
    }

    func sendPasswordReset(email: String) async throws {
        // Response body is not needed; a non-2xx status throws a friendly error.
        _ = try await postIdentity(
            "sendOobCode",
            body: ["requestType": "PASSWORD_RESET", "email": email]
        )
    }

    /// Permanently deletes the signed-in account and the data that belongs to
    /// it. Hosted events, RSVPs, the profile, and the contact-matching directory
    /// entry are removed before the auth record is deleted.
    ///
    /// The order matters: the auth record is deleted last so a failed cleanup
    /// can be retried instead of leaving an unreachable account behind.
    func deleteAccount() async throws {
        guard let uid else {
            throw FirebaseRESTError(message: "You are not signed in.")
        }
        guard let token = await validToken() else {
            throw FirebaseRESTError(message: "Your session expired. Please sign in again.")
        }

        // 1. Hosted events (and their attendance lists). This must succeed
        //    before we delete the account record.
        let hosted = try await fetchUserEvents(uid: uid)
        for event in hosted {
            try await deleteEvent(event)
        }

        // 2. Remove this user's RSVP from events they joined but did not host.
        let joined = try await joinedEventIDsOrThrow(for: uid)
        for id in joined {
            try await deletePath(
                "public/attendance/\(id)/\(uid)",
                token: token
            )
        }

        // 3. The user's node (profile, joined events, private data, push
        //    tokens, and notification area) plus the friend-notification
        //    subscription list.
        try await deletePath("users/\(uid)", token: token)
        try await deletePath("public/friendSubscriptions/\(uid)", token: token)

        // 4. Every reversed-hash directory entry that points at this account.
        //    Reading the directory also cleans up hashes left by a phone number
        //    that was entered on a different device.
        let directory = await fetchDirectory()
        for (hash, uids) in directory where uids.contains(uid) {
            try await deletePath(
                "public/directory/\(hash)/\(uid)",
                token: token
            )
        }

        // 5. The Firebase Authentication record itself.
        _ = try await postIdentity("delete", body: ["idToken": token])

        KeychainStore.delete(StoreKey.phone(uid: uid))
        signOut()
    }

    // MARK: - Events

    /// All events in the database, soonest first. No placeholder/sample data.
    func fetchEvents() async throws -> [Event] {
        let token = await validToken()
        guard let url = databaseURL(path: "events", token: token) else {
            throw FirebaseRESTError(message: "The database URL is invalid.")
        }

        let (data, _) = try await perform(URLRequest(url: url))
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return []
        }

        var events: [Event] = []
        for (key, value) in dict {
            guard var record = value as? [String: Any] else { continue }
            if record["id"] == nil { record["id"] = key }
            if let event = Event.fromDict(record) { events.append(event) }
        }
        return events.sorted { $0.eventDate < $1.eventDate }
    }

    /// A single event, used when a notification opens an event that is not in
    /// the feed yet (for example on a cold launch).
    func fetchEvent(id: UUID) async throws -> Event? {
        let token = await validToken()
        guard let url = databaseURL(
            path: "events/\(id.uuidString)",
            token: token
        ) else {
            throw FirebaseRESTError(message: "The database URL is invalid.")
        }

        let (data, _) = try await perform(URLRequest(url: url))
        guard var record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        if record["id"] == nil { record["id"] = id.uuidString }
        return Event.fromDict(record)
    }

    /// Events created by a specific user.
    func fetchUserEvents(uid: String) async throws -> [Event] {
        let all = try await fetchEvents()
        return all.filter { $0.creatorUid == uid }
    }

    func createEvent(_ event: Event) async throws {
        guard let token = await validToken(), let uid else {
            throw FirebaseRESTError(message: "You must be signed in to create events.")
        }

        var payload = event.toDict()
        payload["creatorUid"] = uid
        payload["createdAt"] = Date().timeIntervalSince1970 * 1000

        try await write(
            path: "events/\(event.id.uuidString)",
            method: "PUT",
            payload: payload,
            token: token
        )

        // The organizer counts as going, so the public attendance list and the
        // organizer's own joined list are complete from the moment the event is
        // posted. Friends rely on that list to see who is attending.
        try? await joinEvent(event)
    }

    func updateEvent(_ event: Event) async throws {
        guard let token = await validToken(), let uid else {
            throw FirebaseRESTError(message: "You must be signed in to edit events.")
        }
        guard event.creatorUid == uid else {
            throw FirebaseRESTError(message: "You can only edit events you created.")
        }

        var payload = event.toDict()
        payload["updatedAt"] = Date().timeIntervalSince1970 * 1000

        try await write(
            path: "events/\(event.id.uuidString)",
            method: "PATCH",
            payload: payload,
            token: token
        )
    }

    func deleteEvent(_ event: Event) async throws {
        guard let token = await validToken(), let uid else {
            throw FirebaseRESTError(message: "You must be signed in to delete events.")
        }
        guard event.creatorUid == uid else {
            throw FirebaseRESTError(message: "You can only delete events you created.")
        }

        // Clear the public attendance list first. The rules allow the event
        // owner to remove it, and doing it before the event is gone means the
        // ownership check can still resolve.
        try? await removeAllAttendance(for: event, token: token)

        guard let url = databaseURL(path: "events/\(event.id.uuidString)", token: token) else {
            throw FirebaseRESTError(message: "The database URL is invalid.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        _ = try await perform(request)
    }

    // MARK: - Push notifications

    /// Stores this device's APNs token under the signed-in account. A person
    /// can have more than one device, so tokens are keyed by the token itself.
    /// The token is removed on sign-out and when APNs reports it as invalid.
    func registerPushToken(_ deviceToken: String, environment: String) async {
        guard let authToken = await validToken(), let uid else { return }
        guard !deviceToken.isEmpty else { return }

        let payload: [String: Any] = [
            "token": deviceToken,
            "environment": environment,
            "platform": "ios",
            "updatedAt": Date().timeIntervalSince1970 * 1000
        ]

        try? await write(
            path: "users/\(uid)/pushTokens/\(deviceToken)",
            method: "PUT",
            payload: payload,
            token: authToken
        )
    }

    func unregisterPushToken(_ deviceToken: String) async {
        guard let authToken = await validToken(), let uid else { return }
        guard !deviceToken.isEmpty else { return }
        try? await deletePath(
            "users/\(uid)/pushTokens/\(deviceToken)",
            token: authToken
        )
    }

    /// Publishes the account IDs of friends this person matched from their
    /// address book. The server uses the reverse lookup to decide whose devices
    /// should receive an alert when one of those friends posts an event.
    ///
    /// Only account IDs are uploaded — never names, phone numbers, emails, or
    /// contact photos. Replacing the whole node also removes friends who are no
    /// longer matched.
    func publishFriendSubscriptions(_ friendUIDs: Set<String>) async {
        guard let authToken = await validToken(), let uid else { return }

        guard !friendUIDs.isEmpty else {
            try? await deletePath(
                "public/friendSubscriptions/\(uid)",
                token: authToken
            )
            return
        }

        var payload: [String: Any] = [:]
        for friendUID in friendUIDs {
            payload[friendUID] = true
        }

        try? await write(
            path: "public/friendSubscriptions/\(uid)",
            method: "PUT",
            payload: payload,
            token: authToken
        )
    }

    /// Saves the person's current search center and radius so the server can
    /// apply the same distance rule to push notifications. Passing `nil`
    /// coordinates (the "Anywhere" filter) removes the area and allows alerts
    /// for all matched friends.
    func saveNotificationArea(
        latitude: Double?,
        longitude: Double?,
        radiusMiles: Double
    ) async {
        guard let authToken = await validToken(), let uid else { return }

        guard let latitude, let longitude else {
            try? await deletePath(
                "users/\(uid)/notificationArea",
                token: authToken
            )
            return
        }

        let payload: [String: Any] = [
            "latitude": latitude,
            "longitude": longitude,
            "radiusMiles": radiusMiles,
            "updatedAt": Date().timeIntervalSince1970 * 1000
        ]

        try? await write(
            path: "users/\(uid)/notificationArea",
            method: "PUT",
            payload: payload,
            token: authToken
        )
    }

    // MARK: - Joining events

    /// Marks the signed-in user as attending. Stored per-user so it works with
    /// the current security rules (a non-owner can't write to another user's
    /// event node).
    func joinEvent(_ event: Event) async throws {
        guard let token = await validToken(), let uid else {
            throw FirebaseRESTError(message: "Sign in to join events.")
        }

        guard let url = databaseURL(
            path: "users/\(uid)/joinedEvents/\(event.id.uuidString)",
            token: token
        ) else {
            throw FirebaseRESTError(message: "The database URL is invalid.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("true".utf8)
        _ = try await perform(request)

        try? await setAttendance(eventID: event.id, attending: true)
    }

    func leaveEvent(_ event: Event) async throws {
        guard let token = await validToken(), let uid else {
            throw FirebaseRESTError(message: "Sign in to manage events.")
        }
        guard let url = databaseURL(
            path: "users/\(uid)/joinedEvents/\(event.id.uuidString)",
            token: token
        ) else {
            throw FirebaseRESTError(message: "The database URL is invalid.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        _ = try await perform(request)

        try? await setAttendance(eventID: event.id, attending: false)
    }

    func fetchJoinedEventIDs() async -> Set<String> {
        guard let uid else { return [] }
        return await fetchJoinedEventIDs(for: uid)
    }

    /// Joined event IDs for any user. The database rules allow any signed-in
    /// user to read attendee lists, which is what powers "friends going".
    func fetchJoinedEventIDs(for userID: String) async -> Set<String> {
        guard let token = await validToken(),
              let url = databaseURL(path: "users/\(userID)/joinedEvents", token: token) else {
            return []
        }
        guard let (data, _) = try? await perform(URLRequest(url: url)),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return []
        }
        return Set(dict.compactMap { $0.value as? Bool == true ? $0.key : nil })
    }

    /// Throwing variant used by account deletion, where a failed read must not
    /// silently leave RSVP data behind.
    private func joinedEventIDsOrThrow(for userID: String) async throws -> Set<String> {
        guard let token = await validToken(),
              let url = databaseURL(path: "users/\(userID)/joinedEvents", token: token) else {
            throw FirebaseRESTError(message: "The database URL is invalid.")
        }

        let (data, _) = try await perform(URLRequest(url: url))
        let object = try? JSONSerialization.jsonObject(with: data)
        if object is NSNull { return [] }
        guard let dict = object as? [String: Any] else { return [] }
        return Set(dict.compactMap { $0.value as? Bool == true ? $0.key : nil })
    }

    // MARK: - Public attendance

    /// A signed-in-readable list of who is going, one boolean per user. It
    /// powers the real attendee count on cards and detail pages without
    /// exposing anything beyond "this account is attending this event".
    private func setAttendance(eventID: UUID, attending: Bool) async throws {
        guard let token = await validToken(), let uid else { return }
        let path = "public/attendance/\(eventID.uuidString)/\(uid)"
        if attending {
            try await putRawJSON(path: path, json: "true", token: token)
        } else {
            try await deletePath(path, token: token)
        }
    }

    private func removeAllAttendance(for event: Event, token: String) async throws {
        try await deletePath("public/attendance/\(event.id.uuidString)", token: token)
    }

    /// Counts for every event in one request. Returns nil when the request
    /// failed, so callers don't overwrite known counts with zero.
    func fetchAttendanceCounts() async -> [String: Int]? {
        guard let token = await validToken(),
              let url = databaseURL(path: "public/attendance", token: token) else {
            return nil
        }
        guard let (data, _) = try? await perform(URLRequest(url: url)) else {
            return nil
        }
        let object = try? JSONSerialization.jsonObject(with: data)
        if object is NSNull { return [:] }
        guard let dict = object as? [String: Any] else { return [:] }

        var counts: [String: Int] = [:]
        for (eventID, value) in dict {
            guard let attendees = value as? [String: Any] else { continue }
            counts[eventID] = attendees.values.filter { ($0 as? Bool) == true }.count
        }
        return counts
    }

    func fetchAttendanceCount(eventID: UUID) async -> Int? {
        guard let token = await validToken(),
              let url = databaseURL(
                path: "public/attendance/\(eventID.uuidString)",
                token: token
              ) else {
            return nil
        }
        guard let (data, _) = try? await perform(URLRequest(url: url)) else {
            return nil
        }
        let object = try? JSONSerialization.jsonObject(with: data)
        if object is NSNull { return 0 }
        guard let dict = object as? [String: Any] else { return 0 }
        return dict.values.filter { ($0 as? Bool) == true }.count
    }

    /// Writes the current user's attendance for every event they have joined or
    /// hosted, and removes RSVPs that point at events which no longer exist.
    func publishAttendanceForJoinedEvents() async {
        guard let uid else { return }
        guard let all = try? await fetchEvents() else { return }

        let valid = Set(all.map(\.id.uuidString))
        var ids = await fetchJoinedEventIDs()

        // Clean up joins for events that were deleted by their organizer.
        if let token = await validToken() {
            for id in ids.subtracting(valid) {
                try? await deletePath("users/\(uid)/joinedEvents/\(id)", token: token)
                try? await deletePath("public/attendance/\(id)/\(uid)", token: token)
            }
        }

        ids = ids.intersection(valid)
        ids.formUnion(all.filter { $0.creatorUid == uid }.map(\.id.uuidString))

        for id in ids.prefix(200) {
            guard let uuid = UUID(uuidString: id) else { continue }
            try? await setAttendance(eventID: uuid, attending: true)
        }
    }

    // MARK: - Contact matching directory

    /// A private lookup table that lets a device match a contact's email or
    /// phone number to a Bulletin account without uploading the address book.
    /// Only a SHA-256 hash of the normalized value is stored, never the value
    /// itself.
    nonisolated static func emailHash(_ email: String) -> String {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Every hash that should match a phone number, regardless of how it was
    /// typed or saved in a contact. The same number commonly appears as
    /// `+1 555 123 4567`, `(555) 123-4567`, `5551234567`, or `001 555…`; all of
    /// those produce at least one shared hash.
    ///
    /// A client-side hash can still be enumerated offline by a determined
    /// attacker. If Bulletin moves to a backend, this should become a keyed
    /// server-side lookup.
    nonisolated static func phoneHashVariants(_ phone: String) -> Set<String> {
        guard let normalized = normalizePhone(phone) else { return [] }
        let digits = normalized.filter(\.isNumber)

        var values = Set<String>([digits])
        if digits.hasPrefix("00") {
            values.insert(String(digits.dropFirst(2)))
        }
        if digits.hasPrefix("0") {
            values.insert(String(digits.dropFirst()))
        }

        var hashes = Set<String>()
        for value in values {
            guard value.count >= 10 else { continue }
            hashes.insert(phoneDigest(value))
            if value.count > 10 {
                hashes.insert(phoneDigest(String(value.suffix(10))))
            }
        }
        return hashes
    }

    nonisolated private static func phoneDigest(_ digits: String) -> String {
        let digest = SHA256.hash(data: Data(("phone:" + digits).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Normalizes a phone number to E.164-ish form so a contact's number and
    /// an account's number produce the same hash. Numbers without a country
    /// code are assumed to be North American (10 digits, or 11 starting with 1).
    nonisolated static func normalizePhone(_ raw: String) -> String? {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop extensions such as "x123" or "ext. 123".
        cleaned = cleaned.replacingOccurrences(
            of: "(?i)(?:ext\\.?|extension|x)\\s*\\d+\\s*$",
            with: "",
            options: .regularExpression
        )

        let digits = cleaned.filter(\.isNumber)

        if cleaned.hasPrefix("+") {
            guard digits.count >= 8 else { return nil }
            return "+" + digits
        }
        guard digits.count >= 10 else { return nil }
        if digits.count == 10 {
            return "+1" + digits
        }
        if digits.count == 11 && digits.hasPrefix("1") {
            return "+" + digits
        }
        return "+" + digits
    }

    /// Formats a stored E.164 North American number for display.
    nonisolated static func formatPhone(_ phone: String) -> String {
        let digits = phone.filter(\.isNumber)
        guard phone.hasPrefix("+1"), digits.count == 11 else { return phone }
        let area = digits.dropFirst().prefix(3)
        let middle = digits.dropFirst(4).prefix(3)
        let last = digits.dropFirst(7)
        return "(\(area)) \(middle)-\(last)"
    }

    /// Adds the signed-in account to the hash directory used for friend
    /// matching. Both the account email and, when present, the phone number are
    /// published. Safe to call repeatedly.
    func publishDirectoryEntry() async {
        guard let token = await validToken(), let uid else { return }

        var hashes = Set<String>()
        if let email = userEmail?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !email.isEmpty {
            hashes.insert(Self.emailHash(email))
        }
        if let phone = profile?.phoneNumber {
            hashes.formUnion(Self.phoneHashVariants(phone))
        }

        for hash in hashes {
            try? await putRawJSON(
                path: "public/directory/\(hash)/\(uid)",
                json: "true",
                token: token
            )
        }
    }

    /// Maps every hashed email or phone number in the directory to the account
    /// UIDs using it.
    func fetchDirectory() async -> [String: [String]] {
        guard let token = await validToken(),
              let url = databaseURL(path: "public/directory", token: token) else {
            return [:]
        }
        guard let (data, _) = try? await perform(URLRequest(url: url)),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return [:]
        }

        var directory: [String: [String]] = [:]
        for (hash, value) in dict {
            guard let entries = value as? [String: Any] else { continue }
            directory[hash] = entries.compactMap { $0.value as? Bool == true ? $0.key : nil }
        }
        return directory
    }

    // MARK: - Profile

    /// Loads the phone number used for friend matching. The raw number stays on
    /// this device (Keychain); the database only ever receives a hash. A value
    /// left by an older build under the owner-only private node is accepted as
    /// a fallback.
    func loadProfile() async {
        guard isSignedIn,
              let uid,
              let token = await validToken() else {
            profile = nil
            isProfileLoaded = false
            return
        }

        var storedPhone = KeychainStore.get(StoreKey.phone(uid: uid))

        if storedPhone == nil {
            storedPhone = await fetchValue(
                path: "users/\(uid)/private/phoneNumber",
                token: token
            ) as? String
        }
        if storedPhone == nil {
            storedPhone = await fetchValue(
                path: "users/\(uid)/profile/phoneNumber",
                token: token
            ) as? String
        }

        if let storedPhone, !storedPhone.isEmpty {
            let normalized = Self.normalizePhone(storedPhone) ?? storedPhone
            if normalized != storedPhone {
                KeychainStore.set(normalized, for: StoreKey.phone(uid: uid))
            }
            profile = UserProfile(phoneNumber: normalized)
        } else {
            profile = nil
        }
        isProfileLoaded = true
    }

    /// Saves a normalized phone number on this device and publishes its hash for
    /// contact matching. Changing the number removes the old hash. The raw
    /// number is never uploaded.
    func savePhoneNumber(_ raw: String, publish: Bool = true) async throws {
        guard let uid else {
            throw FirebaseRESTError(message: "Sign in to save your phone number.")
        }
        guard let normalized = Self.normalizePhone(raw) else {
            throw FirebaseRESTError(
                message: "Enter a valid phone number with its area code."
            )
        }

        let previous = profile?.phoneNumber
        KeychainStore.set(normalized, for: StoreKey.phone(uid: uid))

        profile = UserProfile(phoneNumber: normalized)
        isProfileLoaded = true

        if let previous, previous != normalized, let token = await validToken() {
            for hash in Self.phoneHashVariants(previous) {
                try? await deletePath(
                    "public/directory/\(hash)/\(uid)",
                    token: token
                )
            }
        }

        if publish {
            await publishDirectoryEntry()
        }
    }

    private func writeProfile(email: String) async throws {
        guard let token = await validToken(), let uid else { return }
        try await write(
            path: "users/\(uid)/profile",
            method: "PATCH",
            payload: [
                "email": email,
                "createdAt": Date().timeIntervalSince1970 * 1000,
                "termsVersion": LegalConfig.termsVersion,
                "termsAcceptedAt": Date().timeIntervalSince1970 * 1000
            ],
            token: token
        )
    }

    private func fetchValue(path: String, token: String) async -> Any? {
        guard let url = databaseURL(path: path, token: token) else { return nil }
        guard let (data, _) = try? await perform(URLRequest(url: url)),
              let object = try? JSONSerialization.jsonObject(with: data),
              !(object is NSNull) else {
            return nil
        }
        return object
    }

    func savePrivateAge(_ age: Int) async throws {
        guard let token = await validToken(), let uid else {
            throw FirebaseRESTError(message: "Sign in to save your profile.")
        }
        try await write(
            path: "users/\(uid)/private",
            method: "PATCH",
            payload: ["age": age],
            token: token
        )
    }

    // MARK: - Networking: Identity Toolkit

    private func postIdentity(_ action: String, body: [String: Any]) async throws -> Data {
        guard var components = URLComponents(
            string: "https://identitytoolkit.googleapis.com/v1/accounts:\(action)"
        ) else {
            throw FirebaseRESTError(message: "Could not build the auth request.")
        }
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]

        guard let url = components.url else {
            throw FirebaseRESTError(message: "Could not build the auth request.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await perform(request)
        return data
    }

    // MARK: - Networking: Realtime Database

    private func databaseURL(path: String, token: String?) -> URL? {
        guard var components = URLComponents(string: "\(databaseURL)/\(path).json") else {
            return nil
        }
        if let token, !token.isEmpty {
            components.queryItems = [URLQueryItem(name: "auth", value: token)]
        }
        return components.url
    }

    private func write(
        path: String,
        method: String,
        payload: Any,
        token: String
    ) async throws {
        guard let url = databaseURL(path: path, token: token) else {
            throw FirebaseRESTError(message: "The database URL is invalid.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard JSONSerialization.isValidJSONObject(payload) else {
            throw FirebaseRESTError(message: "That data could not be saved.")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        _ = try await perform(request)
    }

    /// Writes a raw JSON fragment. Realtime Database rejects top-level
    /// primitives through `JSONSerialization`, so booleans are sent as text.
    private func putRawJSON(path: String, json: String, token: String) async throws {
        guard let url = databaseURL(path: path, token: token) else {
            throw FirebaseRESTError(message: "The database URL is invalid.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(json.utf8)
        _ = try await perform(request)
    }

    private func deletePath(_ path: String, token: String) async throws {
        guard let url = databaseURL(path: path, token: token) else {
            throw FirebaseRESTError(message: "The database URL is invalid.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        _ = try await perform(request)
    }

    // MARK: - Core request helper

    @discardableResult
    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw FirebaseRESTError(
                message: "Couldn't reach the server. Check your internet connection."
            )
        }

        guard let http = response as? HTTPURLResponse else {
            throw FirebaseRESTError(message: "The server sent an unexpected response.")
        }

        guard (200..<300).contains(http.statusCode) else {
            let friendly = FirebaseManager.friendlyMessage(from: data)
                ?? "Something went wrong (\(http.statusCode)). Please try again."
            throw FirebaseRESTError(message: friendly)
        }

        return (data, http)
    }

    // MARK: - Token handling

    /// Returns a usable ID token, refreshing it when it is close to expiring.
    private func validToken() async -> String? {
        if let idToken, let tokenExpiry, tokenExpiry > Date().addingTimeInterval(60) {
            return idToken
        }
        return await refreshIDToken()
    }

    private func refreshIDToken() async -> String? {
        guard let refreshToken, !refreshToken.isEmpty else { return nil }
        guard var components = URLComponents(string: "https://securetoken.googleapis.com/v1/token") else {
            return nil
        }
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("grant_type=refresh_token&refresh_token=\(refreshToken)".utf8)

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else {
            return nil
        }

        guard (200..<300).contains(http.statusCode) else {
            // A rejected refresh token means the session is no longer valid.
            // Network/server failures are left alone so the user can retry.
            if [400, 401, 403].contains(http.statusCode) {
                signOut()
            }
            return nil
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newToken = object["id_token"] as? String else {
            return nil
        }

        idToken = newToken
        if let newRefresh = object["refresh_token"] as? String { self.refreshToken = newRefresh }
        let seconds = Double(object["expires_in"] as? String ?? "3600") ?? 3600
        tokenExpiry = Date().addingTimeInterval(seconds)
        persistSession()
        return newToken
    }

    // MARK: - Auth payload

    private struct AuthPayload: Decodable {
        let idToken: String?
        let email: String?
        let localId: String?
        let refreshToken: String?
        let expiresIn: String?
    }

    private func decodeAuth(_ data: Data) throws -> AuthPayload {
        do {
            return try JSONDecoder().decode(AuthPayload.self, from: data)
        } catch {
            throw FirebaseRESTError(message: "The server sent an unexpected auth response.")
        }
    }

    private func apply(_ payload: AuthPayload, fallbackEmail: String) {
        guard let token = payload.idToken, let userID = payload.localId else { return }

        idToken = token
        uid = userID
        userEmail = payload.email ?? fallbackEmail
        refreshToken = payload.refreshToken
        let seconds = Double(payload.expiresIn ?? "3600") ?? 3600
        tokenExpiry = Date().addingTimeInterval(seconds)
        isSignedIn = true
        persistSession()
    }

    // MARK: - Session persistence

    private func persistSession() {
        let defaults = UserDefaults.standard
        defaults.set(uid, forKey: StoreKey.uid)
        defaults.set(userEmail, forKey: StoreKey.email)

        // Auth tokens live in the Keychain, not UserDefaults.
        KeychainStore.set(idToken, for: StoreKey.idToken)
        KeychainStore.set(refreshToken, for: StoreKey.refreshToken)
        defaults.removeObject(forKey: StoreKey.idToken)
        defaults.removeObject(forKey: StoreKey.refreshToken)

        if let tokenExpiry {
            defaults.set(tokenExpiry.timeIntervalSince1970, forKey: StoreKey.expiry)
        } else {
            defaults.removeObject(forKey: StoreKey.expiry)
        }
    }

    private func restoreSession() {
        let defaults = UserDefaults.standard
        guard let storedUID = defaults.string(forKey: StoreKey.uid),
              let storedEmail = defaults.string(forKey: StoreKey.email) else {
            return
        }

        uid = storedUID
        userEmail = storedEmail
        idToken = KeychainStore.get(StoreKey.idToken)
        refreshToken = KeychainStore.get(StoreKey.refreshToken)

        // One-time migration from the older UserDefaults storage.
        if idToken == nil, let legacy = defaults.string(forKey: StoreKey.idToken) {
            idToken = legacy
            KeychainStore.set(legacy, for: StoreKey.idToken)
            defaults.removeObject(forKey: StoreKey.idToken)
        }
        if refreshToken == nil, let legacy = defaults.string(forKey: StoreKey.refreshToken) {
            refreshToken = legacy
            KeychainStore.set(legacy, for: StoreKey.refreshToken)
            defaults.removeObject(forKey: StoreKey.refreshToken)
        }

        guard idToken != nil || refreshToken != nil else {
            clearSession()
            return
        }

        let expiry = defaults.double(forKey: StoreKey.expiry)
        if expiry > 0 {
            tokenExpiry = Date(timeIntervalSince1970: expiry)
        }
        isSignedIn = true
    }

    private func clearSession() {
        let defaults = UserDefaults.standard
        [StoreKey.uid, StoreKey.email, StoreKey.idToken, StoreKey.refreshToken, StoreKey.expiry]
            .forEach { defaults.removeObject(forKey: $0) }

        KeychainStore.delete(StoreKey.idToken)
        KeychainStore.delete(StoreKey.refreshToken)
    }

    // MARK: - Friendly errors

    private static func friendlyMessage(from data: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = object["error"] as? [String: Any]
        else {
            return nil
        }

        let raw = (error["message"] as? String) ?? ""
        let code = raw.components(separatedBy: " ").first ?? raw

        switch code {
        case "EMAIL_NOT_FOUND":
            return "No user record found for that email."
        case "INVALID_PASSWORD":
            return "Incorrect password. Try again."
        case "INVALID_LOGIN_CREDENTIALS":
            return "Email or password is incorrect."
        case "INVALID_EMAIL":
            return "That email address doesn't look right."
        case "EMAIL_EXISTS":
            return "That email is already in use."
        case "WEAK_PASSWORD":
            return "Password must be at least 6 characters."
        case "MISSING_PASSWORD":
            return "Please enter a password."
        case "TOO_MANY_ATTEMPTS_TRY_LATER":
            return "Too many attempts. Please try again later."
        case "USER_DISABLED":
            return "This account has been disabled."
        case "CREDENTIAL_TOO_OLD_LOGIN_AGAIN":
            return "Please sign out and sign in again, then try deleting your account."
        case "USER_NOT_FOUND":
            return "That account no longer exists."
        case "OPERATION_NOT_ALLOWED":
            return "Email sign-in isn't enabled for this project."
        case "PERMISSION_DENIED":
            return "You don't have permission to do that."
        default:
            return raw.isEmpty ? nil : raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
