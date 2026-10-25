import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var system = SystemStatus.shared
    @ObservedObject private var location = SaveLocation.shared
    @ObservedObject private var network = NetworkMonitor.shared
    @Environment(\.dismiss) private var dismiss
    @State private var folderError: String?
    @State private var pickingFolder = false
    @State private var pickerRound = 0          // counts each time the folder picker is opened
    @State private var pickerOpenedAt: Date?    // when the picker appeared
    @State private var pickerAnswered = false   // the picker reported a pick or a cancel
    @State private var anchor = ViewAnchor()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $settings.connectionsPerDownload, in: 1...AppSettings.maxConnections) {
                        LabeledContent("Connections per file", value: "\(settings.connectionsPerDownload)")
                    }
                    Stepper(value: $settings.simultaneousDownloads, in: 1...6) {
                        LabeledContent("Downloads at once", value: "\(settings.simultaneousDownloads)")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent("Speed Limit", value: Self.limitText(settings.speedLimit))
                        Slider(value: limitStep, in: 0...Double(AppSettings.speedLimitSteps.count - 1), step: 1) {
                            Text("Speed Limit")
                        } minimumValueLabel: {
                            Text("0.5 MB/s").font(.caption2)
                        } maximumValueLabel: {
                            Text("Unlimited").font(.caption2)
                        }
                    }
                } header: {
                    Text("Speed")
                } footer: {
                    Text("Each file downloads over several connections at once, straight into place. When a connection finishes its share, it takes over half of the slowest one's, so every connection stays busy to the end. Set connections to 1 if a site has problems with it.\n\nThe speed limit (0.5 MB/s up to 2 GB/s, or Unlimited) covers all downloads together. iOS's own background downloader can't be limited, so with Full Speed in Background off, downloads that carry on after you leave JDLite ignore it.")
                }

                Section {
                    Picker("Download Over", selection: $settings.networkMode) {
                        ForEach(NetworkMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    LabeledContent("Connected To", value: connectionName)
                } header: {
                    Text("Network")
                } footer: {
                    Text("With Wi-Fi Only, downloads wait while you're on mobile data and carry on by themselves when you're back on Wi-Fi. iOS always uses Wi-Fi when it's connected, so with Mobile Data Only, downloads wait while you're on Wi-Fi.")
                }

                Section {
                    Button {
                        location.useChosenFolder = false
                    } label: {
                        locationRow("JDLite's Downloads Folder", symbol: "arrow.down.circle", chosen: !location.useChosenFolder)
                    }
                    if let name = location.folderName {
                        Button {
                            location.useChosenFolder = true
                        } label: {
                            locationRow(name, symbol: "folder", chosen: location.useChosenFolder)
                        }
                    }
                    Button(location.folderName == nil ? "Choose a Folder…" : "Choose a Different Folder…") {
                        openFolderPicker()
                    }
                    if let folderError {
                        Text(folderError).foregroundStyle(.red)
                    }
                } header: {
                    Text("Save Files To")
                } footer: {
                    Text("Tap Choose a Folder, go into the folder you want (for example in iCloud Drive or on a USB drive), then tap Open. If that folder isn't available when a download finishes, the file goes to JDLite's Downloads folder (Files › On My iPhone › JDLite) instead.")
                }

                Section {
                    Toggle("Full Speed in Background", isOn: $settings.keepAwakeInBackground)
                    Toggle("Notify When Done", isOn: $settings.notificationsEnabled)
                    LabeledContent("Background App Refresh", value: system.backgroundRefreshOn ? "On" : "Off")
                    if !system.backgroundRefreshOn {
                        Button("Turn It On in Settings") { system.openAppSettings() }
                    }
                } header: {
                    Text("Background")
                } footer: {
                    Text("Full Speed in Background keeps JDLite running while it downloads after you leave it (it plays silence to stay awake, like a music app), so downloads don't slow down. It uses a little more battery and stops by itself when downloads finish. When it's off, iOS's own background downloader takes over, which is often much slower.\n\nYou'll get a notification when a download finishes or fails. Swiping JDLite away in the app switcher stops its downloads until you open it again; they then carry on from where they stopped.")
                }
                Section {
                    Toggle("Live Activity", isOn: $settings.liveActivityEnabled)
                } footer: {
                    Text("Shows download progress on the Lock Screen and in the Dynamic Island.")
                }

                Section {
                    LabeledContent("Version", value: Self.versionText)
                }
            }
            .background(AnchorView(anchor: anchor))
            .sheet(isPresented: $pickingFolder, onDismiss: { folderPickerClosed() }) {
                DocumentPicker(types: [.folder]) { urls in
                    pickerAnswered = true
                    if urls.isEmpty && pickerClosedRightAway {
                        folderError = Self.closedByItself
                    }
                    useFolder(urls.first)
                    closeFolderPicker()
                }
                .ignoresSafeArea()
                .onAppear { pickerOpenedAt = Date() }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private static let closedByItself = "The Files picker closed by itself as it opened, so no folder was chosen. Try again."

    private func openFolderPicker() {
        folderError = nil
        pickerRound += 1
        pickerOpenedAt = nil
        pickerAnswered = false
        pickingFolder = true
        let round = pickerRound
        Task { @MainActor in
            // If the picker hasn't appeared after 2 seconds, show it straight from UIKit instead.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard round == pickerRound, pickingFolder, pickerOpenedAt == nil else { return }
            pickingFolder = false
            try? await Task.sleep(nanoseconds: 500_000_000)   // let SwiftUI give up on its sheet first
            guard round == pickerRound, anchor.view?.window != nil else { return }   // Settings still open
            DirectDocumentPicker.present(types: [.folder], from: anchor.view, onFailure: { onScreen in
                folderError = "The Files picker didn't open. (Showing: \(onScreen))"
            }, onFinish: { urls in
                useFolder(urls.first)
            })
        }
    }

    /// The picker closes its own sheet; this just makes sure SwiftUI knows it's closed.
    private func closeFolderPicker() {
        let round = pickerRound
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            if round == pickerRound && pickingFolder { pickingFolder = false }
        }
    }

    /// The picker's sheet has gone. If that happened the moment it appeared without the picker
    /// reporting anything, the Files picker itself failed.
    private func folderPickerClosed() {
        if !pickerAnswered && pickerClosedRightAway {
            folderError = Self.closedByItself
        }
    }

    private var pickerClosedRightAway: Bool {
        guard let opened = pickerOpenedAt else { return false }
        return Date().timeIntervalSince(opened) < 0.6
    }

    private func useFolder(_ url: URL?) {
        guard let url else { return }   // cancelled: nothing changes
        // The picker also lets .torrent files be picked (JDLite opens them), so check it's a folder.
        let scoped = url.startAccessingSecurityScopedResource()
        let isFolder = url.hasDirectoryPath
            || (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        if scoped { url.stopAccessingSecurityScopedResource() }
        guard isFolder else {
            folderError = "That's a file, not a folder. Go into the folder you want and tap Open."
            return
        }
        do {
            try location.choose(url)
            folderError = nil
        } catch {
            folderError = "Couldn't use that folder: \(error.localizedDescription)"
        }
    }

    private static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private func locationRow(_ title: String, symbol: String, chosen: Bool) -> some View {
        HStack {
            Label(title, systemImage: symbol)
                .foregroundStyle(.primary)
            Spacer()
            if chosen {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
        .contentShape(Rectangle())
    }

    private var connectionName: String {
        guard network.connected else { return "No Connection" }
        if network.onWiFi { return "Wi-Fi" }
        return network.onCellular ? "Mobile Data" : "Other Network"
    }

    /// The slider's position for the current limit (Unlimited is the last stop).
    private var limitStep: Binding<Double> {
        Binding(
            get: {
                let steps = AppSettings.speedLimitSteps
                return Double(steps.firstIndex(of: settings.speedLimit) ?? steps.count - 1)
            },
            set: { position in
                let steps = AppSettings.speedLimitSteps
                settings.speedLimit = steps[min(max(Int(position.rounded()), 0), steps.count - 1)]
            }
        )
    }

    private static func limitText(_ megabytes: Double) -> String {
        if megabytes <= 0 { return "Unlimited" }
        if megabytes >= 1000 { return String(Int(megabytes / 1000)) + " GB/s" }
        return (megabytes < 1 ? String(format: "%.1f", megabytes) : String(Int(megabytes))) + " MB/s"
    }
}
