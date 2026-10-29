import SwiftUI

/// What's in your TorBox account: download things again, or remove them from TorBox.
/// Select picks several of them (or all) to download or remove at once. Opened from the
/// TorBox screen.
struct TorBoxCloudView: View {
    @EnvironmentObject var manager: DownloadManager
    @ObservedObject private var torbox = TorBox.shared
    @State private var torrents: [TorBoxCloudItem] = []
    @State private var webDownloads: [TorBoxCloudItem] = []
    @State private var loading = false
    @State private var loaded = false
    @State private var problem: String?
    @State private var note: String?
    @State private var working: String?
    @State private var choosing: TorBoxCloudItem?
    @State private var removing: [TorBoxCloudItem] = []
    @State private var confirmingRemove = false
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<String>()

    private var selecting: Bool { editMode.isEditing }

    /// Everything on the screen, in the order it's shown.
    private var entries: [TorBoxCloudItem] { torrents + webDownloads }

    private var selectedEntries: [TorBoxCloudItem] {
        entries.filter { selection.contains($0.id) }
    }

    /// How many of the selected items TorBox has finished, so they can be downloaded.
    private var selectedReadyCount: Int {
        selectedEntries.filter { $0.ready }.count
    }

    private var allSelected: Bool {
        let ids = Set(entries.map { $0.id })
        return !ids.isEmpty && ids.isSubset(of: selection)
    }

    /// Rows can only be selected in Select mode, so a stray tap can't pre-select one.
    private var selectionBinding: Binding<Set<String>> {
        Binding(get: { selection }, set: { newValue in
            if selecting { selection = newValue }
        })
    }

    var body: some View {
        content
            .environment(\.editMode, $editMode)
            .navigationTitle("TorBox Cloud")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(selecting)
            .toolbar { toolbarContent }
            .navigationDestination(item: $choosing) { entry in
                TorrentFilesView(title: entry.name, files: entry.files) { chosen in
                    add(entry, files: entry.files.filter { chosen.contains($0.id) })
                }
            }
            .confirmationDialog(removeTitle, isPresented: $confirmingRemove, titleVisibility: .visible,
                                presenting: removing) { picked in
                Button("Remove From TorBox", role: .destructive) {
                    finishSelecting()
                    Task { await removeFromTorBox(picked) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { picked in
                Text(removeMessage(picked))
            }
            .task { await load() }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if selecting {
            ToolbarItem(placement: .topBarLeading) {
                Button(allSelected ? "Deselect All" : "Select All") {
                    selection = allSelected ? [] : Set(entries.map { $0.id })
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { finishSelecting() }
                    .fontWeight(.semibold)
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button(role: .destructive) {
                    askToRemove(selectedEntries)
                } label: {
                    Label(selectedEntries.isEmpty ? "Remove" : "Remove (\(selectedEntries.count))",
                          systemImage: "trash")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(selectedEntries.isEmpty)
                Spacer()
                Button {
                    downloadSelected()
                } label: {
                    Label(selectedReadyCount == 0 ? "Download" : "Download (\(selectedReadyCount))",
                          systemImage: "arrow.down.circle")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(selectedReadyCount == 0)
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Select") { editMode = .active }
                    .disabled(!loaded || entries.isEmpty || working != nil)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !torbox.hasKey {
            ContentUnavailableView("No TorBox account", systemImage: "key",
                                   description: Text("Add your TorBox API key on the TorBox screen first."))
        } else if !loaded {
            ProgressView("Loading your TorBox…")
        } else if entries.isEmpty {
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
        List(selection: selectionBinding) {
            if !selecting {
                if let working {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(working)
                        }
                    }
                }
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
            if !selecting {
                Section {
                    EmptyView()
                } footer: {
                    Text("Tap the arrow to download something again, or tap Select to download or remove several at once. Swipe left to remove one from TorBox. To have TorBox cleared out by itself, turn on Remove From TorBox When Done on the TorBox screen.")
                }
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
            if entry.ready && !selecting {
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
        .tag(entry.id)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if working == nil {
                Button {
                    askToRemove([entry])
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .tint(.red)
            }
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

    private func finishSelecting() {
        editMode = .inactive
        selection = []
    }

    // MARK: Downloading

    /// A torrent with several files asks which ones first.
    private func download(_ entry: TorBoxCloudItem) {
        if entry.files.count > 1 {
            choosing = entry
        } else {
            add(entry, files: entry.files)
        }
    }

    private func add(_ entry: TorBoxCloudItem, files: [TorBoxFile]) {
        note = addedText(manager.addFromTorBox(entry, files: files))
    }

    /// Downloads every file of each selected item that TorBox has finished. The rest are skipped.
    private func downloadSelected() {
        let picked = selectedEntries
        let ready = picked.filter { $0.ready }
        guard !ready.isEmpty else { return }
        var added = 0
        for entry in ready {
            added += manager.addFromTorBox(entry, files: entry.files)
        }
        finishSelecting()
        var text = addedText(added)
        let skipped = picked.count - ready.count
        if skipped == 1 {
            text += " 1 item wasn't ready on TorBox yet, so it was skipped."
        } else if skipped > 1 {
            text += " \(skipped) items weren't ready on TorBox yet, so they were skipped."
        }
        note = text
    }

    private func addedText(_ count: Int) -> String {
        switch count {
        case 0: return "Those files are already in your downloads."
        case 1: return "Added 1 file to your downloads."
        default: return "Added \(count) files to your downloads."
        }
    }

    // MARK: Removing

    private func askToRemove(_ picked: [TorBoxCloudItem]) {
        guard !picked.isEmpty else { return }
        removing = picked
        confirmingRemove = true
    }

    private var removeTitle: String {
        if removing.count == 1, let only = removing.first {
            return "Remove “\(only.name)” from TorBox?"
        }
        return "Remove \(removing.count) items from TorBox?"
    }

    /// Also warns about anything that hasn't finished downloading here yet.
    private func removeMessage(_ picked: [TorBoxCloudItem]) -> String {
        let one = picked.count == 1
        var text = one
            ? "It's deleted from your TorBox account. Files you've already downloaded stay on this device."
            : "They're deleted from your TorBox account. Files you've already downloaded stay on this device."
        let unfinished = picked.filter { unfinishedHere($0) }.count
        if one && unfinished == 1 {
            text += " It hasn't finished downloading here yet, and may not be able to once it's gone from TorBox."
        } else if unfinished == 1 {
            text += " 1 of them hasn't finished downloading here yet, and may not be able to once it's gone from TorBox."
        } else if unfinished > 1 {
            text += " \(unfinished) of them haven't finished downloading here yet, and may not be able to once they're gone from TorBox."
        }
        return text
    }

    /// True when the downloads list has files from this item that aren't finished.
    private func unfinishedHere(_ entry: TorBoxCloudItem) -> Bool {
        manager.items.contains {
            $0.torboxId == entry.torboxID && ($0.torboxKind ?? .web) == entry.kind && $0.state != .completed
        }
    }

    /// Removes them one at a time, a moment apart, since TorBox limits how fast its API can be used.
    private func removeFromTorBox(_ picked: [TorBoxCloudItem]) async {
        guard !picked.isEmpty, working == nil else { return }
        var removed = 0
        var failures: [String] = []
        for (index, entry) in picked.enumerated() {
            working = picked.count == 1
                ? "Removing from TorBox…"
                : "Removing \(index + 1) of \(picked.count) from TorBox…"
            if index > 0 { try? await Task.sleep(nanoseconds: 250_000_000) }
            do {
                try await removeOne(entry)
                torrents.removeAll { $0.id == entry.id }
                webDownloads.removeAll { $0.id == entry.id }
                removed += 1
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        working = nil
        if !failures.isEmpty { await load() }   // show what's really still on TorBox

        if removed == 0 {
            note = nil
        } else if picked.count == 1 {
            note = "Removed “\(picked[0].name)” from TorBox."
        } else {
            note = removed == 1 ? "Removed 1 item from TorBox." : "Removed \(removed) items from TorBox."
        }
        if let first = failures.first {
            let what = picked.count == 1 ? "it" : (failures.count == 1 ? "1 item" : "\(failures.count) items")
            problem = "Couldn't remove \(what): " + first
        } else {
            problem = nil
        }
    }

    /// Tries once more after a pause, in case TorBox was busy.
    private func removeOne(_ entry: TorBoxCloudItem) async throws {
        do {
            try await torbox.remove(entry.kind, id: entry.torboxID)
        } catch {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            try await torbox.remove(entry.kind, id: entry.torboxID)
        }
    }

    private func load() async {
        guard torbox.hasKey, !loading, working == nil else { return }
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

        // Forget selected items that aren't on TorBox any more.
        let ids = Set(entries.map { $0.id })
        selection = selection.intersection(ids)
        if ids.isEmpty { finishSelecting() }
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
