import SwiftUI

#if canImport(FirebaseCore)
import FirebaseCore
#endif

@MainActor
class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UIScrollView.appearance().bounces = false
        #if canImport(FirebaseCore)
        if FirebaseApp.app() == nil { FirebaseApp.configure() }
        #endif

        NotificationManager.shared.configure()

        // A notification tap can launch a terminated app before SwiftUI has
        // built the feed. Store the event ID now; ContentView consumes it once
        // the session and event list are ready.
        if let remote = launchOptions?[.remoteNotification] as? [AnyHashable: Any] {
            NotificationManager.shared.handleRemoteNotification(remote)
        }

        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        NotificationManager.shared.didRegister(deviceToken: deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        NotificationManager.shared.didFailToRegister(error: error)
    }
}

@main
struct BulletinApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
