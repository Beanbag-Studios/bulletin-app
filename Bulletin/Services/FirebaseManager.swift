import Foundation
import Combine
import CryptoKit

// MARK: - Errors

struct FirebaseRESTError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
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

    func signUp(email: String, password: String) async throws {
        let data = try await postIdentity(
            "signUp",
            body: ["email": email, "password": password, "returnSecureToken": true]
        )
        let payload = try decodeAuth(data)
        apply(payload, fallbackEmail: email)

        // Best-effort profile bootstrap. Never block a successful sign-up on it.
        try? await writeProfile(email: email)
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
        await publishDirectoryEntry()
        await publishAttendanceForJoinedEvents()
    }

    func signOut() {
        isSignedIn = false
        userEmail = nil
        uid = nil
        idToken = nil
        refreshToken = nil
        tokenExpiry = nil
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

        // 3. The user's node (profile, joined events, private data).
        try await deletePath("users/\(uid)", token: token)

        // 4. The reversed-hash directory entry used for friend matching.
        if let email = userEmail, !email.isEmpty {
            try await deletePath(
                "public/directory/\(Self.emailHash(email))/\(uid)",
                token: token
            )
        }

        // 5. The Firebase Authentication record itself.
        _ = try await postIdentity("delete", body: ["idToken": token])

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

        // The organizer counts as going, so the public attendance list is
        // complete from the moment the event is posted.
        try? await setAttendance(eventID: event.id, attending: true)
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

    /// A private lookup table that lets a device match a contact's email to a
    /// Bulletin account without uploading the address book. Only a SHA-256 hash
    /// of the normalized email is stored.
    nonisolated static func emailHash(_ email: String) -> String {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Adds the signed-in account to the hash directory used for friend
    /// matching. Safe to call repeatedly.
    func publishDirectoryEntry() async {
        guard let token = await validToken(),
              let uid,
              let email = userEmail?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !email.isEmpty else {
            return
        }

        try? await putRawJSON(
            path: "public/directory/\(Self.emailHash(email))/\(uid)",
            json: "true",
            token: token
        )
    }

    /// Maps every hashed email in the directory to the account UIDs using it.
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
