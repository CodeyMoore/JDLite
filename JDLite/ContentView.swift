import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    enum Sheet: Identifiable, Hashable {
        case add, torbox, cloud, plugins, settings
        case chooseFiles(UUID)
        var id: Self { self }
    }

    @EnvironmentObject var manager: DownloadManager
    @ObservedObject private var system = SystemStatus.shared
    @State private var sheet: Sheet?
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<UUID>()
    @State private var pendingDelete = Set<UUID>()
    @State private var confirmingDelete = false
    @State private var expandedGroups = Set<UUID>()
    @State private var searchText = ""
    @State private var repeatLinks: [URL] = []
    @State private var askingAboutRepeats = false
    @AppStorage("sortOrder") private var sortOrder: SortOrder = .oldest
    @AppStorage("statusFilter") private var statusFilter: StatusFilter = .all
    @AppStorage("typeFilter") private var typeFilter: String = "all"

    private var isEditing: Bool { editMode.isEditing }
    private var isFiltering: Bool { statusFilter != .all || typeFilter != "all" }
    private var query: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The downloads after the filter and search, sorted by when each was added.
    private var visibleItems: [DownloadItem] {
        let filtered = manager.items.enumerated().filter { pair in
            statusFilter.matches(pair.element)
                && (typeFilter == "all" || FileKind.of(pair.element.fileName).rawValue == typeFilter)
                && matchesSearch(pair.element)
        }
        let newestFirst = sortOrder == .newest
        return filtered.sorted { a, b in
            let da = a.element.addedAt ?? .distantPast
            let db = b.element.addedAt ?? .distantPast
            if da != db { return newestFirst ? da > db : da < db }
            return newestFirst ? a.offset > b.offset : a.offset < b.offset
        }
        .map { $0.element }
    }

    private func matchesSearch(_ item: DownloadItem) -> Bool {
        let text = query
        guard !text.isEmpty else { return true }
        if item.fileName.localizedCaseInsensitiveContains(text) { return true }
        if let group = item.groupName, group.localizedCaseInsensitiveContains(text) { return true }
        if let host = (item.sourceURL ?? item.url).host, host.localizedCaseInsensitiveContains(text) { return true }
        return false
    }

    /// The list's rows: downloads, with a torrent's files shown as one group row (followed by
    /// its files while the group is open).
    private func listRows(_ visible: [DownloadItem]) -> [ListRow] {
        var members: [UUID: [DownloadItem]] = [:]
        for item in manager.items {
            if let group = item.groupID { members[group, default: []].append(item) }
        }
        var shown: [UUID: [DownloadItem]] = [:]
        for item in visible {
            if let group = item.groupID { shown[group, default: []].append(item) }
        }
        var rows: [ListRow] = []
        var placed = Set<UUID>()
        for item in visible {
            guard let group = item.groupID, let all = members[group], all.count > 1 else {
                rows.append(.item(item, false))
                continue
            }
            guard placed.insert(group).inserted else { continue }
            let files = (shown[group] ?? []).sorted {
                $0.sortPath.localizedStandardCompare($1.sortPath) == .orderedAscending
            }
            rows.append(.group(TorrentGroup(id: group, name: item.groupName ?? item.fileName,
                                            members: all, shown: files)))
            if expandedGroups.contains(group) && !isEditing {
                for file in files { rows.append(.item(file, true)) }
            }
        }
        return rows
    }

    private var allSelected: Bool {
        let ids = Set(listRows(visibleItems).map { $0.id })
        return !ids.isEmpty && ids.isSubset(of: selection)
    }

    var body: some View {
        NavigationStack {
            Group {
                if manager.items.isEmpty {
                    ContentUnavailableView("No downloads",
                                           systemImage: "arrow.down.circle",
                                           description: Text("Tap + to paste links, or send them from Safari."))
                } else {
                    let visible = visibleItems
                    let rows = listRows(visible)
                    List(selection: $selection) {
                        if !isEditing && !system.backgroundRefreshOn {
                            BackgroundWarning(lowPower: system.lowPowerMode) { system.openAppSettings() }
                        }
                        if !isEditing && isFiltering && !visible.isEmpty {
                            FilterSummary(text: filterSummary, count: visible.count) { clearFilters() }
                        }
                        ForEach(rows) { row in
                            rowView(row)
                        }
                    }
                    .listStyle(.plain)
                    .overlay {
                        if visible.isEmpty {
                            if !query.isEmpty {
                                ContentUnavailableView.search(text: query)
                            } else {
                                ContentUnavailableView {
                                    Label("No matching downloads", systemImage: "line.3.horizontal.decrease.circle")
                                } description: {
                                    Text("Nothing matches the filter you picked.")
                                } actions: {
                                    Button("Show Everything") { clearFilters() }
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search downloads")
            .environment(\.editMode, $editMode)
            .navigationTitle("JDLite")
            .toolbar { toolbarContent }
            .confirmationDialog(deleteTitle, isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    let ids = pendingDelete
                    manager.delete(ids)
                    selection = selection.filter { id in
                        manager.items.contains { $0.id == id || $0.groupID == id }
                    }
                    pendingDelete = []
                    if manager.items.isEmpty { editMode = .inactive }
                }
                Button("Cancel", role: .cancel) { pendingDelete = [] }
            } message: {
                Text(deleteMessage)
            }
            .sheet(item: $sheet) { s in
                switch s {
                case .add: AddLinksView()
                case .torbox: TorBoxView()
                case .cloud: TorBoxCloudView()
                case .plugins: PluginsView()
                case .settings: SettingsView()
                case .chooseFiles(let id):
                    ChooseFilesSheet(itemID: id, item: manager.items.first(where: { $0.id == id }))
                }
            }
            .task { await PluginHost.shared.ensureLoaded() }
        }
        .onChange(of: manager.repeatedLinks, initial: true) { _, links in
            // Links from Safari or the share sheet that were already in the list.
            guard !links.isEmpty else { return }
            repeatLinks = links
            askingAboutRepeats = true
            manager.clearRepeatedLinks()
        }
        .confirmationDialog(repeatTitle, isPresented: $askingAboutRepeats, titleVisibility: .visible,
                            presenting: repeatLinks) { links in
            Button(links.count == 1 ? "Add It Again" : "Add Them Again") {
                manager.add(urls: links, allowDuplicates: true)
            }
            Button("Skip", role: .cancel) {}
        } message: { links in
            Text(links.count == 1
                 ? "That link is already in your list."
                 : "These links are already in your list.")
        }
    }

    /// One row of the list: a download, or a torrent's group row.
    @ViewBuilder
    private func rowView(_ row: ListRow) -> some View {
        switch row {
        case .item(let item, let inGroup):
            DownloadRow(item: item, speed: manager.speeds[item.id], inGroup: inGroup) {
                sheet = .chooseFiles(item.id)
            }
            .tag(item.id)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button {
                    askToDelete([item.id])
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(.red)
            }
        case .group(let group):
            GroupRow(group: group, speeds: manager.speeds, expanded: expandedGroups.contains(group.id)) {
                toggleGroup(group.id)
            }
            .tag(group.id)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button {
                    askToDelete([group.id])
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(.red)
            }
            .contextMenu { groupMenu(group) }
        }
    }

    private var repeatTitle: String {
        repeatLinks.count == 1 ? "Already in your list" : "\(repeatLinks.count) links are already in your list"
    }

    private func toggleGroup(_ id: UUID) {
        withAnimation(.snappy) {
            if expandedGroups.contains(id) {
                expandedGroups.remove(id)
            } else {
                expandedGroups.insert(id)
            }
        }
    }

    @ViewBuilder
    private func groupMenu(_ group: TorrentGroup) -> some View {
        let ids = Set(group.members.map { $0.id })
        if group.members.contains(where: { $0.state == .completed }), let folder = group.folderURL {
            Button("Show in Files", systemImage: "folder") { FilesApp.open(folder) }
        }
        if group.members.contains(where: { $0.state == .queued || $0.state == .resolving || $0.state == .downloading }) {
            Button("Pause", systemImage: "pause.circle") { manager.pauseAll(ids) }
        }
        if group.members.contains(where: { $0.state == .paused }) {
            Button("Resume", systemImage: "play.circle") { manager.resumeAll(ids) }
        }
        if group.members.contains(where: { $0.state == .failed }) {
            Button("Retry Failed Files", systemImage: "arrow.clockwise") { manager.retryFailed(ids) }
        }
        Button("Delete…", systemImage: "trash", role: .destructive) { askToDelete([group.id]) }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isEditing {
            ToolbarItem(placement: .topBarLeading) {
                Button(allSelected ? "Deselect All" : "Select All") {
                    selection = allSelected ? [] : Set(listRows(visibleItems).map { $0.id })
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    editMode = .inactive
                    selection = []
                }
                .fontWeight(.semibold)
            }
            ToolbarItem(placement: .bottomBar) {
                Button(role: .destructive) {
                    askToDelete(selection)
                } label: {
                    Label(selection.isEmpty ? "Delete" : "Delete (\(selection.count))", systemImage: "trash")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(selection.isEmpty)
            }
        } else {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button("TorBox", systemImage: "cloud") { sheet = .torbox }
                    Button("TorBox Cloud", systemImage: "icloud.and.arrow.down") { sheet = .cloud }
                    Button("Plugins", systemImage: "puzzlepiece.extension") { sheet = .plugins }
                    Button("Settings", systemImage: "gearshape") { sheet = .settings }
                    Divider()
                    Button("Pause All", systemImage: "pause.circle") { manager.pauseAll() }
                        .disabled(!manager.canPauseAll)
                    Button("Resume All", systemImage: "play.circle") { manager.resumeAll() }
                        .disabled(!manager.canResumeAll)
                    if manager.hasFailed {
                        Button("Retry Failed", systemImage: "arrow.clockwise.circle") { manager.retryFailed() }
                    }
                    Divider()
                    Button("Select Downloads", systemImage: "checkmark.circle") { editMode = .active }
                        .disabled(manager.items.isEmpty)
                    Button("Clear Finished (Keep Files)", systemImage: "checklist") { manager.clearCompleted() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                filterMenu
                Button { sheet = .add } label: { Image(systemName: "plus") }
            }
        }
    }

    // MARK: Filter menu

    private var filterMenu: some View {
        Menu {
            Section("Sort") {
                Picker("Sort", selection: $sortOrder) {
                    Label("Newest First", systemImage: "arrow.down").tag(SortOrder.newest)
                    Label("Oldest First", systemImage: "arrow.up").tag(SortOrder.oldest)
                }
                .pickerStyle(.inline)
            }
            Section("Show") {
                Picker("Show", selection: $statusFilter) {
                    ForEach(StatusFilter.allCases, id: \.self) { filter in
                        Label("\(filter.title) (\(count(filter)))", systemImage: filter.symbol).tag(filter)
                    }
                }
                .pickerStyle(.inline)
            }
            Section("File Type") {
                Picker(selection: $typeFilter) {
                    Label("All Types", systemImage: "square.grid.2x2").tag("all")
                    ForEach(kindsInList) { kind in
                        Label("\(kind.title) (\(count(kind)))", systemImage: kind.symbol).tag(kind.rawValue)
                    }
                } label: {
                    Label(FileKind(rawValue: typeFilter)?.title ?? "File Type", systemImage: "doc.on.doc")
                }
                .pickerStyle(.menu)
            }
            if isFiltering {
                Button("Show Everything", systemImage: "xmark.circle") { clearFilters() }
            }
        } label: {
            Image(systemName: isFiltering ? "line.3.horizontal.decrease.circle.fill"
                                          : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel("Sort and filter")
    }

    /// File types present in the list (plus the chosen one, so its checkmark shows).
    private var kindsInList: [FileKind] {
        let present = Set(manager.items.map { FileKind.of($0.fileName) })
        return FileKind.allCases.filter { present.contains($0) || $0.rawValue == typeFilter }
    }

    private func count(_ filter: StatusFilter) -> Int {
        manager.items.filter { filter.matches($0) }.count
    }

    private func count(_ kind: FileKind) -> Int {
        manager.items.filter { FileKind.of($0.fileName) == kind }.count
    }

    private var filterSummary: String {
        var parts: [String] = []
        if statusFilter != .all { parts.append(statusFilter.title) }
        if let kind = FileKind(rawValue: typeFilter) { parts.append(kind.title) }
        return parts.joined(separator: " · ")
    }

    private func clearFilters() {
        statusFilter = .all
        typeFilter = "all"
    }

    // MARK: Deleting

    /// Asks before deleting. A group row stands for all of its torrent's files.
    private func askToDelete(_ ids: Set<UUID>) {
        let files = Set(manager.items.filter { item in
            ids.contains(item.id) || (item.groupID.map { ids.contains($0) } ?? false)
        }.map { $0.id })
        guard !files.isEmpty else { return }
        pendingDelete = files
        confirmingDelete = true
    }

    private var pendingItems: [DownloadItem] { manager.items.filter { pendingDelete.contains($0.id) } }

    private var deleteTitle: String {
        let items = pendingItems
        if items.count == 1 { return "Delete “\(items[0].fileName)”?" }
        if let group = items.first?.groupID, items.allSatisfy({ $0.groupID == group }),
           items.count == manager.items.filter({ $0.groupID == group }).count {
            return "Delete “\(items[0].groupName ?? items[0].fileName)”?"   // a whole torrent
        }
        return "Delete \(items.count) downloads?"
    }

    private var deleteMessage: String {
        let items = pendingItems
        let finished = items.filter { $0.state == .completed }.count
        if items.count == 1 {
            return finished == 1
                ? "The file will be deleted from this device."
                : "The download will stop and anything downloaded so far will be deleted."
        }
        if finished == items.count { return "Their files will be deleted from this device." }
        if finished == 0 { return "These downloads will stop and anything downloaded so far will be deleted." }
        return "Finished files will be deleted from this device, and unfinished downloads will stop."
    }
}

/// Shown when iOS won't let downloads carry on in the background.
private struct BackgroundWarning: View {
    let lowPower: Bool
    let openSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("Background App Refresh is off")
                    .font(.subheadline.weight(.semibold))
                Text(lowPower
                     ? "Low Power Mode turns it off, so downloads may stop when you leave JDLite."
                     : "Downloads may stop when you leave JDLite. Turn on Background App Refresh to keep them going.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !lowPower {
                    Button("Open Settings", action: openSettings)
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.borderless)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

/// A reminder that the list is filtered, with a quick way back.
private struct FilterSummary: View {
    let text: String
    let count: Int
    let clear: () -> Void

    var body: some View {
        HStack {
            Label("\(text) · \(count)", systemImage: "line.3.horizontal.decrease")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Clear", action: clear)
                .font(.footnote.weight(.semibold))
                .buttonStyle(.borderless)
        }
    }
}

// MARK: - Torrent groups

/// A row of the list: a download, or a torrent whose files show as one group.
enum ListRow: Identifiable {
    case item(DownloadItem, Bool)    // a download, and whether it's shown inside its torrent's group
    case group(TorrentGroup)

    var id: UUID {
        switch self {
        case .item(let item, _): return item.id
        case .group(let group): return group.id
        }
    }
}

/// A torrent whose files show as one row in the list.
struct TorrentGroup {
    let id: UUID
    let name: String
    let members: [DownloadItem]      // every file of the torrent in the list
    let shown: [DownloadItem]        // the ones the filter and search let through

    /// The torrent's folder in Downloads.
    var folderURL: URL? {
        guard let root = members.compactMap({ $0.folder }).first?.split(separator: "/").first else { return nil }
        return DownloadManager.downloadsDir.appendingPathComponent(String(root), isDirectory: true)
    }
}

extension DownloadItem {
    /// Sorts a torrent's files the way the torrent lays them out.
    var sortPath: String { (folder ?? "") + "/" + fileName }
}

/// Opens the Files app at a folder in JDLite's storage.
@MainActor
enum FilesApp {
    static func open(_ folder: URL) {
        let path = folder.path
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        if let url = URL(string: "shareddocuments://" + encoded) {
            UIApplication.shared.open(url)
        }
    }
}

/// A torrent's files as one row: combined progress, and a button to show the files.
struct GroupRow: View {
    @EnvironmentObject var manager: DownloadManager
    @Environment(\.editMode) private var editMode
    let group: TorrentGroup
    let speeds: [UUID: Double]
    let expanded: Bool
    let toggle: () -> Void

    private var editing: Bool { editMode?.wrappedValue.isEditing == true }
    private var members: [DownloadItem] { group.members }
    private var done: Int { members.filter { $0.state == .completed }.count }
    private var failed: Int { members.filter { $0.state == .failed }.count }
    private var paused: Int { members.filter { $0.state == .paused }.count }
    private var waiting: Int {
        members.filter { $0.state == .queued || $0.state == .resolving || $0.state == .downloading }.count
    }
    private var downloading: Bool { members.contains { $0.state == .downloading } }
    private var allDone: Bool { done == members.count }
    private var totalBytes: Int64 { members.reduce(Int64(0)) { $0 + max($1.bytesTotal, 0) } }
    private var receivedBytes: Int64 {
        members.reduce(Int64(0)) { $0 + ($1.state == .completed ? max($1.bytesTotal, $1.bytesReceived) : $1.bytesReceived) }
    }
    private var speed: Double { members.reduce(0.0) { $0 + (speeds[$1.id] ?? 0) } }

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(tint.opacity(0.14))
                    .frame(width: 42, height: 42)
                    .overlay(
                        Image(systemName: "folder.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(tint)
                    )
                if allDone {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.white, Color.green)
                        .background(Circle().fill(Color(.systemBackground)).padding(-1.5))
                        .offset(x: 4, y: 4)
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(group.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !allDone && (totalBytes > 0 || downloading) {
                    ProgressBar(fraction: totalBytes > 0 ? min(Double(receivedBytes) / Double(totalBytes), 1) : nil,
                                tint: downloading ? Color.accentColor : (failed > 0 ? Color.red : Color.gray))
                }
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(failed > 0 && waiting == 0 ? Color.red : Color.secondary)
                    .lineLimit(2)
            }
            if !editing {
                if let action {
                    Button(action: action.run) {
                        Image(systemName: action.symbol).font(.title2)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(action.label)
                }
                Button(action: toggle) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color(.tertiarySystemFill)))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(expanded ? "Hide files" : "Show files")
            }
        }
        .padding(.vertical, 4)
    }

    private var tint: Color {
        if allDone { return .green }
        if downloading { return .accentColor }
        if failed > 0 && waiting == 0 { return .red }
        return .gray
    }

    private var summary: String {
        let count = members.count
        if allDone { return "\(count) files · \(Fmt.bytes(totalBytes)) · Finished" }
        var parts = ["\(done) of \(count) files"]
        if totalBytes > 0 { parts.append("\(Fmt.bytes(receivedBytes)) of \(Fmt.bytes(totalBytes))") }
        if speed > 0 { parts.append(Fmt.speed(speed)) }
        if failed > 0 {
            parts.append("\(failed) failed")
        } else if waiting == 0 && paused > 0 {
            parts.append("Paused")
        }
        return parts.joined(separator: " · ")
    }

    private struct GroupAction {
        let symbol: String
        let label: String
        let run: () -> Void
    }

    /// Pause while anything is going, else resume what's paused, else retry what failed.
    private var action: GroupAction? {
        let ids = Set(members.map { $0.id })
        let manager = self.manager
        if waiting > 0 { return GroupAction(symbol: "pause.circle", label: "Pause") { manager.pauseAll(ids) } }
        if paused > 0 { return GroupAction(symbol: "play.circle", label: "Resume") { manager.resumeAll(ids) } }
        if failed > 0 { return GroupAction(symbol: "arrow.clockwise.circle", label: "Retry") { manager.retryFailed(ids) } }
        return nil
    }
}

/// The sheet for picking which of a waiting torrent's files to download.
private struct ChooseFilesSheet: View {
    @EnvironmentObject var manager: DownloadManager
    @Environment(\.dismiss) private var dismiss
    let itemID: UUID
    @State private var files: [TorBoxFile]
    @State private var title: String

    init(itemID: UUID, item: DownloadItem?) {
        self.itemID = itemID
        // Taken once, so the list stays put while the sheet closes.
        _files = State(initialValue: item?.choices ?? [])
        _title = State(initialValue: item?.groupName ?? item?.fileName ?? "Torrent")
    }

    var body: some View {
        NavigationStack {
            if files.isEmpty {
                ContentUnavailableView("Nothing to pick", systemImage: "checklist",
                                       description: Text("This torrent's files have already been picked."))
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                    }
            } else {
                TorrentFilesView(title: title, files: files, showsCancel: true) { chosen in
                    manager.chooseFiles(itemID, fileIDs: chosen)
                }
            }
        }
    }
}

// MARK: - Row

struct DownloadRow: View {
    @EnvironmentObject var manager: DownloadManager
    @Environment(\.editMode) private var editMode
    let item: DownloadItem
    let speed: Double?
    var inGroup = false                       // shown under its torrent's group row
    var chooseFiles: (() -> Void)? = nil      // opens the file picker for a waiting torrent
    @State private var expanded = false

    private var editing: Bool { editMode?.wrappedValue.isEditing == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                FileBadge(item: item)
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.fileName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let bar = barStyle {
                        ProgressBar(fraction: bar.fraction, tint: bar.tint)
                    }
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(item.state == .failed ? Color.red : Color.secondary)
                        .lineLimit(2)
                }
                if !editing {
                    if let symbol = actionSymbol {
                        Button(action: act) {
                            Image(systemName: symbol).font(.title2)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(actionLabel)
                    }
                    Button {
                        withAnimation(.snappy) { expanded.toggle() }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.bold))
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Color(.tertiarySystemFill)))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(expanded ? "Less" : "More")
                }
            }
            if expanded && !editing {
                DownloadDetails(item: item, speed: speed, connections: manager.connectionCounts[item.id])
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 4)
        .padding(.leading, inGroup ? 22 : 0)
    }

    private struct BarStyle {
        var fraction: Double?
        var tint: Color
    }

    private var barStyle: BarStyle? {
        switch item.state {
        case .downloading:
            return BarStyle(fraction: item.bytesTotal > 0 ? item.progress : nil, tint: .accentColor)
        case .resolving:
            return item.torboxId != nil ? BarStyle(fraction: item.cloudProgress, tint: .purple) : nil
        case .choosing:
            return nil
        case .paused:
            return BarStyle(fraction: item.progress, tint: .gray)
        case .queued:
            return item.bytesReceived > 0 ? BarStyle(fraction: item.progress, tint: .gray) : nil
        case .failed:
            return item.bytesReceived > 0 && item.bytesTotal > 0 ? BarStyle(fraction: item.progress, tint: .red) : nil
        case .completed:
            return nil
        }
    }

    private var percent: String { "\(Int((item.progress * 100).rounded(.down)))%" }

    private var summary: String {
        switch item.state {
        case .queued:
            if let status = item.status { return status }   // "Waiting for Wi-Fi…"
            return item.torboxId != nil ? "Queued · via TorBox" : "Queued"
        case .resolving:
            return item.status ?? "Resolving…"
        case .choosing:
            let count = item.choices?.count ?? 0
            return "\(count) files ready on TorBox · Choose which to download"
        case .downloading:
            if let status = item.status { return status }   // "Connecting…", "Waiting for TorBox…"
            var parts: [String] = []
            if item.bytesTotal > 0 {
                parts.append(percent)
                parts.append("\(Fmt.bytes(item.bytesReceived)) of \(Fmt.bytes(item.bytesTotal))")
            } else {
                parts.append(Fmt.bytes(item.bytesReceived))
            }
            if let speed, speed > 0 { parts.append(Fmt.speed(speed)) }
            return parts.joined(separator: " · ")
        case .paused:
            return item.bytesTotal > 0 ? "Paused · \(percent) of \(Fmt.bytes(item.bytesTotal))" : "Paused"
        case .completed:
            return item.bytesTotal > 0 ? "\(Fmt.bytes(item.bytesTotal)) · Finished" : "Finished"
        case .failed:
            let message = item.error ?? "Failed"
            return item.retryAt != nil ? message + " Trying again by itself…" : message
        }
    }

    private var actionSymbol: String? {
        switch item.state {
        case .downloading, .resolving: return "pause.circle"
        case .paused: return "play.circle"
        case .failed: return "arrow.clockwise.circle"
        case .choosing: return chooseFiles != nil ? "checklist" : nil
        default: return nil
        }
    }

    private var actionLabel: String {
        switch item.state {
        case .paused: return "Resume"
        case .failed: return "Retry"
        case .choosing: return "Choose Files"
        default: return "Pause"
        }
    }

    private func act() {
        switch item.state {
        case .downloading, .resolving: manager.pause(item.id)
        case .paused, .failed: manager.resume(item.id)
        case .choosing: chooseFiles?()
        default: break
        }
    }
}

// MARK: - "More" panel

struct DownloadDetails: View {
    let item: DownloadItem
    let speed: Double?
    var connections: Int?

    private struct DetailRow: Identifiable {
        let label: String
        let value: String
        var id: String { label }
        init(_ label: String, _ value: String) { self.label = label; self.value = value }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline) {
                    Text(row.label).foregroundStyle(.secondary)
                    Spacer(minLength: 16)
                    Text(row.value)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
            }
            HStack(spacing: 8) {
                if !(item.sourceURL ?? item.url).isFileURL {
                    Button {
                        UIPasteboard.general.string = (item.sourceURL ?? item.url).absoluteString
                    } label: {
                        pill("Copy Link", "doc.on.doc")
                    }
                }
                if item.state == .completed {
                    Button {
                        // Opens the Files app at the folder the file is in.
                        let file = DownloadManager.downloadsDir.appendingPathComponent(item.savedFileName ?? item.fileName)
                        FilesApp.open(file.deletingLastPathComponent())
                    } label: {
                        pill("Show in Files", "folder")
                    }
                }
            }
            .buttonStyle(.borderless)
            .padding(.top, 2)
        }
        .font(.caption)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.secondarySystemBackground)))
    }

    private func pill(_ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color(.tertiarySystemFill)))
    }

    private var rows: [DetailRow] {
        var r: [DetailRow] = [DetailRow("Status", statusWord)]
        if item.state == .downloading {
            r.append(DetailRow("Speed", speed.map { Fmt.speed($0) } ?? "Measuring…"))
            if let speed, speed > 0, item.bytesTotal > item.bytesReceived {
                r.append(DetailRow("Time left", Fmt.duration(Double(item.bytesTotal - item.bytesReceived) / speed)))
            }
        }
        if item.state != .completed && (item.bytesReceived > 0 || item.bytesTotal > 0) {
            r.append(DetailRow("Downloaded", item.bytesTotal > 0
                ? "\(Fmt.bytes(item.bytesReceived)) of \(Fmt.bytes(item.bytesTotal)) (\(Int(item.progress * 100))%)"
                : Fmt.bytes(item.bytesReceived)))
        }
        r.append(DetailRow("File size", item.bytesTotal > 0 ? Fmt.bytes(item.bytesTotal) : "Unknown yet"))
        if item.state == .downloading, let connections, connections > 0 {
            r.append(DetailRow("Connections", "\(connections)"))
        }
        if item.state == .resolving, let p = item.cloudProgress {
            r.append(DetailRow("TorBox", "\(Int(p * 100))% fetched"))
        }
        if item.state == .choosing, let files = item.choices {
            r.append(DetailRow("Files", "\(files.count) to choose from"))
        }
        if let torrent = item.groupName, item.state != .choosing {
            r.append(DetailRow("Torrent", torrent))
        }
        let source = item.sourceURL ?? item.url
        if source.host == "torbox.app" {
            r.append(DetailRow("From", "Your TorBox cloud"))
        } else if item.torboxKind == .torrent {
            let kind = source.isFileURL ? ".torrent file" : (source.scheme == "magnet" ? "Magnet link" : (source.host ?? "Torrent"))
            r.append(DetailRow("From", kind + " via TorBox"))
        } else {
            r.append(DetailRow("From", (source.host ?? source.absoluteString) + (item.torboxId != nil ? " via TorBox" : "")))
        }
        if item.state == .completed, let name = item.savedFileName {
            r.append(DetailRow("Saved as", "Downloads/" + name))
        }
        if let d = item.addedAt { r.append(DetailRow("Added", Fmt.date(d))) }
        if let d = item.completedAt { r.append(DetailRow("Finished", Fmt.date(d))) }
        if item.state == .failed, let e = item.error { r.append(DetailRow("Error", e)) }
        if item.state == .failed, item.retryAt != nil {
            r.append(DetailRow("Next", "Tries again by itself in a moment"))
        }
        return r
    }

    private var statusWord: String {
        switch item.state {
        case .queued: return "Queued"
        case .resolving: return item.torboxId != nil ? "TorBox is fetching it" : "Finding the file"
        case .choosing: return "Ready: pick which files to download"
        case .downloading: return "Downloading"
        case .paused: return "Paused"
        case .completed: return "Finished"
        case .failed: return "Failed"
        }
    }
}

// MARK: - Progress bar

struct ProgressBar: View {
    /// 0...1, or nil when the size isn't known yet (shows a moving bar).
    var fraction: Double?
    var tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.systemFill))
                if let fraction {
                    let f = CGFloat(min(max(fraction, 0), 1))
                    Capsule()
                        .fill(tint)
                        .frame(width: f > 0 ? max(geo.size.width * f, 6) : 0)
                        .animation(.easeOut(duration: 0.35), value: f)
                } else {
                    MovingBar(tint: tint, width: geo.size.width)
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(fraction.map { "\(Int($0 * 100)) percent" } ?? "In progress")
    }
}

private struct MovingBar: View {
    var tint: Color
    var width: CGFloat
    @State private var moving = false

    var body: some View {
        Capsule()
            .fill(tint)
            .frame(width: width * 0.35)
            .offset(x: moving ? width : -width * 0.35)
            .onAppear {
                withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { moving = true }
            }
    }
}

// MARK: - File type badge

struct FileBadge: View {
    let item: DownloadItem

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.opacity(0.14))
                .frame(width: 42, height: 42)
                .overlay(
                    Image(systemName: item.state == .choosing ? "checklist" : FileBadge.symbol(for: item.fileName))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(tint)
                )
            if let badge {
                Image(systemName: badge.symbol)
                    .symbolRenderingMode(.palette)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.white, badge.color)
                    .background(Circle().fill(Color(.systemBackground)).padding(-1.5))
                    .offset(x: 4, y: 4)
            }
        }
        .accessibilityHidden(true)
    }

    private var tint: Color {
        switch item.state {
        case .completed: return .green
        case .failed: return .red
        case .resolving: return item.torboxId != nil ? .purple : .accentColor
        case .choosing: return .purple
        case .paused, .queued: return .gray
        case .downloading: return .accentColor
        }
    }

    private var badge: (symbol: String, color: Color)? {
        switch item.state {
        case .completed: return (symbol: "checkmark.circle.fill", color: Color.green)
        case .failed: return (symbol: "exclamationmark.circle.fill", color: Color.red)
        case .paused: return (symbol: "pause.circle.fill", color: Color.gray)
        default: return nil
        }
    }

    static func symbol(for name: String) -> String {
        FileKind.of(name).symbol
    }
}

// MARK: - Formatting

enum Fmt {
    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    static func speed(_ bytesPerSecond: Double) -> String { bytes(Int64(bytesPerSecond)) + "/s" }

    static func duration(_ seconds: Double) -> String {
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.allowedUnits = seconds >= 3600 ? [.hour, .minute] : (seconds >= 60 ? [.minute, .second] : [.second])
        f.maximumUnitCount = 2
        return f.string(from: max(1, seconds.rounded())) ?? "–"
    }

    static func date(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .shortened) }
}

// MARK: - Add links

struct AddLinksView: View {
    @EnvironmentObject var manager: DownloadManager
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var torrentPick: FilesPickRequest?
    @State private var askingAboutRepeats = false

    private static let torrentType = UTType(filenameExtension: "torrent") ?? .data

    private var links: [URL] { DownloadManager.extractLinks(from: text) }

    /// The links that are already in the list.
    private var repeats: [URL] { manager.duplicates(in: links) }

    private var repeatNote: String {
        let count = repeats.count
        if count == links.count {
            return count == 1 ? "This link is already in your list." : "All of these links are already in your list."
        }
        return count == 1 ? "1 of these links is already in your list." : "\(count) of these links are already in your list."
    }

    private var found: String {
        let magnets = links.filter { $0.scheme?.lowercased() == "magnet" }.count
        let total = links.count
        var s = total == 1 ? "1 link found" : "\(total) links found"
        if magnets > 0 { s += magnets == total ? (total == 1 ? " (a magnet link)" : " (magnet links)") : " (\(magnets) magnet)" }
        return s
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $text)
                    .frame(minHeight: 180)
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                Text(found).font(.footnote).foregroundStyle(.secondary)
                if !repeats.isEmpty {
                    Label(repeatNote, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                Button {
                    torrentPick = FilesPickRequest(types: [Self.torrentType], asCopy: true, multiple: true)
                } label: {
                    Label("Add .torrent Files…", systemImage: "doc.badge.plus")
                }
                .padding(.top, 8)
                Text("Magnet links and .torrent files download through TorBox.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding()
            .filesPicker($torrentPick) { urls in
                guard !urls.isEmpty else { return }
                for url in urls { manager.importFile(url) }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 600_000_000)   // let the picker close first
                    dismiss()
                }
            }
            .confirmationDialog(repeatNote, isPresented: $askingAboutRepeats, titleVisibility: .visible) {
                Button(repeats.count == 1 ? "Add It Again" : "Add Them Again") {
                    manager.add(urls: links, allowDuplicates: true)
                    dismiss()
                }
                if repeats.count < links.count {
                    Button("Only Add the New Ones") {
                        manager.add(urls: links)
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .navigationTitle("Add links")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Paste") { text = UIPasteboard.general.string ?? text }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { addLinks() }.disabled(links.isEmpty)
                }
            }
        }
    }

    /// Adds the links, first asking about any that are already in the list.
    private func addLinks() {
        if repeats.isEmpty {
            manager.add(urls: links)
            dismiss()
        } else {
            askingAboutRepeats = true
        }
    }
}
