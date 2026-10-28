import SwiftUI

/// What's in your TorBox account: download things again, or remove them from TorBox.
struct TorBoxCloudView: View {
    @EnvironmentObject var manager: DownloadManager
    @ObservedObject private var torbox = TorBox.shared
    @Environment(\.dismiss) private var dismiss
    @State private var torrents: [TorBoxCloudItem] = []
    @State private var webDownloads: [TorBoxCloudItem] = []
    @State private var loading = false
    @State private var loaded = false
    @State private var problem: String?
    @State private var note: String?
    @State private var choosing: TorBoxCloudItem?
    @State private var removing: TorBoxCloudItem?
    @State private var confirmingRemove = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("TorBox Cloud")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
                .navigationDestination(item: $choosing) { entry in
                    TorrentFilesView(title: entry.name, files: entry.files) { chosen in
                        add(entry, files: entry.files.filter { chosen.contains($0.id) })
                    }
                }
                .confirmationDialog(removeTitle, isPresented: $confirmingRemove, titleVisibility: .visible,
                                    presenting: removing) { entry in
                    Button("Remove From TorBox", role: .destructive) {
                        Task { await remove(entry) }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: { _ in
                    Text("It's deleted from your TorBox account. Files you've already downloaded stay on this device.")
                }
        }
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if !torbox.hasKey {
            ContentUnavailableView("No TorBox account", systemImage: "key",
                                   description: Text("Add your TorBox API key in ⋯ › TorBox first."))
        } else if !loaded {
            ProgressView("Loading your TorBox…")
        } else if torrents.isEmpty && webDownloads.isEmpty {
            if let problem {
                ContentUnavailableView {
                    Label("Couldn't load TorBox", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(problem)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                }
            } else {
                ContentUnavailableView("Nothing on TorBox", systemImage: "icloud",
                                       description: Text("Torrents and links you send to TorBox show up here."))
            }
        } else {
            list
        }
    }

    private var list: some View {
        List {
            if let note {
                Section {
                    Label(note, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            if let problem {
                Section {
                    Text(problem).foregroundStyle(.red)
                }
            }
            if !torrents.isEmpty {
                Section("Torrents") {
                    ForEach(torrents) { entry in row(entry) }
                }
            }
            if !webDownloads.isEmpty {
                Section("Downloads") {
                    ForEach(webDownloads) { entry in row(entry) }
                }
            }
            Section {
                EmptyView()
            } footer: {
                Text("Tap the arrow to download something again. Swipe left to remove it from TorBox. To have TorBox cleared out by itself, turn on Remove From TorBox When Done in ⋯ › TorBox.")
            }
        }
        .refreshable { await load() }
    }

    private func row(_ entry: TorBoxCloudItem) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(detail(entry))
                    .font(.caption)
                    .foregroundStyle(entry.failure != nil ? Color.red : Color.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if entry.ready {
                Button {
                    download(entry)
                } label: {
                    Image(systemName: "arrow.down.circle").font(.title2)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Download")
            }
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                removing = entry
                confirmingRemove = true
            } label: {
                Label("Remove", systemImage: "trash")
            }
            .tint(.red)
        }
    }

    private func detail(_ entry: TorBoxCloudItem) -> String {
        if let failure = entry.failure { return "Failed: " + failure }
        var parts: [String] = [entry.ready ? "Ready" : entry.statusText]
        if entry.files.count > 1 { parts.append("\(entry.files.count) files") }
        if let size = entry.size, size > 0 { parts.append(Fmt.bytes(size)) }
        if let added = entry.addedAt { parts.append(added.formatted(date: .abbreviated, time: .omitted)) }
        return parts.joined(separator: " · ")
    }

    private var removeTitle: String {
        "Remove “\(removing?.name ?? "this")” from TorBox?"
    }

    /// A torrent with several files asks which ones first.
    private func download(_ entry: TorBoxCloudItem) {
        if entry.files.count > 1 {
            choosing = entry
        } else {
            add(entry, files: entry.files)
        }
    }

    private func add(_ entry: TorBoxCloudItem, files: [TorBoxFile]) {
        let count = manager.addFromTorBox(entry, files: files)
        switch count {
        case 0: note = "Those files are already in your downloads."
        case 1: note = "Added 1 file to your downloads."
        default: note = "Added \(count) files to your downloads."
        }
    }

    private func load() async {
        guard torbox.hasKey, !loading else { return }
        loading = true
        var problems: [String] = []
        do {
            torrents = try await torbox.cloud(.torrent)
        } catch {
            problems.append(error.localizedDescription)
        }
        do {
            webDownloads = try await torbox.cloud(.web)
        } catch {
            problems.append(error.localizedDescription)
        }
        problem = problems.first.map { "Couldn't load everything from TorBox: " + $0 }
        loading = false
        loaded = true
    }

    private func remove(_ entry: TorBoxCloudItem) async {
        do {
            try await torbox.remove(entry.kind, id: entry.torboxID)
            torrents.removeAll { $0.id == entry.id }
            webDownloads.removeAll { $0.id == entry.id }
            note = "Removed “\(entry.name)” from TorBox."
            problem = nil
        } catch {
            problem = "Couldn't remove it: " + error.localizedDescription
        }
    }
}

/// Pick which of a torrent's files to download. Everything is ticked to start with.
struct TorrentFilesView: View {
    @Environment(\.dismiss) private var dismiss
    private let title: String
    private let files: [TorBoxFile]
    private let showsCancel: Bool
    private let onDownload: (Set<Int>) -> Void
    @State private var chosen: Set<Int>

    init(title: String, files: [TorBoxFile], showsCancel: Bool = false,
         onDownload: @escaping (Set<Int>) -> Void) {
        self.title = title
        self.files = files.sorted {
            ($0.path ?? $0.name).localizedStandardCompare($1.path ?? $1.name) == .orderedAscending
        }
        self.showsCancel = showsCancel
        self.onDownload = onDownload
        _chosen = State(initialValue: Set(files.map { $0.id }))
    }

    private var allChosen: Bool { chosen.count == files.count }

    private var chosenSize: Int64 {
        files.reduce(Int64(0)) { $0 + (chosen.contains($1.id) ? max($1.size ?? 0, 0) : 0) }
    }

    var body: some View {
        List {
            Section {
                ForEach(files, id: \.id) { file in
                    Button {
                        toggle(file.id)
                    } label: {
                        fileRow(file)
                    }
                }
            } header: {
                HStack {
                    Text("\(chosen.count) of \(files.count) files · \(Fmt.bytes(chosenSize))")
                    Spacer()
                    Button(allChosen ? "Select None" : "Select All") {
                        chosen = allChosen ? [] : Set(files.map { $0.id })
                    }
                    .font(.footnote.weight(.semibold))
                }
                .textCase(nil)
            } footer: {
                Text("The files go into a folder named after the torrent in JDLite's Downloads folder, laid out as in the torrent.")
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsCancel {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { downloadButton }
            } else {
                ToolbarItem(placement: .confirmationAction) { downloadButton }
            }
        }
    }

    private var downloadButton: some View {
        Button("Download") {
            let picked = chosen
            dismiss()
            onDownload(picked)
        }
        .disabled(chosen.isEmpty)
    }

    private func fileRow(_ file: TorBoxFile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: chosen.contains(file.id) ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(chosen.contains(file.id) ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let folder = subfolder(of: file) {
                    Label(folder, systemImage: "folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let size = file.size, size > 0 {
                Text(Fmt.bytes(size))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    private func toggle(_ id: Int) {
        if chosen.contains(id) {
            chosen.remove(id)
        } else {
            chosen.insert(id)
        }
    }

    /// The folders the file is in inside the torrent, if it isn't at the top.
    private func subfolder(of file: TorBoxFile) -> String? {
        let root = DownloadManager.safeComponent(title) ?? "Torrent"
        let full = DownloadManager.torrentFolder(torrent: title, file: file.path ?? file.name)
        guard full.hasPrefix(root + "/") else { return nil }
        return String(full.dropFirst(root.count + 1))
    }
}
