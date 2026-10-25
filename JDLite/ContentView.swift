import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    enum Sheet: Identifiable {
        case add, torbox, plugins, settings
        var id: Self { self }
    }

    @EnvironmentObject var manager: DownloadManager
    @ObservedObject private var system = SystemStatus.shared
    @State private var sheet: Sheet?
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<UUID>()
    @State private var pendingDelete = Set<UUID>()
    @State private var confirmingDelete = false
    @AppStorage("sortOrder") private var sortOrder: SortOrder = .oldest
    @AppStorage("statusFilter") private var statusFilter: StatusFilter = .all
    @AppStorage("typeFilter") private var typeFilter: String = "all"

    private var isEditing: Bool { editMode.isEditing }
    private var isFiltering: Bool { statusFilter != .all || typeFilter != "all" }

    /// The downloads after the filter, sorted by when they were added.
    private var visibleItems: [DownloadItem] {
        let filtered = manager.items.enumerated().filter { pair in
            statusFilter.matches(pair.element)
                && (typeFilter == "all" || FileKind.of(pair.element.fileName).rawValue == typeFilter)
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

    private var allSelected: Bool {
        let ids = Set(visibleItems.map(\.id))
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
                    List(selection: $selection) {
                        if !isEditing && !system.backgroundRefreshOn {
                            BackgroundWarning(lowPower: system.lowPowerMode) { system.openAppSettings() }
                        }
                        if !isEditing && isFiltering && !visible.isEmpty {
                            FilterSummary(text: filterSummary, count: visible.count) { clearFilters() }
                        }
                        ForEach(visible) { item in
                            DownloadRow(item: item, speed: manager.speeds[item.id])
                                .tag(item.id)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button {
                                        askToDelete([item.id])
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    .tint(.red)
                                }
                        }
                    }
                    .listStyle(.plain)
                    .overlay {
                        if visible.isEmpty {
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
            .environment(\.editMode, $editMode)
            .navigationTitle("JDLite")
            .toolbar { toolbarContent }
            .confirmationDialog(deleteTitle, isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    let ids = pendingDelete
                    manager.delete(ids)
                    selection.subtract(ids)
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
                case .plugins: PluginsView()
                case .settings: SettingsView()
                }
            }
            .task { await PluginHost.shared.ensureLoaded() }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isEditing {
            ToolbarItem(placement: .topBarLeading) {
                Button(allSelected ? "Deselect All" : "Select All") {
                    selection = allSelected ? [] : Set(visibleItems.map(\.id))
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
                    Button("Plugins", systemImage: "puzzlepiece.extension") { sheet = .plugins }
                    Button("Settings", systemImage: "gearshape") { sheet = .settings }
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

    private func askToDelete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        pendingDelete = ids
        confirmingDelete = true
    }

    private var pendingItems: [DownloadItem] { manager.items.filter { pendingDelete.contains($0.id) } }

    private var deleteTitle: String {
        let items = pendingItems
        if items.count == 1 { return "Delete “\(items[0].fileName)”?" }
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

// MARK: - Row

struct DownloadRow: View {
    @EnvironmentObject var manager: DownloadManager
    @Environment(\.editMode) private var editMode
    let item: DownloadItem
    let speed: Double?
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
            return item.error ?? "Failed"
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

    private var actionLabel: String {
        switch item.state {
        case .paused: return "Resume"
        case .failed: return "Retry"
        default: return "Pause"
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
                if item.state == .completed && item.savedFolder == nil {
                    Button {
                        // Opens the Files app at this app's Downloads folder.
                        let path = DownloadManager.downloadsDir.path
                        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
                        if let url = URL(string: "shareddocuments://" + encoded) {
                            UIApplication.shared.open(url)
                        }
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
        let source = item.sourceURL ?? item.url
        if item.torboxKind == .torrent {
            let kind = source.isFileURL ? ".torrent file" : (source.scheme == "magnet" ? "Magnet link" : (source.host ?? "Torrent"))
            r.append(DetailRow("From", kind + " via TorBox"))
        } else {
            r.append(DetailRow("From", (source.host ?? source.absoluteString) + (item.torboxId != nil ? " via TorBox" : "")))
        }
        if item.state == .completed, let name = item.savedFileName {
            r.append(DetailRow("Saved as", (item.savedFolder ?? "Downloads") + "/" + name))
        }
        if let d = item.addedAt { r.append(DetailRow("Added", Fmt.date(d))) }
        if let d = item.completedAt { r.append(DetailRow("Finished", Fmt.date(d))) }
        if item.state == .failed, let e = item.error { r.append(DetailRow("Error", e)) }
        return r
    }

    private var statusWord: String {
        switch item.state {
        case .queued: return "Queued"
        case .resolving: return item.torboxId != nil ? "TorBox is fetching it" : "Finding the file"
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
                    Image(systemName: FileBadge.symbol(for: item.fileName))
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
    @State private var pickingTorrent = false

    private static let torrentType = UTType(filenameExtension: "torrent") ?? .data

    private var links: [URL] { DownloadManager.extractLinks(from: text) }

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
                Button {
                    pickingTorrent = true
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
            .fileImporter(isPresented: $pickingTorrent, allowedContentTypes: [Self.torrentType],
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result, !urls.isEmpty {
                    for url in urls { manager.importFile(url) }
                    dismiss()
                }
            }
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
