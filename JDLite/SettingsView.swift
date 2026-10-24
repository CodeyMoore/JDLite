import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var system = SystemStatus.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $settings.connectionsPerDownload, in: 1...8) {
                        LabeledContent("Connections per file", value: "\(settings.connectionsPerDownload)")
                    }
                    Stepper(value: $settings.simultaneousDownloads, in: 1...6) {
                        LabeledContent("Downloads at once", value: "\(settings.simultaneousDownloads)")
                    }
                } header: {
                    Text("Speed")
                } footer: {
                    Text("Large files are split into parts that download over separate connections at the same time, which is usually much faster, especially from servers far away. Applies to downloads that start after you change it. Set it to 1 if a site has problems with it.")
                }
                Section {
                    Toggle("Notify When Done", isOn: $settings.notificationsEnabled)
                    LabeledContent("Background App Refresh", value: system.backgroundRefreshOn ? "On" : "Off")
                    if !system.backgroundRefreshOn {
                        Button("Turn It On in Settings") { system.openAppSettings() }
                    }
                } header: {
                    Text("Background")
                } footer: {
                    Text("Downloads keep going while JDLite is closed, and files TorBox is still fetching are checked every few minutes. You'll get a notification when a download finishes or fails. Swiping JDLite away in the app switcher stops its downloads until you open it again; they then carry on from where they stopped.")
                }
                Section {
                    Toggle("Live Activity", isOn: $settings.liveActivityEnabled)
                } footer: {
                    Text("Shows download progress on the Lock Screen and in the Dynamic Island.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
