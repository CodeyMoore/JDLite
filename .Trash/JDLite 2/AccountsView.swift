import SwiftUI

struct AccountsView: View {
    @ObservedObject private var store = AccountStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var editing: Account?

    var body: some View {
        NavigationStack {
            List {
                if store.accounts.isEmpty {
                    Text("No accounts yet. Add one for sites whose plugins need a login.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.accounts) { a in
                    Button { editing = a } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.label.isEmpty ? a.host : a.label)
                            Text(a.username.isEmpty ? a.host : "\(a.username) · \(a.host)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)
                }
                .onDelete { offsets in
                    let ids = offsets.map { store.accounts[$0].id }
                    for id in ids { store.delete(id) }
                }
            }
            .navigationTitle("Accounts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { editing = Account() } label: { Image(systemName: "plus") }
                }
            }
            .sheet(item: $editing) { AccountEditView(account: $0) }
        }
    }
}

struct AccountEditView: View {
    @ObservedObject private var plugins = PluginHost.shared
    @Environment(\.dismiss) private var dismiss
    @State private var account: Account

    init(account: Account) { _account = State(initialValue: account) }

    private var knownHosts: [String] {
        Array(Set(plugins.plugins.filter { $0.accounts }.flatMap { $0.hosts })).sorted()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Site") {
                    TextField("example.com", text: $account.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    if !knownHosts.isEmpty {
                        Menu("Pick from plugins") {
                            ForEach(knownHosts, id: \.self) { h in Button(h) { account.host = h } }
                        }
                    }
                }
                Section("Login") {
                    TextField("Label (optional)", text: $account.label)
                    TextField("Username or email", text: $account.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password or API token", text: $account.password)
                }
                Section {
                    TextField("name=value; name2=value2", text: $account.cookies, axis: .vertical)
                        .lineLimit(2...5)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Cookies (optional)")
                } footer: {
                    Text("For sites that use a session cookie instead of a password. Stored in the Keychain.")
                }
            }
            .navigationTitle(account.host.isEmpty ? "New account" : "Edit account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { AccountStore.shared.save(account); dismiss() }
                        .disabled(account.host.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
