import SwiftUI

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Recreates the background download sessions and keeps the Live Activity in sync,
        // including when iOS launches the app in the background for finished transfers.
        LiveActivityController.shared.start()
        return true
    }

    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        DownloadManager.shared.backgroundCompletionHandlers[identifier] = completionHandler
    }
}

@main
struct JDLiteApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var manager = DownloadManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(manager)
                .onOpenURL { manager.handleOpen($0) }
        }
    }
}
