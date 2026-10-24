import Foundation
import Combine

/// User settings, stored in UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    /// How many connections a large file is split across.
    @Published var connectionsPerDownload: Int {
        didSet { defaults.set(connectionsPerDownload, forKey: "connectionsPerDownload") }
    }

    /// How many files download at the same time.
    @Published var simultaneousDownloads: Int {
        didSet {
            defaults.set(simultaneousDownloads, forKey: "simultaneousDownloads")
            DownloadManager.shared.settingsChanged()
        }
    }

    /// Notify when downloads finish or fail while the app isn't open.
    @Published var notificationsEnabled: Bool {
        didSet {
            defaults.set(notificationsEnabled, forKey: "notificationsEnabled")
            if notificationsEnabled { Notifier.shared.askPermissionIfNeeded() }
        }
    }

    @Published var liveActivityEnabled: Bool {
        didSet {
            defaults.set(liveActivityEnabled, forKey: "liveActivityEnabled")
            Task { await LiveActivityController.shared.refresh(force: true) }
        }
    }

    init() {
        let d = UserDefaults.standard
        _connectionsPerDownload = Published(wrappedValue: d.object(forKey: "connectionsPerDownload") as? Int ?? 4)
        _simultaneousDownloads = Published(wrappedValue: d.object(forKey: "simultaneousDownloads") as? Int ?? 3)
        _notificationsEnabled = Published(wrappedValue: d.object(forKey: "notificationsEnabled") as? Bool ?? true)
        _liveActivityEnabled = Published(wrappedValue: d.object(forKey: "liveActivityEnabled") as? Bool ?? true)
    }
}
