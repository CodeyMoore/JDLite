import Foundation
import Network
import Combine

/// Which network downloads may use.
enum NetworkMode: String, CaseIterable, Identifiable {
    case any, wifiOnly, cellularOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .any: return "Wi-Fi and Mobile Data"
        case .wifiOnly: return "Wi-Fi Only"
        case .cellularOnly: return "Mobile Data Only"
        }
    }
}

/// Watches which network the device is on, for the Wi-Fi / mobile data setting.
@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    @Published private(set) var connected = true
    @Published private(set) var onWiFi = true        // Wi-Fi or a wired connection
    @Published private(set) var onCellular = false
    private let monitor = NWPathMonitor()
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { path in
            let connected = path.status == .satisfied
            let wifi = connected && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
            let cellular = connected && path.usesInterfaceType(.cellular)
            Task { @MainActor in
                NetworkMonitor.shared.update(connected: connected, wifi: wifi, cellular: cellular)
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.codeymoore.jdlite.network"))
    }

    private func update(connected: Bool, wifi: Bool, cellular: Bool) {
        let changed = connected != self.connected || wifi != onWiFi || cellular != onCellular
        self.connected = connected
        onWiFi = wifi
        onCellular = cellular
        if changed { DownloadManager.shared.networkChanged() }
    }

    /// Why downloads have to wait under the current setting, or nil if they can run.
    func waitReason(for mode: NetworkMode) -> String? {
        switch mode {
        case .any:
            return nil
        case .wifiOnly:
            return onWiFi ? nil : "Waiting for Wi-Fi…"
        case .cellularOnly:
            // iOS always prefers Wi-Fi when it's connected, so downloads wait until it isn't.
            return onCellular && !onWiFi ? nil : "Waiting for mobile data…"
        }
    }
}
