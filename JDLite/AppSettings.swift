import Foundation
import Combine

/// User settings, stored in UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    static let maxConnections = 16

    private let defaults = UserDefaults.standard

    /// How many connections each file downloads over at the same time.
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

    /// Keep JDLite running in the background while it downloads, so downloads don't slow down.
    @Published var keepAwakeInBackground: Bool {
        didSet { defaults.set(keepAwakeInBackground, forKey: "keepAwakeInBackground") }
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
        var connections = d.object(forKey: "connectionsPerDownload") as? Int ?? 8
        if !d.bool(forKey: "connectionsUpgraded") {
            // Version 1.5 downloads much faster with more connections: move the old default (4) up.
            if connections == 4 { connections = 8 }
            d.set(connections, forKey: "connectionsPerDownload")
            d.set(true, forKey: "connectionsUpgraded")
        }
        _connectionsPerDownload = Published(wrappedValue: min(max(connections, 1), Self.maxConnections))
        _simultaneousDownloads = Published(wrappedValue: d.object(forKey: "simultaneousDownloads") as? Int ?? 3)
        _keepAwakeInBackground = Published(wrappedValue: d.object(forKey: "keepAwakeInBackground") as? Bool ?? true)
        _notificationsEnabled = Published(wrappedValue: d.object(forKey: "notificationsEnabled") as? Bool ?? true)
        _liveActivityEnabled = Published(wrappedValue: d.object(forKey: "liveActivityEnabled") as? Bool ?? true)
    }
}
