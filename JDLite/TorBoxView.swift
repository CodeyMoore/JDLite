import SwiftUI

struct TorBoxView: View {
    @ObservedObject private var torbox = TorBox.shared
    @Environment(\.dismiss) private var dismiss
    @State private var keyText = ""
    @State private var working = false
    @State private var message: String?
    @State private var isError = false

    var body: some View {
        NavigationStack {
            Form {
                if torbox.hasKey {
                    Section("Account") {
                        Text(torbox.accountSummary ?? "Checking…")
                            .foregroundStyle(.secondary)
                        Toggle("Use TorBox for supported sites", isOn: $torbox.enabled)
                        LabeledContent("Supported sites",
                                       value: torbox.supportedSiteCount.map { "\($0)" } ?? "–")
                    }
                }
                Section {
                    SecureField(torbox.hasKey ? "New API key" : "API key", text: $keyText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        Task { await save() }
                    } label: {
                        if working {
                            ProgressView()
                        } else {
                            Text(torbox.hasKey ? "Replace key" : "Save key")
                        }
                    }
                    .disabled(working || keyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: {
                    Text("API key")
                } footer: {
                    Text("Copy it from your TorBox settings page. It's stored in this device's Keychain. Links from sites TorBox supports are downloaded through your TorBox account.")
                }
                if let message {
                    Section {
                        Text(message).foregroundStyle(isError ? Color.red : Color.secondary)
                    }
                }
                if torbox.hasKey {
                    Section {
                        Button("Remove API key", role: .destructive) {
                            torbox.removeKey()
                            message = nil
                        }
                    }
                }
            }
            .navigationTitle("TorBox")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task {
                if torbox.hasKey {
                    await torbox.refreshAccount()
                    await torbox.refreshHosters()
                }
            }
        }
    }

    private func save() async {
        working = true
        defer { working = false }
        do {
            try await torbox.saveKey(keyText)
            keyText = ""
            message = "Key saved."
            isError = false
        } catch {
            message = error.localizedDescription
            isError = true
        }
    }
}
