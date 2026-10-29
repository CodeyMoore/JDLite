import SwiftUI

/// Your Offcloud account: email, password and API key.
struct OffcloudView: View {
    @ObservedObject private var offcloud = Offcloud.shared
    @ObservedObject private var torbox = TorBox.shared
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var keyText = ""
    @State private var working = false
    @State private var message: String?
    @State private var isError = false
    @State private var confirmingRemove = false

    /// Offcloud's account page, where the API key is (it asks you to log in first if needed).
    private static let accountPage = URL(string: "https://offcloud.com/#/account")!

    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedKey: String { keyText.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// A key, an email and password to fetch one, or a changed email or password for the saved key.
    private var canSave: Bool {
        if !trimmedKey.isEmpty { return true }
        if !trimmedEmail.isEmpty && !password.isEmpty { return true }
        return offcloud.hasKey && (trimmedEmail != (offcloud.email ?? "") || !password.isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                if offcloud.hasKey {
                    Section {
                        Text(offcloud.accountSummary ?? "Checking…")
                            .foregroundStyle(.secondary)
                        Toggle("Use Offcloud", isOn: $offcloud.enabled)
                        if let count = offcloud.supportedSiteCount {
                            LabeledContent("Supported sites", value: "\(count)")
                        }
                    } header: {
                        Text("Account")
                    } footer: {
                        Text("Links from sites Offcloud supports, magnet links and .torrent files download through your Offcloud account. If a site sends a web page instead of the file, JDLite also asks Offcloud.")
                    }
                    if torbox.hasKey {
                        Section {
                            Picker("Try First", selection: $settings.preferOffcloud) {
                                Text("TorBox").tag(false)
                                Text("Offcloud").tag(true)
                            }
                        } header: {
                            Text("TorBox and Offcloud")
                        } footer: {
                            Text("When both can get a link or torrent, it goes to this one first. If that one can't get it, the other one has a go.")
                        }
                    }
                }
                Section {
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField(offcloud.hasPassword ? "Password (saved)" : "Password", text: $password)
                        .textContentType(.password)
                    SecureField(offcloud.hasKey ? "New API key (optional)" : "API key", text: $keyText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        Task { await save() }
                    } label: {
                        if working {
                            ProgressView()
                        } else {
                            Text(offcloud.hasKey ? "Update Account" : "Save Account")
                        }
                    }
                    .disabled(working || !canSave)
                    Link(destination: Self.accountPage) {
                        Label("Get API key", systemImage: "key")
                    }
                } header: {
                    Text("Sign In")
                } footer: {
                    Text("Your API key is on offcloud.com under Account (tap Get API key and log in if it asks). JDLite uses the key to talk to Offcloud. Leave it empty and JDLite signs in with your email and password to fetch it, if Offcloud allows that. All three are stored in this device's Keychain.")
                }
                if let message {
                    Section {
                        Text(message).foregroundStyle(isError ? Color.red : Color.secondary)
                    }
                }
                if offcloud.hasKey {
                    Section {
                        Button("Remove Offcloud Account", role: .destructive) { confirmingRemove = true }
                    }
                }
            }
            .navigationTitle("Offcloud")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Remove your Offcloud account from JDLite?", isPresented: $confirmingRemove,
                                titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    offcloud.removeAccount()
                    email = ""
                    password = ""
                    keyText = ""
                    message = nil
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The email, password and API key are deleted from this device. Nothing changes in your Offcloud account.")
            }
            .task {
                email = offcloud.email ?? ""
                if offcloud.hasKey {
                    await offcloud.refreshAccount()
                    await offcloud.refreshSites()
                }
            }
        }
    }

    private func save() async {
        working = true
        defer { working = false }
        do {
            try await offcloud.saveAccount(email: trimmedEmail, password: password, key: trimmedKey)
            password = ""
            keyText = ""
            message = "Account saved."
            isError = false
        } catch {
            message = DownloadManager.offcloudText(error)
            isError = true
        }
    }
}
