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

    /// Which network downloads may use.
    @Published var networkMode: NetworkMode {
        didSet {
            defaults.set(networkMode.rawValue, forKey: "networkMode")
            DownloadManager.shared.networkChanged()
        }
    }

    /// Speed limit for all downloads together, in MB/s (0 = no limit).
    @Published var speedLimit: Double {
        didSet {
            defaults.set(speedLimit, forKey: "speedLimit")
            SpeedLimiter.shared.setLimit(bytesPerSecond: speedLimit * 1_000_000)
        }
    }

    /// The speed limit slider's stops, in MB/s, slowest first. 0 (the last stop) means unlimited.
    static let speedLimitSteps: [Double] = [0.5, 1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 0]

    /// Ask which files to download when a torrent has more than one.
    @Published var askTorrentFiles: Bool {
        didSet { defaults.set(askTorrentFiles, forKey: "askTorrentFiles") }
    }

    /// Downloads that fail because the connection dropped try again by themselves.
    @Published var autoRetry: Bool {
        didSet { defaults.set(autoRetry, forKey: "autoRetry") }
    }

    /// Delete downloads from your TorBox account once all their files are downloaded.
    @Published var removeFromTorBox: Bool {
        didSet { defaults.set(removeFromTorBox, forKey: "removeFromTorBox") }
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
        _networkMode = Published(wrappedValue: NetworkMode(rawValue: d.string(forKey: "networkMode") ?? "") ?? .any)
        let limit = d.object(forKey: "speedLimit") as? Double ?? 0
        _speedLimit = Published(wrappedValue: max(limit, 0))
        SpeedLimiter.shared.setLimit(bytesPerSecond: max(limit, 0) * 1_000_000)
        _askTorrentFiles = Published(wrappedValue: d.object(forKey: "askTorrentFiles") as? Bool ?? true)
        _autoRetry = Published(wrappedValue: d.object(forKey: "autoRetry") as? Bool ?? true)
        _removeFromTorBox = Published(wrappedValue: d.object(forKey: "removeFromTorBox") as? Bool ?? false)
        _notificationsEnabled = Published(wrappedValue: d.object(forKey: "notificationsEnabled") as? Bool ?? true)
        _liveActivityEnabled = Published(wrappedValue: d.object(forKey: "liveActivityEnabled") as? Bool ?? true)
    }
}
