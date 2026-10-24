import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
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
