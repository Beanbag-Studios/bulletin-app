import Foundation
import Combine
import UIKit
import UserNotifications

/// Owns the notification permission prompt, the APNs device token, and the
/// event deep link that arrives when someone taps a friend-event alert.
///
/// The token is registered with the signed-in account so the Cloud Function in
/// `functions/` can deliver a real push even when Bulletin is closed. The raw
/// APNs token is only an opaque routing address; it contains no account data.
@MainActor
final class NotificationManager: NSObject, ObservableObject {
    static let shared = NotificationManager()

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var deviceToken: String?
    @Published private(set) var registrationError: String?

    /// Set by a notification tap or by a cold launch from a notification. The
    /// feed consumes this once it has the matching event.
    @Published private(set) var pendingEventID: String?

    private let center = UNUserNotificationCenter.current()

    private override init() {
        super.init()
    }

    // MARK: - Setup

    /// Call as early as possible (from the app delegate) so a notification that
    /// launches the app is delivered to this delegate.
    func configure() {
        center.delegate = self
        Task { await refreshStatus() }
    }

    /// Reads the current system status. If permission already exists, make sure
    /// APNs has the current token.
    func refreshStatus() async {
        let settings = await center.notificationSettings()
        authorizationStatus = settings.authorizationStatus

        if settings.authorizationStatus == .authorized ||
            settings.authorizationStatus == .provisional ||
            settings.authorizationStatus == .ephemeral {
            registerForRemoteNotifications()
        }
    }

    /// Asks once, on app open, when the person has not made a choice yet.
    /// Apple only shows the system prompt while the status is `.notDetermined`.
    func requestAuthorizationIfNeeded() async {
        let settings = await center.notificationSettings()
        authorizationStatus = settings.authorizationStatus

        switch settings.authorizationStatus {
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(
                    options: [.alert, .badge, .sound]
                )
                await refreshStatus()
                if granted {
                    registerForRemoteNotifications()
                }
            } catch {
                registrationError = error.localizedDescription
            }
        case .authorized, .provisional, .ephemeral:
            registerForRemoteNotifications()
        case .denied:
            break
        @unknown default:
            break
        }
    }

    func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    // MARK: - Token

    /// Called from the app delegate after APNs returns a token. Stored under the
    /// signed-in account. If the person is signed out, the token is kept in
    /// memory and registered after the next sign-in.
    func didRegister(deviceToken data: Data) {
        let token = data.map { String(format: "%02x", $0) }.joined()
        deviceToken = token
        registrationError = nil
        syncTokenWithAccount()
    }

    func didFailToRegister(error: Error) {
        // Simulators do not have an APNs token. Keep this quiet so a normal
        // simulator run does not look like a production failure.
        registrationError = error.localizedDescription
        #if DEBUG
        print("APNs registration failed: \(error.localizedDescription)")
        #endif
    }

    /// Writes the current token to the signed-in user's account, if there is
    /// one. Safe to call repeatedly; the database write is idempotent.
    func syncTokenWithAccount() {
        guard let deviceToken, FirebaseManager.shared.isSignedIn else { return }
        let environment = Self.apnsEnvironment
        Task {
            await FirebaseManager.shared.registerPushToken(
                deviceToken,
                environment: environment
            )
        }
    }

    /// Removes this device from the current account before sign-out so the old
    /// account cannot keep sending alerts to a device now used by someone else.
    func unregisterFromAccount() async {
        guard let deviceToken else { return }
        await FirebaseManager.shared.unregisterPushToken(deviceToken)
    }

    static var apnsEnvironment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    // MARK: - Deep links

    func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) {
        guard let eventID = userInfo["eventID"] as? String, !eventID.isEmpty else {
            return
        }
        pendingEventID = eventID
    }

    func consumePendingEventID() -> String? {
        let id = pendingEventID
        pendingEventID = nil
        return id
    }

    func clearBadge() {
        center.setBadgeCount(0) { _ in }
    }

    var authorizationLabel: String {
        switch authorizationStatus {
        case .notDetermined: return "Not set"
        case .denied: return "Off"
        case .authorized: return "On"
        case .provisional: return "Quiet"
        case .ephemeral: return "On"
        @unknown default: return "Unknown"
        }
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Show friend events while the app is open too, instead of silently
        // dropping them.
        return [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        await MainActor.run {
            self.handleRemoteNotification(userInfo)
        }
    }
}
