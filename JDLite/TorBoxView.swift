import SwiftUI

struct TorBoxView: View {
    @ObservedObject private var torbox = TorBox.shared
    @Environment(\.dismiss) private var dismiss
    @State private var keyText = ""
    @State private var working = false
    @State private var message: String?
    @State private var isError = false

    /// TorBox's settings page: it asks you to log in first, then shows your API key.
    private static let loginPage = URL(string: "https://torbox.app/settings")!
    private static let hostersPage = URL(string: "https://torbox.app/hosters")!

    var body: some View {
        NavigationStack {
            Form {
                if torbox.hasKey {
                    Section("Account") {
                        Text(torbox.accountSummary ?? "Checking…")
                            .foregroundStyle(.secondary)
                        Toggle("Use TorBox for supported sites", isOn: $torbox.enabled)
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
                    Link(destination: Self.loginPage) {
                        Label("Log in to TorBox", systemImage: "person.crop.circle")
                    }
                } header: {
                    Text("API key")
                } footer: {
                    Text("Log in to TorBox, copy the API key from its settings page and paste it here. It's stored in this device's Keychain.")
                }
                Section {
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
                } footer: {
                    Text("Links from these sites download through your TorBox account. TorBox may ask you to log in to see the list.")
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
