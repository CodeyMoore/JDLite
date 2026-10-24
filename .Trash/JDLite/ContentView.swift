import SwiftUI

struct ContentView: View {
    enum Sheet: Identifiable {
        case add, torbox, plugins
        var id: Self { self }
    }

    @EnvironmentObject var manager: DownloadManager
    @State private var sheet: Sheet?

    var body: some View {
        NavigationStack {
            Group {
                if manager.items.isEmpty {
                    ContentUnavailableView("No downloads",
                                           systemImage: "arrow.down.circle",
                                           description: Text("Tap + to paste links."))
                } else {
                    List {
                        ForEach(manager.items) { item in
                            DownloadRow(item: item)
                        }
                        .onDelete { offsets in
                            let ids = offsets.map { manager.items[$0].id }
                            for id in ids { manager.remove(id) }
                        }
                    }
                }
            }
            .navigationTitle("JDLite")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("TorBox", systemImage: "cloud") { sheet = .torbox }
                        Button("Plugins", systemImage: "puzzlepiece.extension") { sheet = .plugins }
                        Divider()
                        Button("Clear completed", systemImage: "checkmark.circle") { manager.clearCompleted() }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { sheet = .add } label: { Image(systemName: "plus") }
                }
            }
            .sheet(item: $sheet) { s in
                switch s {
                case .add: AddLinksView()
                case .torbox: TorBoxView()
                case .plugins: PluginsView()
                }
            }
            .task { await PluginHost.shared.ensureLoaded() }
        }
    }
}

struct DownloadRow: View {
    @EnvironmentObject var manager: DownloadManager
    let item: DownloadItem

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.fileName).lineLimit(1)
                if item.state == .downloading || item.state == .paused {
                    ProgressView(value: item.progress)
                }
                Text(statusText).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            Spacer()
            if let symbol = actionSymbol {
                Button { act() } label: { Image(systemName: symbol).font(.title3) }
                    .buttonStyle(.borderless)
            }
        }
    }

    private func fmt(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    private var statusText: String {
        let via = item.torboxId != nil ? " · TorBox" : ""
        switch item.state {
        case .queued: return "Queued" + via
        case .resolving: return item.status ?? "Resolving…"
        case .downloading:
            let amount = item.bytesTotal > 0
                ? "\(fmt(item.bytesReceived)) / \(fmt(item.bytesTotal))"
                : fmt(item.bytesReceived)
            return amount + via
        case .paused: return "Paused"
        case .completed: return "Done · \(fmt(item.bytesTotal))"
        case .failed: return item.error ?? "Failed"
        }
    }

    private var actionSymbol: String? {
        switch item.state {
        case .downloading, .resolving: return "pause.circle"
        case .paused: return "play.circle"
        case .failed: return "arrow.clockwise.circle"
        default: return nil
        }
    }

    private func act() {
        switch item.state {
        case .downloading, .resolving: manager.pause(item.id)
        case .paused, .failed: manager.resume(item.id)
        default: break
        }
    }
}

struct AddLinksView: View {
    @EnvironmentObject var manager: DownloadManager
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    private var links: [URL] { DownloadManager.extractLinks(from: text) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $text)
                    .frame(minHeight: 180)
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                Text("\(links.count) link(s) found").font(.footnote).foregroundStyle(.secondary)
                Spacer()
            }
            .padding()
            .navigationTitle("Add links")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Paste") { text = UIPasteboard.general.string ?? text }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { manager.add(urls: links); dismiss() }.disabled(links.isEmpty)
                }
            }
        }
    }
}
