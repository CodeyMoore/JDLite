import SwiftUI

struct TorBoxView: View {
    @ObservedObject private var torbox = TorBox.shared
    @Environment(\.dismiss) private var dismiss
    @State private var keyText = ""
    @State private var working = false
    @State private var message: String?
    @State private var isError = false

    /// TorBox's settings page, where the API key is (it asks you to log in first if needed).
    private static let apiKeyPage = URL(string: "https://torbox.app/settings")!
    private static let hostersPage = URL(string: "https://torbox.app/hosters")!

    var body: some View {
        NavigationStack {
            Form {
                if torbox.hasKey {
                    Section {
                        Text(torbox.accountSummary ?? "Checking…")
                            .foregroundStyle(.secondary)
                        Toggle("Use TorBox for supported sites", isOn: $torbox.enabled)
                        Link(destination: Self.hostersPage) {
                            HStack {
                                Label("Tap here for supported TorBox hosters", systemImage: "list.bullet.rectangle")
                                Spacer()
                                if let count = torbox.supportedSiteCount {
                                    Text("\(count)")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text("Account")
                    } footer: {
                        Text("Links from supported sites download through your TorBox account. TorBox may ask you to log in to see the list.")
                    }
                }
                Section {
                    Link(destination: Self.apiKeyPage) {
                        Label("Get API key", systemImage: "key")
                    }
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
                    Text("Tap Get API key, log in to TorBox if it asks, then copy the key from its settings page and paste it here. It's stored in this device's Keychain.")
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
