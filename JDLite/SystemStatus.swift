import UIKit

/// iOS settings that decide whether downloads can carry on in the background.
@MainActor
final class SystemStatus: ObservableObject {
    static let shared = SystemStatus()

    @Published private(set) var backgroundRefreshOn = true
    @Published private(set) var lowPowerMode = false

    private var observers: [NSObjectProtocol] = []

    init() {
        update()
        let names: [Notification.Name] = [
            UIApplication.backgroundRefreshStatusDidChangeNotification,
            .NSProcessInfoPowerStateDidChange,
            UIApplication.didBecomeActiveNotification
        ]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.update()
                }
            })
        }
    }

    func update() {
        backgroundRefreshOn = UIApplication.shared.backgroundRefreshStatus == .available
        lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    func openAppSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}
