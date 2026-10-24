import SwiftUI

struct PluginsView: View {
    @ObservedObject private var host = PluginHost.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Installed") {
                    if host.plugins.isEmpty { Text("No plugins loaded.").foregroundStyle(.secondary) }
                    ForEach(host.plugins) { p in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.version.isEmpty ? p.name : "\(p.name) \(p.version)")
                            Text(p.hosts.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                            Text(p.file)
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
                if !host.loadErrors.isEmpty {
                    Section("Errors") {
                        ForEach(Array(host.loadErrors.enumerated()), id: \.offset) { _, e in
                            Text(e).font(.caption).foregroundStyle(.red)
                        }
                    }
                }
                Section {
                    if host.logs.isEmpty { Text("Nothing logged yet.").foregroundStyle(.secondary) }
                    ForEach(Array(host.logs.suffix(30).enumerated()), id: \.offset) { _, l in
                        Text(l).font(.caption.monospaced())
                    }
                } header: {
                    Text("Log")
                } footer: {
                    Text("Add .js files in Files › On My iPhone › JDLite › Plugins, then tap Reload. Only install plugins you trust: they can make network requests. Built-in plugins are restored on launch, so copy one under a new name to change it.")
                }
            }
            .navigationTitle("Plugins")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("Reload") { host.reloadTapped() } }
            }
        }
    }
}
