import Foundation
import Combine
import UIKit

/// `choosing`: a torrent is ready on TorBox or Offcloud and waits for you to pick which files to download.
enum DownloadState: String, Codable { case queued, resolving, choosing, downloading, paused, completed, failed }

/// One byte range of a file. In-app connections write it straight into the download's data
/// file; a background (iOS) transfer fetches it into a file of its own, which is copied into
/// place when it arrives.
struct Segment: Codable, Equatable {
    var start: Int64
    var end: Int64                   // inclusive
    var received: Int64 = 0          // bytes fetched so far
    var done = false                 // saved in the data file
    var retries = 0
    var resumeData: Data?
    var background: Bool?            // being fetched by a background transfer

    var length: Int64 { end - start + 1 }
}

/// What a quick look at a file's first byte says about the server.
struct Probe: Sendable {
    let total: Int64
    let acceptsRanges: Bool
}

/// A finished file in its place in Downloads. (Not called SavedFile: an older file used that name.)
struct FinishedFile: Sendable {
    let url: URL
    let path: String                 // inside Downloads, with its folder
    let size: Int64
}

/// What a background transfer's description says about it.
struct TransferTag: Sendable {
    let id: UUID
    let name: String?
    let part: Int64?                 // start of the part it carries (nil = the whole file)
    let length: Int64?
    let outdated: Bool               // made by an older version of the app
}

struct DownloadItem: Identifiable, Codable {
    var id = UUID()
    var url: URL
    var fileName: String
    var state: DownloadState = .queued
    var bytesReceived: Int64 = 0
    var bytesTotal: Int64 = 0
    var resumeData: Data?
    var error: String?
    var headers: [String: String]?   // from a plugin, sent with the download
    var needsResolve: Bool?          // true until plugins/TorBox have looked at the link
    var preferredName: String?       // file name chosen by a plugin, TorBox or the server
    var status: String?              // progress note (resolving, connecting)
    var sourceURL: URL?              // the link as it was added
    var torboxId: Int?               // TorBox web download ID
    var torboxFileId: Int?           // file inside that TorBox download
    var cloudProgress: Double?       // how far TorBox has fetched the file (0...1)
    var savedName: String?           // file name in Downloads once finished
    var addedAt: Date?
    var completedAt: Date?
    var segments: [Segment]?         // the file's parts, once its size is known
    var singleConnection: Bool?      // the server can't send parts of this file
    var layout: Int?                 // 2: parts are saved into one data file
    var torboxKind: TorBoxKind?      // .torrent for torrents (nil: a link from a file host)
    var torrentFile: String?         // a .torrent file waiting to go to TorBox (in Torrents/)
    var groupID: UUID?               // a torrent's files share this; the list shows them as one group
    var groupName: String?           // that torrent's name
    var folder: String?              // the folder inside Downloads the file goes into (nil: Downloads itself)
    var choices: [TorBoxFile]?       // a torrent's files, while you pick which to download
    var autoRetries: Int?            // tries it made by itself after the connection dropped
    var retryAt: Date?               // when it tries again by itself
    var retryMark: Int64?            // how far it had got at the last of those tries
    var offcloudId: String?          // Offcloud request ID: a torrent (or link) it fetches to its cloud
    var offcloudFile: Bool?          // the link is a file in your Offcloud cloud, so it's never looked up again
    var viaOffcloud: Bool?           // Offcloud gave the link
    var askOffcloud: Bool?           // the next look-up sends the link to Offcloud even if Offcloud doesn't list the site
    var triedServices: [String]?     // TorBox/Offcloud, if they couldn't get it this time

    var progress: Double { bytesTotal > 0 ? min(Double(bytesReceived) / Double(bytesTotal), 1) : 0 }

    /// A file in TorBox's or Offcloud's cloud: its link stays the same, so it's never looked up again.
    var isCloudFile: Bool { torboxFileId != nil || offcloudFile == true }

    /// The service the file comes through, if any.
    var serviceName: String? {
        if torboxId != nil { return "TorBox" }
        if offcloudId != nil || viaOffcloud == true { return "Offcloud" }
        return nil
    }

    /// The finished file's path inside Downloads (with its folder), if there is one.
    var savedFileName: String? { savedName ?? (state == .completed ? fileName : nil) }
}

@MainActor
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var items: [DownloadItem] = []
    /// Current speed (bytes per second) of each running download.
    @Published private(set) var speeds: [UUID: Double] = [:]
    /// How many connections each running download is using.
    @Published private(set) var connectionCounts: [UUID: Int] = [:]
    /// Links sent from Safari or the share sheet that were already in the list. The list asks
    /// whether to add them again.
    @Published private(set) var repeatedLinks: [URL] = []
    /// Handed over by iOS when it wakes the app for finished background transfers.
    var backgroundCompletionHandlers: [String: () -> Void] = [:]

    // Background transfers: several background sessions ("lanes"), so parts travel over
    // separate connections and keep going while the app sleeps.
    private var lanes: [URLSession] = []
    private static let laneCount = 8
    private var nextLane = 0
    /// Background session for TorBox status checks while the app is asleep.
    private var checks: URLSession!
    nonisolated private static let checkPrefix = "torbox-check"

    // In-app connections (see TurboWorker): much faster than background transfers, used
    // while JDLite is open or kept awake in the background.
    private var workers: [UUID: [TurboWorker]] = [:]
    private var directURLs: [UUID: URL] = [:]      // where the file really is, after redirects
    private var workerLimit: [UUID: Int] = [:]     // lowered when a server refuses extra connections
    private var jsonReplies = Set<UUID>()
    private var attempts: [String: (count: Int, position: Int64)] = [:]
    private var progressLoop: Task<Void, Never>?
    /// True while downloads can use in-app connections.
    private var inApp = true

    private static let minPartSize: Int64 = 2 << 20      // files are split into parts at least this big
    private static let minStealSize: Int64 = 2 << 20     // smallest piece a connection takes over
    private static let reclaimLimit: Int64 = 16 << 20    // background progress worth keeping

    private var torboxPoller: Task<Void, Never>?
    private var pollSoon = false
    private var offcloudPoller: Task<Void, Never>?
    private var offcloudPollSoon = false
    private var samples: [UUID: (time: TimeInterval, bytes: Int64)] = [:]
    private var liveBytes: [UUID: [Int64: Int64]] = [:]  // background part progress not yet copied into items
    private var bgLive: [UUID: Set<Int64>] = [:]         // parts a background transfer is fetching
    private var absorbing = Set<String>()
    private var delivering = Set<UUID>()
    private var probing = Set<UUID>()
    private var finishUp: UIBackgroundTaskIdentifier = .invalid
    private var pendingRestarts = Set<UUID>()
    private var restartTask: Task<Void, Never>?
    private var keepAwakeCheck: Task<Void, Never>?
    private var retryTimer: Task<Void, Never>?
    /// How long a download waits before each try it makes by itself.
    private static let retryDelays: [TimeInterval] = [10, 30, 60, 120, 300]
    private var observers: [NSObjectProtocol] = []
    private var lastSave: TimeInterval = 0
    private let storeURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("downloads.json")
    }()

    private var maxConcurrent: Int { AppSettings.shared.simultaneousDownloads }

    override init() {
        super.init()
        load()
        migrateOldParts()
        Self.preparePartsFolder()
        let base = "\(Bundle.main.bundleIdentifier ?? "jdlite").downloads"
        for n in 0..<Self.laneCount {
            let cfg = URLSessionConfiguration.background(withIdentifier: n == 0 ? base : "\(base).lane\(n)")
            cfg.sessionSendsLaunchEvents = true
            cfg.isDiscretionary = false
            cfg.httpMaximumConnectionsPerHost = 6
            lanes.append(URLSession(configuration: cfg, delegate: self, delegateQueue: nil))
        }
        let checkConfig = URLSessionConfiguration.background(withIdentifier: "\(base).checks")
        checkConfig.sessionSendsLaunchEvents = true
        checkConfig.isDiscretionary = false
        checks = URLSession(configuration: checkConfig, delegate: self, delegateQueue: nil)
        inApp = UIApplication.shared.applicationState != .background
        _ = AppSettings.shared   // applies the speed limit
        NetworkMonitor.shared.start()
        observeAppState()
        reconcile()
    }

    // MARK: Public API

    /// Adds links. Links already in the list are skipped unless `allowDuplicates` is set.
    func add(urls: [URL], allowDuplicates: Bool = false) {
        var known = allowDuplicates ? Set<String>() : linkKeys
        var ids: [UUID] = []
        for url in urls {
            guard known.insert(Self.linkKey(url)).inserted else { continue }   // already there, or twice in one go
            var name = url.lastPathComponent
            if name.isEmpty || name == "/" { name = url.host ?? "download" }
            let magnet = url.scheme?.lowercased() == "magnet"
            if magnet { name = Self.magnetName(url) }
            var item = DownloadItem(url: url, fileName: Self.cleanName(name))
            if magnet { item.torboxKind = .torrent }
            item.state = .resolving
            item.needsResolve = true
            item.sourceURL = url
            item.addedAt = Date()
            items.append(item)
            ids.append(item.id)
        }
        save()
        if !ids.isEmpty { Notifier.shared.askPermissionIfNeeded() }
        for id in ids { Task { await runResolve(id) } }
    }

    /// Keys of the links in the list (see `linkKey`).
    private var linkKeys: Set<String> {
        Set(items.compactMap { item -> String? in
            let link = item.sourceURL ?? item.url
            return link.isFileURL ? nil : Self.linkKey(link)
        })
    }

    /// The links in `urls` that are already in the list.
    func duplicates(in urls: [URL]) -> [URL] {
        let known = linkKeys
        return urls.filter { known.contains(Self.linkKey($0)) }
    }

    /// Spots the same link twice: magnet links by their torrent's hash, other links as they are.
    nonisolated static func linkKey(_ url: URL) -> String {
        if url.scheme?.lowercased() == "magnet",
           let xt = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
               .first(where: { $0.name.lowercased() == "xt" })?.value, !xt.isEmpty {
            return "magnet:" + xt.lowercased()
        }
        return url.absoluteString
    }

    func clearRepeatedLinks() {
        repeatedLinks = []
    }

    /// Handles jdlite://add?u=<url>&u=<url> links from the Safari and share extensions
    /// (t=<base64 .torrent file>&tn=<its name> for torrent files), and files opened in JDLite.
    func handleOpen(_ url: URL) {
        if url.isFileURL {
            importFile(url)
            return
        }
        guard url.scheme == "jdlite", url.host == "add",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let query = comps.queryItems ?? []
        let urls = query
            .filter { $0.name == "u" }
            .compactMap { $0.value }
            .compactMap { URL(string: $0) }
            .filter { ["http", "https", "magnet"].contains($0.scheme?.lowercased() ?? "") }
        let repeats = duplicates(in: urls)
        add(urls: urls)   // the new ones; the list asks about the others
        if !repeats.isEmpty { repeatedLinks = repeats }
        let names = query.filter { $0.name == "tn" }.compactMap { $0.value }
        for (k, encoded) in query.filter({ $0.name == "t" }).compactMap({ $0.value }).enumerated() {
            if let data = Self.base64URLDecode(encoded) {
                addTorrentFile(data, name: k < names.count ? names[k] : "Torrent")
            }
        }
    }

    /// A .torrent file opened in JDLite (Share › JDLite, or Open In from the Files app).
    func importFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard url.pathExtension.lowercased() == "torrent",
              let data = try? Data(contentsOf: url), !data.isEmpty, data.count < 50_000_000 else { return }
        addTorrentFile(data, name: url.lastPathComponent)
        // Files handed over by other apps are copied into Documents/Inbox: tidy that up.
        if url.path.contains("/Documents/Inbox/") { try? FileManager.default.removeItem(at: url) }
    }

    /// Adds a .torrent file. It goes to TorBox, which fetches the torrent; then the files download.
    func addTorrentFile(_ data: Data, name: String) {
        let stored = UUID().uuidString + ".torrent"
        let file = Self.torrentsDir.appendingPathComponent(stored)
        try? FileManager.default.createDirectory(at: Self.torrentsDir, withIntermediateDirectories: true)
        guard (try? data.write(to: file, options: .atomic)) != nil else { return }
        let stem = (name as NSString).deletingPathExtension
        var item = DownloadItem(url: file, fileName: Self.cleanName(stem.isEmpty ? "Torrent" : stem))
        item.state = .resolving
        item.needsResolve = true
        item.torboxKind = .torrent
        item.torrentFile = stored
        item.addedAt = Date()
        items.append(item)
        save()
        Notifier.shared.askPermissionIfNeeded()
        let id = item.id
        Task { await runResolve(id) }
    }

    /// Carries on with a paused or failed download. `automatic`: a try it makes by itself.
    func resume(_ id: UUID, automatic: Bool = false) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        clearAttempts(id)
        workerLimit[id] = nil
        mutate(id, persist: false) {
            $0.retryAt = nil
            if !automatic {
                $0.autoRetries = nil
                $0.retryMark = nil
                $0.triedServices = nil   // a retry you ask for gives TorBox and Offcloud another go
                $0.askOffcloud = nil
            }
        }
        if item.needsResolve == true {
            mutate(id) { $0.state = .resolving; $0.error = nil }
            Task { await runResolve(id) }
        } else {
            mutate(id) {
                $0.state = .queued
                $0.error = nil
                if var segs = $0.segments {
                    for k in segs.indices { segs[k].retries = 0 }
                    $0.segments = segs
                }
            }
            startNext()
        }
    }

    func pause(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        switch item.state {
        case .queued, .resolving:
            mutate(id) { $0.state = .paused; $0.status = nil }
        case .downloading:
            turboStop(id)
            bgLive[id] = nil
            refreshProgress(id)
            mutate(id) { $0.state = .paused; $0.status = nil }
            clearTransfer(id)
            startNext()
            Task { await stopTransfers(for: id) }
        default:
            break
        }
    }

    /// Pauses every unfinished download (or just the ones in `only`).
    func pauseAll(_ only: Set<UUID>? = nil) {
        // Waiting ones first, so pausing a running one doesn't start them.
        for i in items.indices where only?.contains(items[i].id) ?? true {
            switch items[i].state {
            case .queued, .resolving:
                items[i].state = .paused
                items[i].status = nil
            case .failed where items[i].retryAt != nil:
                items[i].state = .paused   // it was going to try again by itself
                items[i].retryAt = nil
            default:
                break
            }
        }
        let running = items.filter { $0.state == .downloading && (only?.contains($0.id) ?? true) }.map { $0.id }
        for id in running { pause(id) }
        save()
        scheduleRetryCheck()
    }

    /// Carries on with every paused download (or just the ones in `only`).
    func resumeAll(_ only: Set<UUID>? = nil) {
        let ids = items.filter { $0.state == .paused && (only?.contains($0.id) ?? true) }.map { $0.id }
        for id in ids { resume(id) }
    }

    /// Tries every failed download again (or just the ones in `only`).
    func retryFailed(_ only: Set<UUID>? = nil) {
        let ids = items.filter { $0.state == .failed && (only?.contains($0.id) ?? true) }.map { $0.id }
        for id in ids { resume(id) }
    }

    var canPauseAll: Bool {
        items.contains {
            $0.state == .queued || $0.state == .resolving || $0.state == .downloading
                || ($0.state == .failed && $0.retryAt != nil)
        }
    }

    var canResumeAll: Bool { items.contains { $0.state == .paused } }

    var hasFailed: Bool { items.contains { $0.state == .failed } }

    /// Removes downloads from the list and deletes their files: the finished file,
    /// or whatever was downloaded so far.
    func delete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for id in ids {
            turboStop(id)
            bgLive[id] = nil
            liveBytes[id] = nil
            directURLs[id] = nil
            workerLimit[id] = nil
            jsonReplies.remove(id)
            clearAttempts(id)
            clearTransfer(id)
        }
        Task {
            for (task, _) in await liveTasks(for: ids) { task.cancel() }
        }
        let remaining = items.filter { !ids.contains($0.id) }
        let stillUsed = Set(remaining.compactMap { $0.savedFileName })
        for item in items where ids.contains(item.id) {
            try? FileManager.default.removeItem(at: Self.partsDir(item.id))
            if let stored = item.torrentFile {
                try? FileManager.default.removeItem(at: Self.torrentsDir.appendingPathComponent(stored))
            }
            if let name = item.savedFileName, !stillUsed.contains(name) {
                let file = Self.downloadsDir.appendingPathComponent(name)
                try? FileManager.default.removeItem(at: file)
                Self.removeEmptyFolders(above: file)
            }
        }
        items = remaining
        save()
        startNext()
        scheduleRetryCheck()
    }

    /// Removes finished downloads from the list. Their files stay in Downloads.
    func clearCompleted() {
        for item in items where item.state == .completed {
            if let stored = item.torrentFile {
                try? FileManager.default.removeItem(at: Self.torrentsDir.appendingPathComponent(stored))
            }
        }
        items.removeAll { $0.state == .completed }
        save()
    }

    /// Called when the "downloads at once" setting changes.
    func settingsChanged() { startNext() }

    nonisolated static func extractLinks(from text: String) -> [URL] {
        var seen = Set<URL>()
        var out: [URL] = []
        if let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            det.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) { m, _, _ in
                if let u = m?.url, ["http", "https"].contains(u.scheme?.lowercased() ?? ""), seen.insert(u).inserted {
                    out.append(u)
                }
            }
        }
        // Magnet links (torrents), which the link detector doesn't pick up.
        if let magnets = try? NSRegularExpression(pattern: "magnet:\\?[^\\s\"'<>]+", options: [.caseInsensitive]) {
            for m in magnets.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let r = Range(m.range, in: text), let u = URL(string: String(text[r])), seen.insert(u).inserted else { continue }
                out.append(u)
            }
        }
        return out
    }

    /// A magnet link's display name (dn=...), or a short name made from its hash.
    nonisolated static func magnetName(_ url: URL) -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let name = items.first(where: { $0.name == "dn" })?.value, !name.isEmpty {
            return name.replacingOccurrences(of: "+", with: " ")   // magnet names use + for spaces
        }
        if let xt = items.first(where: { $0.name == "xt" })?.value {
            return "Torrent " + String(xt.split(separator: ":").last?.prefix(8) ?? "")
        }
        return "Torrent"
    }

    nonisolated static func base64URLDecode(_ s: String) -> Data? {
        var b64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        return Data(base64Encoded: b64)
    }

    // MARK: Resolving: plugins first, then TorBox or Offcloud, otherwise download the link directly

    private func runResolve(_ id: UUID) async {
        guard let item = items.first(where: { $0.id == id }), item.state == .resolving else { return }
        let link = item.sourceURL ?? item.url

        // Already handed to TorBox (e.g. the app was closed while TorBox fetched it).
        if item.torboxId != nil {
            if item.torboxFileId != nil {
                mutate(id) { $0.state = .queued; $0.needsResolve = nil; $0.status = nil }
                startNext()
            } else {
                setStatus(id, "Waiting for TorBox…")
                startTorBoxPolling()
            }
            return
        }

        // Already handed to Offcloud's cloud.
        if item.offcloudId != nil {
            if item.offcloudFile == true {
                mutate(id) { $0.state = .queued; $0.needsResolve = nil; $0.status = nil }
                startNext()
            } else {
                setStatus(id, "Waiting for Offcloud…")
                startOffcloudPolling()
            }
            return
        }

        // Torrents (magnet links, .torrent files, links to .torrent files) are fetched by TorBox or Offcloud.
        if item.torboxKind == .torrent || item.torrentFile != nil
            || (link.pathExtension.lowercased() == "torrent" && (TorBox.shared.isActive || Offcloud.shared.isActive)) {
            await sendTorrent(id, item: item, link: link)
            return
        }

        await PluginHost.shared.ensureLoaded()
        if let plugin = PluginHost.shared.match(link) {
            setStatus(id, "Resolving with \(plugin.name)…")
            do {
                let links = try await PluginHost.shared.resolve(plugin: plugin, url: link)
                guard isResolving(id) else { return }
                applyResolved(id, links)
            } catch {
                failResolve(id, error.localizedDescription)
            }
            return
        }

        // Sites TorBox or Offcloud supports: the one you prefer first, then the other if that
        // one couldn't get the file.
        let tried = item.triedServices ?? []
        for service in preferredServices where !tried.contains(service.rawValue) {
            switch service {
            case .torbox:
                guard await TorBox.shared.supports(link) else { continue }
                guard isResolving(id) else { return }
                await sendToTorBox(id, link: link)
                return
            case .offcloud:
                guard Offcloud.shared.isActive else { continue }
                var listed = item.askOffcloud == true
                if !listed { listed = await Offcloud.shared.supports(link) }
                guard listed else { continue }
                guard isResolving(id) else { return }
                await sendToOffcloud(id, link: link)
                return
            }
        }

        guard isResolving(id) else { return }
        mutate(id) { $0.state = .queued; $0.needsResolve = nil; $0.status = nil }
        startNext()
    }

    /// TorBox and Offcloud, the one you prefer first (TorBox unless you picked Offcloud).
    private var preferredServices: [PremiumService] {
        AppSettings.shared.preferOffcloud ? [.offcloud, .torbox] : [.torbox, .offcloud]
    }

    private func isActive(_ service: PremiumService) -> Bool {
        service == .torbox ? TorBox.shared.isActive : Offcloud.shared.isActive
    }

    /// TorBox or Offcloud couldn't get a link or torrent. The other one has a go if it's set up
    /// (for a link, if TorBox supports its site); otherwise the download fails with the message.
    private func serviceFailed(_ id: UUID, _ service: PremiumService, _ message: String) async {
        guard isResolving(id), let item = items.first(where: { $0.id == id }) else { return }
        var tried = item.triedServices ?? []
        if !tried.contains(service.rawValue) { tried.append(service.rawValue) }
        let torrent = item.torboxKind == .torrent || item.torrentFile != nil
        let link = item.sourceURL ?? item.url
        var next: PremiumService?
        for other in preferredServices where !tried.contains(other.rawValue) && isActive(other) {
            if other == .torbox && !torrent {
                guard await TorBox.shared.supports(link) else { continue }
            }
            next = other
            break
        }
        guard let next, isResolving(id) else {
            mutate(id, persist: false) {
                $0.triedServices = nil
                $0.askOffcloud = nil
            }
            failResolve(id, message)
            return
        }
        mutate(id) {
            $0.triedServices = tried
            $0.askOffcloud = next == .offcloud ? true : nil
            $0.status = "\(service.name) couldn't get it. Trying \(next.name)…"
        }
        await runResolve(id)
    }

    /// A link from a site TorBox supports goes to TorBox, which fetches the file for us.
    private func sendToTorBox(_ id: UUID, link: URL) async {
        setStatus(id, "Sending to TorBox…")
        do {
            let webId = try await TorBox.shared.create(link: link)
            guard items.contains(where: { $0.id == id }) else { return }
            mutate(id) { $0.torboxId = webId }
            guard isResolving(id) else { return }
            setStatus(id, "Waiting for TorBox…")
            startTorBoxPolling(restart: true)
        } catch is URLError {
            failResolve(id, "TorBox: can't connect.", retryable: true)
        } catch {
            await serviceFailed(id, .torbox, "TorBox: " + error.localizedDescription)
        }
    }

    /// Gets a link through Offcloud. Most sites give a direct link at once; sites Offcloud only
    /// fetches to its cloud (or that don't get an instant link) go through the cloud instead.
    private func sendToOffcloud(_ id: UUID, link: URL) async {
        mutate(id, persist: false) { $0.askOffcloud = nil }
        if !Offcloud.shared.onlyThroughCloud(link) {
            setStatus(id, "Asking Offcloud…")
            do {
                let got = try await Offcloud.shared.instant(link)
                guard isResolving(id) else { return }
                mutate(id) {
                    $0.url = got.url
                    if let name = got.fileName {
                        $0.fileName = Self.cleanName(name)
                        $0.preferredName = Self.cleanName(name)
                    }
                    $0.sourceURL = link
                    $0.headers = nil
                    $0.viaOffcloud = true
                    $0.triedServices = nil
                    $0.state = .queued
                    $0.needsResolve = nil
                    $0.status = nil
                    $0.error = nil
                }
                startNext()
                return
            } catch let error as OffcloudError where error.triesCloud {
                // No instant link: Offcloud's cloud may still be able to fetch it.
            } catch {
                await offcloudFailed(id, error)
                return
            }
        }
        await sendToOffcloudCloud(id, link: link.absoluteString)
    }

    /// Hands a link or magnet link to Offcloud's cloud, then waits for Offcloud to fetch it.
    private func sendToOffcloudCloud(_ id: UUID, link: String) async {
        guard isResolving(id) else { return }
        setStatus(id, "Sending to Offcloud…")
        do {
            let requestId = try await Offcloud.shared.addToCloud(link)
            guard items.contains(where: { $0.id == id }) else { return }
            mutate(id) {
                $0.offcloudId = requestId
                $0.viaOffcloud = true
            }
            guard isResolving(id) else { return }
            setStatus(id, "Waiting for Offcloud…")
            startOffcloudPolling(restart: true)
        } catch {
            await offcloudFailed(id, error)
        }
    }

    /// Offcloud couldn't do it. A dropped connection or a busy Offcloud means trying again
    /// later; anything else gives TorBox a go, if it can.
    private func offcloudFailed(_ id: UUID, _ error: Error) async {
        let message = Self.offcloudText(error)
        if Self.passing(error) {
            failResolve(id, message, retryable: true)
        } else {
            await serviceFailed(id, .offcloud, message)
        }
    }

    /// Offcloud's message, with "Offcloud:" in front unless it already says Offcloud.
    nonisolated static func offcloudText(_ error: Error) -> String {
        let text = error.localizedDescription
        return text.localizedCaseInsensitiveContains("offcloud") ? text : "Offcloud: " + text
    }

    /// A problem that passes by itself: the connection, or a busy server.
    nonisolated private static func passing(_ error: Error) -> Bool {
        if error is URLError { return true }
        if let offcloud = error as? OffcloudError, case .busy = offcloud { return true }
        return false
    }

    /// Sends a torrent to TorBox or Offcloud: the one you prefer first, the other if that one
    /// can't take it.
    private func sendTorrent(_ id: UUID, item: DownloadItem, link: URL) async {
        let tried = item.triedServices ?? []
        guard let service = preferredServices.first(where: { !tried.contains($0.rawValue) && isActive($0) }) else {
            failResolve(id, TorBox.shared.hasKey || Offcloud.shared.hasKey
                ? "Torrents download through TorBox or Offcloud. Switch one on in the ⋯ menu, then tap retry."
                : "Torrents and magnet links download through TorBox or Offcloud. Add your account in the ⋯ menu, then tap retry.")
            return
        }
        switch service {
        case .torbox: await sendTorrentToTorBox(id, item: item, link: link)
        case .offcloud: await sendTorrentToOffcloud(id, item: item, link: link)
        }
    }

    private func sendTorrentToTorBox(_ id: UUID, item: DownloadItem, link: URL) async {
        setStatus(id, "Sending to TorBox…")
        do {
            let torrentId: Int
            if let stored = item.torrentFile {
                let data = try Data(contentsOf: Self.torrentsDir.appendingPathComponent(stored))
                torrentId = try await TorBox.shared.createTorrent(file: data, name: item.fileName)
            } else if link.scheme?.lowercased() == "magnet" {
                torrentId = try await TorBox.shared.createTorrent(magnet: link.absoluteString)
            } else {
                // A link to a .torrent file: fetch the small file, then hand it to TorBox.
                let data = try await fetchTorrentFile(link, headers: item.headers)
                torrentId = try await TorBox.shared.createTorrent(file: data, name: link.lastPathComponent)
            }
            guard items.contains(where: { $0.id == id }) else { return }
            // The .torrent file is kept until the download is removed, so a retry can send it again.
            mutate(id) {
                $0.torboxId = torrentId
                $0.torboxKind = .torrent
            }
            guard isResolving(id) else { return }
            setStatus(id, "Waiting for TorBox…")
            startTorBoxPolling(restart: true)
        } catch is URLError {
            failResolve(id, "TorBox: can't connect.", retryable: true)
        } catch {
            await serviceFailed(id, .torbox, "TorBox: " + error.localizedDescription)
        }
    }

    /// Offcloud takes torrents as magnet links, so a .torrent file is turned into one first.
    private func sendTorrentToOffcloud(_ id: UUID, item: DownloadItem, link: URL) async {
        setStatus(id, "Sending to Offcloud…")
        let magnet: String
        do {
            if let stored = item.torrentFile {
                let data = try Data(contentsOf: Self.torrentsDir.appendingPathComponent(stored))
                guard let made = TorrentMagnet.from(data) else { throw OffcloudError.api("That .torrent file couldn't be read.") }
                magnet = made
            } else if link.scheme?.lowercased() == "magnet" {
                magnet = link.absoluteString
            } else {
                let data = try await fetchTorrentFile(link, headers: item.headers)
                guard let made = TorrentMagnet.from(data) else { throw OffcloudError.api("That .torrent file couldn't be read.") }
                magnet = made
            }
        } catch {
            await offcloudFailed(id, error)
            return
        }
        mutate(id, persist: false) { $0.torboxKind = .torrent }
        await sendToOffcloudCloud(id, link: magnet)
    }

    /// Fetches the small .torrent file a link points to.
    private func fetchTorrentFile(_ link: URL, headers: [String: String]?) async throws -> Data {
        var req = URLRequest(url: link, timeoutInterval: 30)
        for (k, v) in headers ?? [:] { req.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(status), data.first == UInt8(ascii: "d") else {
            throw TorBoxError.api("That link didn't give a .torrent file (HTTP \(status)).")
        }
        return data
    }

    private func applyResolved(_ id: UUID, _ links: [ResolvedLink]) {
        guard let first = links.first, let item = items.first(where: { $0.id == id }) else { return }
        let origin = item.sourceURL ?? item.url
        mutate(id, persist: false) {
            $0.url = first.url
            $0.fileName = Self.cleanName(first.fileName ?? first.url.lastPathComponent)
            $0.preferredName = first.fileName.map { Self.cleanName($0) }
            $0.headers = first.headers
            $0.sourceURL = origin
            $0.state = .queued
            $0.needsResolve = nil
            $0.status = nil
            $0.error = nil
        }
        for link in links.dropFirst() {
            var extra = DownloadItem(url: link.url, fileName: Self.cleanName(link.fileName ?? link.url.lastPathComponent))
            extra.headers = link.headers
            extra.preferredName = link.fileName.map { Self.cleanName($0) }
            extra.sourceURL = origin
            extra.addedAt = Date()
            items.append(extra)
        }
        save()
        startNext()
    }

    // MARK: TorBox

    /// One loop checks every link TorBox is still fetching, so API use stays low.
    /// `restart` cuts the loop's wait short, so a link that was just added is checked at once.
    private func startTorBoxPolling(restart: Bool = false) {
        if restart { pollSoon = true }
        guard torboxPoller == nil else { return }
        torboxPoller = Task {
            await self.pollTorBox()
            self.torboxPoller = nil
        }
    }

    private func pollTorBox() async {
        var delay: Double = 1
        var strikes: [UUID: Int] = [:]
        while true {
            pollSoon = false
            let waiting = items.filter { $0.state == .resolving && $0.torboxId != nil && $0.torboxFileId == nil }
            if waiting.isEmpty { return }
            // With several links of a kind waiting, one request gets the status of all of them.
            var batches: [TorBoxKind: [Int: TorBoxWebDownload]] = [:]
            for kind in [TorBoxKind.web, .torrent] where waiting.filter({ ($0.torboxKind ?? .web) == kind }).count > 1 {
                if let list = try? await TorBox.shared.statusList(kind) { batches[kind] = list }
            }
            for item in waiting {
                guard let webId = item.torboxId, isResolving(item.id) else { continue }
                let kind = item.torboxKind ?? .web
                var askedAPI = false
                do {
                    let dl: TorBoxWebDownload
                    if let known = batches[kind]?[webId] {
                        dl = known
                    } else {
                        askedAPI = true
                        dl = try await TorBox.shared.status(kind, id: webId)
                    }
                    strikes[item.id] = nil
                    if isResolving(item.id) {   // not paused or removed meanwhile
                        if let failure = dl.failure {
                            mutate(item.id) { $0.torboxId = nil; $0.cloudProgress = nil }   // retry adds it again
                            await serviceFailed(item.id, .torbox, "TorBox: " + failure)
                        } else if dl.ready {
                            torboxReady(item.id, webId: webId, download: dl)
                        } else {
                            mutate(item.id, persist: false) {
                                $0.status = dl.statusText
                                $0.cloudProgress = dl.fraction
                            }
                        }
                    }
                } catch TorBoxError.gone {
                    mutate(item.id) { $0.torboxId = nil; $0.cloudProgress = nil }
                    await serviceFailed(item.id, .torbox, "TorBox: " + (TorBoxError.gone.errorDescription ?? "download gone"))
                } catch is URLError {
                    let n = (strikes[item.id] ?? 0) + 1
                    strikes[item.id] = n
                    if n >= 6 {
                        failResolve(item.id, "TorBox: can't connect.", retryable: true)
                    } else {
                        setStatus(item.id, "TorBox: connection problem, retrying…")
                    }
                } catch {
                    failResolve(item.id, "TorBox: " + error.localizedDescription)
                }
                if askedAPI { try? await Task.sleep(nanoseconds: 250_000_000) }   // TorBox limits API requests
            }
            // Wait before the next round: 1 s, then a little longer each time, up to 8 s.
            // A newly added link cuts the wait short.
            var waited: Double = 0
            while waited < delay, !pollSoon {
                try? await Task.sleep(nanoseconds: 250_000_000)
                waited += 0.25
            }
            delay = pollSoon ? 1 : min(delay * 1.5, 8)
        }
    }

    /// TorBox has every file. A torrent with several files waits for you to pick which ones
    /// (unless that's switched off in Settings); otherwise they all start downloading.
    private func torboxReady(_ id: UUID, webId: Int, download dl: TorBoxWebDownload) {
        guard !dl.files.isEmpty, let item = items.first(where: { $0.id == id }) else { return }
        let name = Self.cleanName(dl.name.isEmpty ? item.fileName : dl.name)
        if (item.torboxKind ?? .web) == .torrent, dl.files.count > 1, AppSettings.shared.askTorrentFiles {
            mutate(id) {
                $0.state = .choosing
                $0.choices = dl.files
                $0.fileName = name
                $0.groupName = name
                $0.bytesTotal = dl.files.reduce(Int64(0)) { $0 + max($1.size ?? 0, 0) }
                $0.status = nil
                $0.error = nil
                $0.cloudProgress = nil
            }
            if let waiting = items.first(where: { $0.id == id }) { Notifier.shared.chooseFiles(waiting) }
            return
        }
        startFiles(id, source: .torbox(webId), files: dl.files, torrentFileCount: dl.files.count, torrentName: name)
    }

    /// Downloads the files you picked from a torrent that was waiting for you.
    func chooseFiles(_ id: UUID, fileIDs: Set<Int>) {
        guard let item = items.first(where: { $0.id == id }), item.state == .choosing,
              let all = item.choices else { return }
        let source: CloudSource
        if let webId = item.torboxId {
            source = .torbox(webId)
        } else if let requestId = item.offcloudId {
            source = .offcloud(requestId)
        } else {
            return
        }
        let picked = all.filter { fileIDs.contains($0.id) }
        guard !picked.isEmpty else { return }
        startFiles(id, source: source, files: picked, torrentFileCount: all.count,
                   torrentName: item.groupName ?? item.fileName)
    }

    /// Where a finished cloud download's files come from.
    private enum CloudSource {
        case torbox(Int)        // TorBox download or torrent ID: files use TorBox's permanent links
        case offcloud(String)   // Offcloud request ID: each file has a link of its own
    }

    /// Turns a download TorBox or Offcloud has finished into one download per file. The first
    /// file keeps the original entry. Files of a torrent with several files go into the
    /// torrent's own folder, laid out as in the torrent, and show as one group in the list.
    private func startFiles(_ id: UUID, source: CloudSource, files: [TorBoxFile], torrentFileCount: Int, torrentName: String) {
        guard let first = files.first, let item = items.first(where: { $0.id == id }) else { return }
        let origin = item.sourceURL ?? item.url
        let several = torrentFileCount > 1
        let group: UUID? = files.count > 1 ? UUID() : nil
        let groupName: String? = several ? Self.cleanName(torrentName) : nil
        func folder(of file: TorBoxFile) -> String? {
            several ? Self.torrentFolder(torrent: torrentName, file: file.path ?? file.name) : nil
        }
        mutate(id, persist: false) {
            switch source {
            case .torbox:
                $0.torboxFileId = first.id
            case .offcloud(let requestId):
                $0.offcloudId = requestId
                $0.offcloudFile = true
                $0.viaOffcloud = true
                if let link = first.link { $0.url = link }
            }
            $0.triedServices = nil
            $0.askOffcloud = nil
            $0.fileName = Self.cleanName(first.name)
            $0.preferredName = Self.cleanName(first.name)
            $0.sourceURL = origin
            $0.bytesTotal = max(first.size ?? 0, 0)
            $0.cloudProgress = nil
            $0.state = .queued
            $0.needsResolve = nil
            $0.status = nil
            $0.error = nil
            $0.choices = nil
            $0.groupID = group
            $0.groupName = groupName
            $0.folder = folder(of: first)
        }
        for file in files.dropFirst() {
            var extra = DownloadItem(url: file.link ?? origin, fileName: Self.cleanName(file.name))
            extra.preferredName = Self.cleanName(file.name)
            extra.sourceURL = origin
            switch source {
            case .torbox(let webId):
                extra.torboxId = webId
                extra.torboxFileId = file.id
            case .offcloud(let requestId):
                extra.offcloudId = requestId
                extra.offcloudFile = true
                extra.viaOffcloud = true
            }
            extra.torboxKind = item.torboxKind
            extra.bytesTotal = max(file.size ?? 0, 0)
            extra.addedAt = item.addedAt ?? Date()   // same as the torrent, so its files stay together
            extra.groupID = group
            extra.groupName = groupName
            extra.folder = folder(of: file)
            items.append(extra)
        }
        save()
        startNext()
    }

    /// Downloads files that are already in your TorBox account (the TorBox Cloud screen).
    /// Files already in the list and not finished are skipped. Returns how many were added.
    @discardableResult
    func addFromTorBox(_ entry: TorBoxCloudItem, files: [TorBoxFile]) -> Int {
        let origin = Self.cloudLink(entry)
        let several = entry.files.count > 1
        let fresh = files.filter { file in
            !items.contains {
                $0.torboxId == entry.torboxID && ($0.torboxKind ?? .web) == entry.kind
                    && $0.torboxFileId == file.id && $0.state != .completed
            }
        }
        let group: UUID? = fresh.count > 1 ? UUID() : nil
        let now = Date()
        for file in fresh {
            var item = DownloadItem(url: origin, fileName: Self.cleanName(file.name))
            item.preferredName = Self.cleanName(file.name)
            item.sourceURL = origin
            item.torboxId = entry.torboxID
            item.torboxKind = entry.kind
            item.torboxFileId = file.id
            item.bytesTotal = max(file.size ?? 0, 0)
            item.addedAt = now
            item.groupID = group
            item.groupName = several ? Self.cleanName(entry.name) : nil
            item.folder = several ? Self.torrentFolder(torrent: entry.name, file: file.path ?? file.name) : nil
            items.append(item)
        }
        if !fresh.isEmpty {
            save()
            Notifier.shared.askPermissionIfNeeded()
            startNext()
        }
        return fresh.count
    }

    /// The link a TorBox Cloud download is listed with: a magnet link for a torrent, else TorBox itself.
    nonisolated static func cloudLink(_ entry: TorBoxCloudItem) -> URL {
        if entry.kind == .torrent, let hash = entry.infoHash, let magnet = URL(string: "magnet:?xt=urn:btih:" + hash) {
            return magnet
        }
        return URL(string: "https://torbox.app/dashboard")!
    }

    /// With "Remove From TorBox When Done" on: once every file of a TorBox download is
    /// downloaded, delete it from the TorBox account.
    private func removeFromTorBoxIfDone(_ item: DownloadItem) {
        guard AppSettings.shared.removeFromTorBox, let webId = item.torboxId else { return }
        let kind = item.torboxKind ?? .web
        let unfinished = items.contains {
            $0.torboxId == webId && ($0.torboxKind ?? .web) == kind && $0.state != .completed
        }
        guard !unfinished else { return }
        Task { try? await TorBox.shared.remove(kind, id: webId) }
    }

    // MARK: Offcloud

    /// Links and torrents Offcloud is still fetching to its cloud.
    private var waitingForOffcloud: [DownloadItem] {
        items.filter { $0.state == .resolving && $0.offcloudId != nil && $0.offcloudFile != true }
    }

    /// One loop checks everything Offcloud is fetching. `restart` checks a new one at once.
    private func startOffcloudPolling(restart: Bool = false) {
        if restart { offcloudPollSoon = true }
        guard offcloudPoller == nil else { return }
        offcloudPoller = Task {
            await self.pollOffcloud()
            self.offcloudPoller = nil
        }
    }

    private func pollOffcloud() async {
        var delay: Double = 2
        var strikes: [UUID: Int] = [:]
        while true {
            offcloudPollSoon = false
            let waiting = waitingForOffcloud
            if waiting.isEmpty { return }
            for item in waiting {
                guard let requestId = item.offcloudId, isResolving(item.id) else { continue }
                do {
                    let status = try await Offcloud.shared.cloudStatus(requestId)
                    strikes[item.id] = nil
                    guard isResolving(item.id) else { continue }   // paused or removed meanwhile
                    if let failure = status.failure {
                        mutate(item.id) { $0.offcloudId = nil; $0.cloudProgress = nil }   // retry adds it again
                        await serviceFailed(item.id, .offcloud, "Offcloud: " + failure)
                    } else if status.ready {
                        await offcloudReady(item.id, requestId: requestId, status: status)
                    } else {
                        mutate(item.id, persist: false) {
                            $0.status = status.statusText
                            $0.cloudProgress = status.fraction
                        }
                    }
                } catch OffcloudError.gone {
                    mutate(item.id) { $0.offcloudId = nil; $0.cloudProgress = nil }
                    await serviceFailed(item.id, .offcloud, Self.offcloudText(OffcloudError.gone))
                } catch let error where Self.passing(error) {
                    let n = (strikes[item.id] ?? 0) + 1
                    strikes[item.id] = n
                    if n >= 6 {
                        failResolve(item.id, "Offcloud: can't connect.", retryable: true)
                    } else {
                        setStatus(item.id, "Offcloud: connection problem, retrying…")
                    }
                } catch {
                    failResolve(item.id, Self.offcloudText(error))
                }
            }
            // Wait 2 s, then a little longer each round, up to 10 s. A new one cuts it short.
            var waited: Double = 0
            while waited < delay, !offcloudPollSoon {
                try? await Task.sleep(nanoseconds: 250_000_000)
                waited += 0.25
            }
            delay = offcloudPollSoon ? 2 : min(delay * 1.5, 10)
        }
    }

    /// Offcloud has it all: get each file's link, then download them. A torrent with several
    /// files waits for you to pick which ones, as with TorBox.
    private func offcloudReady(_ id: UUID, requestId: String, status: OffcloudStatus) async {
        let files: [TorBoxFile]
        do {
            files = try await Offcloud.shared.cloudFiles(requestId, status: status)
        } catch let error where Self.passing(error) {
            setStatus(id, "Offcloud: connection problem, retrying…")   // the poller asks again
            return
        } catch {
            guard isResolving(id) else { return }
            mutate(id) { $0.offcloudId = nil; $0.cloudProgress = nil }
            await serviceFailed(id, .offcloud, Self.offcloudText(error))
            return
        }
        guard isResolving(id), let item = items.first(where: { $0.id == id }), !files.isEmpty else { return }
        let name = Self.cleanName(status.fileName.isEmpty ? item.fileName : status.fileName)
        if item.torboxKind == .torrent, files.count > 1, AppSettings.shared.askTorrentFiles {
            mutate(id) {
                $0.state = .choosing
                $0.choices = files
                $0.fileName = name
                $0.groupName = name
                $0.bytesTotal = files.reduce(Int64(0)) { $0 + max($1.size ?? 0, 0) }
                $0.status = nil
                $0.error = nil
                $0.cloudProgress = nil
            }
            if let waiting = items.first(where: { $0.id == id }) { Notifier.shared.chooseFiles(waiting) }
            return
        }
        startFiles(id, source: .offcloud(requestId), files: files, torrentFileCount: files.count, torrentName: name)
    }

    private func isResolving(_ id: UUID) -> Bool {
        items.first(where: { $0.id == id })?.state == .resolving
    }

    private func setStatus(_ id: UUID, _ text: String) {
        mutate(id, persist: false) { $0.status = text }
    }

    private func failResolve(_ id: UUID, _ message: String, retryable: Bool = false) {
        guard isResolving(id) else { return }   // paused or removed meanwhile
        mutate(id) { $0.state = .failed; $0.error = message; $0.status = nil }
        if !(retryable && planAutoRetry(id)) { notifyFailed(id) }
    }

    // MARK: Queue

    private var startingNext = false
    private var startNextAgain = false

    private func startNext() {
        if let wait = networkWait {
            // The network setting doesn't allow downloads right now: they wait.
            for i in items.indices where items[i].state == .queued && items[i].status != wait {
                items[i].status = wait
            }
            return
        }
        // Starting a download can finish another (and call this again): go round again then.
        if startingNext {
            startNextAgain = true
            return
        }
        startingNext = true
        defer { startingNext = false }
        repeat {
            startNextAgain = false
            var active = items.filter { $0.state == .downloading }.count
            for i in items.indices where active < maxConcurrent && items[i].state == .queued {
                if begin(at: i) { active += 1 }
            }
        } while startNextAgain
    }

    // MARK: Network setting

    /// Why downloads have to wait under the network setting right now, or nil if they can run.
    private var networkWait: String? {
        NetworkMonitor.shared.waitReason(for: AppSettings.shared.networkMode)
    }

    /// The network changed, or the network setting did.
    func networkChanged() {
        if let wait = networkWait {
            // Hold every running download until the right network is back. They carry on
            // from where they stopped.
            for item in items where item.state == .downloading { hold(item.id, reason: wait) }
            for i in items.indices where items[i].state == .queued { items[i].status = wait }
            save()
            if UIApplication.shared.applicationState == .background, !BackgroundKeeper.shared.isRunning {
                startHeldInBackground()
            }
        } else {
            for i in items.indices where items[i].state == .queued && (items[i].status ?? "").hasPrefix("Waiting for") {
                items[i].status = nil
            }
            startNext()
            save()
            runDueRetries()
        }
    }

    // MARK: Trying again by itself

    /// After a download failed because the connection dropped (or the server was busy), it
    /// tries again by itself: after 10 s, then 30 s, 1, 2 and 5 minutes. The count starts over
    /// whenever it got further. Returns false if it won't try again.
    @discardableResult
    private func planAutoRetry(_ id: UUID) -> Bool {
        guard AppSettings.shared.autoRetry, let i = index(of: id), items[i].state == .failed else { return false }
        var tries = items[i].autoRetries ?? 0
        if let mark = items[i].retryMark, items[i].bytesReceived > mark { tries = 0 }   // it got further
        guard tries < Self.retryDelays.count else {
            items[i].retryAt = nil
            save()
            return false
        }
        items[i].autoRetries = tries + 1
        items[i].retryMark = items[i].bytesReceived
        items[i].retryAt = Date().addingTimeInterval(Self.retryDelays[tries])
        save()
        scheduleRetryCheck()
        return true
    }

    /// Starts the tries that are due, if there's a network downloads may use.
    private func runDueRetries() {
        if NetworkMonitor.shared.connected, networkWait == nil {
            let now = Date()
            let due = items.filter { item in
                item.state == .failed && (item.retryAt.map { $0 <= now } ?? false)
            }.map { $0.id }
            for id in due { resume(id, automatic: true) }
        }
        scheduleRetryCheck()
    }

    /// Wakes up for the next try that's due. (Tries that are due while there's no network
    /// start when it comes back: see `networkChanged`.)
    private func scheduleRetryCheck() {
        retryTimer?.cancel()
        retryTimer = nil
        let now = Date()
        guard let next = items.compactMap({ $0.state == .failed ? $0.retryAt : nil }).filter({ $0 > now }).min() else { return }
        let wait = next.timeIntervalSince(now) + 0.5
        retryTimer = Task {
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.retryTimer = nil
            self.runDueRetries()
        }
    }

    private var waitingToRetry: Bool {
        items.contains { $0.state == .failed && $0.retryAt != nil }
    }

    /// Stops a download for now (not paused by you): it's queued again with a note why.
    private func hold(_ id: UUID, reason: String) {
        turboStop(id)
        bgLive[id] = nil
        refreshProgress(id)
        mutate(id, persist: false) {
            $0.state = .queued
            $0.status = reason
        }
        clearTransfer(id)
        Task { await stopTransfers(for: id) }
    }

    /// With Wi-Fi Only, downloads waiting for Wi-Fi can be handed to iOS's background
    /// downloader before JDLite goes to sleep: it starts them by itself once Wi-Fi is back.
    private func startHeldInBackground() {
        guard AppSettings.shared.networkMode == .wifiOnly, !inApp else { return }
        var active = items.filter { $0.state == .downloading }.count
        for i in items.indices where active < maxConcurrent && items[i].state == .queued {
            if begin(at: i) { active += 1 }
        }
    }

    /// The request for the file itself (TorBox downloads use TorBox's permanent link).
    private func downloadRequest(for item: DownloadItem) -> URLRequest? {
        var target = item.url
        if let webId = item.torboxId, let fileId = item.torboxFileId {
            guard let link = TorBox.shared.permalink(item.torboxKind ?? .web, id: webId, fileId: fileId) else { return nil }
            target = link
        }
        var req = URLRequest(url: target)
        // Wi-Fi Only also stops iOS's background downloader from using mobile data.
        req.allowsCellularAccess = AppSettings.shared.networkMode != .wifiOnly
        for (k, v) in item.headers ?? [:] { req.setValue(v, forHTTPHeaderField: k) }
        if req.value(forHTTPHeaderField: "Accept-Encoding") == nil {
            req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")   // byte ranges need the file as it is
        }
        return req
    }

    /// Like `downloadRequest`, but straight to where the first reply came from, which skips
    /// redirects (and TorBox's API) for every further connection.
    private func transferRequest(for item: DownloadItem) -> URLRequest? {
        guard var req = downloadRequest(for: item) else { return nil }
        if let direct = directURLs[item.id] { req.url = direct }
        return req
    }

    /// Starts or continues a queued download. Returns false if it couldn't start.
    @discardableResult
    private func begin(at i: Int) -> Bool {
        let id = items[i].id
        guard let request = downloadRequest(for: items[i]) else {
            items[i].state = .failed
            items[i].error = TorBoxError.noKey.errorDescription
            save()
            return false
        }
        clearTransfer(id)
        items[i].state = .downloading
        items[i].error = nil
        items[i].status = nil

        if items[i].segments != nil, items[i].singleConnection == true {
            // This server can't send part of a file, so the download starts again.
            try? FileManager.default.removeItem(at: Self.partsDir(id))
            items[i].segments = nil
            items[i].bytesReceived = 0
        }
        if items[i].segments != nil {
            drive(i)   // carry on with every part that isn't done yet
            return true
        }
        let item = items[i]
        if inApp {
            if item.resumeData != nil, item.bytesReceived >= Self.reclaimLimit {
                // A background download that got a good way: let it finish where it is.
                startWhole(item, request: request)
            } else {
                startFresh(at: i, request: request)
            }
        } else if item.resumeData == nil, item.singleConnection != true {
            items[i].status = "Connecting…"
            Task { await self.backgroundSplit(id, request: request) }
        } else {
            startWhole(item, request: request)
        }
        items[i].resumeData = nil
        save()
        return true
    }

    /// A whole file in one background transfer (for servers that can't send parts).
    private func startWhole(_ item: DownloadItem, request: URLRequest) {
        let task: URLSessionDownloadTask
        if let data = item.resumeData {
            task = lanes[0].downloadTask(withResumeData: data)
        } else {
            task = lanes[0].downloadTask(with: request)
        }
        task.taskDescription = Self.describe(item.id, name: item.preferredName, part: nil, length: nil)
        task.resume()
    }

    // MARK: In-app connections

    /// Starts a new download over one in-app connection. The server's first reply says how
    /// big the file is; the download is then shared out over more connections.
    private func startFresh(at i: Int, request: URLRequest) {
        let id = items[i].id
        turboStop(id)
        try? FileManager.default.removeItem(at: Self.partsDir(id))
        items[i].segments = nil
        items[i].layout = 2
        items[i].bytesReceived = 0
        items[i].status = "Connecting…"
        directURLs[id] = nil
        jsonReplies.remove(id)
        spawnWorker(id, part: 0, from: 0, end: TurboWorker.unknownEnd, request: request, reply: true)
    }

    private func spawnWorker(_ id: UUID, part: Int64, from: Int64, end: Int64, request: URLRequest,
                             reply: Bool = false) {
        let worker = TurboWorker(downloadID: id, fileURL: Self.dataURL(id))
        workers[id, default: []].append(worker)
        worker.start(part: part, from: from, end: end, request: request, reportReply: reply)
        ensureProgressLoop()
    }

    /// The first reply of a new download: learn its size and name, then split it up.
    func turboReply(_ worker: TurboWorker, _ reply: TurboReply) {
        let id = worker.downloadID
        guard isCurrent(worker), let i = index(of: id), items[i].state == .downloading,
              items[i].segments == nil else { return }
        items[i].status = nil
        if let url = reply.finalURL { directURLs[id] = url }
        if reply.isJSON { jsonReplies.insert(id) }
        if items[i].preferredName == nil, let name = reply.suggestedName, !name.isEmpty {
            // Use the server's name if it gave one, or if the link didn't look like a file name.
            let current = items[i].fileName as NSString
            if reply.namedByServer || current.pathExtension.isEmpty {
                items[i].preferredName = Self.cleanName(name)
                items[i].fileName = Self.cleanName(name)
            }
        }
        items[i].bytesTotal = max(reply.total ?? 0, 0)
        items[i].layout = 2
        // Without byte ranges and a known size, a file can't be split or picked up part-way.
        let canSplit = reply.acceptsRanges && reply.total != nil && items[i].singleConnection != true
        if !canSplit { items[i].singleConnection = true }
        let last = reply.total.map { $0 - 1 } ?? TurboWorker.unknownEnd
        items[i].segments = [Segment(start: 0, end: last)]
        if canSplit, let total = reply.total, total > 0 {
            splitEvenly(at: i, worker: worker, total: total)
        }
        save()
    }

    /// Shares a new download out over several connections in equal parts.
    private func splitEvenly(at i: Int, worker: TurboWorker, total: Int64) {
        let id = items[i].id
        let n = Int(min(Int64(connectionLimit(for: id)), max(1, total / Self.minPartSize)))
        guard n >= 2, let request = transferRequest(for: items[i]) else { return }
        let size = total / Int64(n)
        guard worker.shrink(toEnd: size - 1) else {
            // Already past that point: share out what's left (if it's still going at all;
            // a small file may have finished already).
            if worker.currentPart != nil { fillConnections(at: i) }
            return
        }
        var segs: [Segment] = []
        for k in 0..<n {
            let start = Int64(k) * size
            let end = k == n - 1 ? total - 1 : start + size - 1
            segs.append(Segment(start: start, end: end))
        }
        items[i].segments = segs
        for s in segs.dropFirst() {
            spawnWorker(id, part: s.start, from: s.start, end: s.end, request: request)
        }
    }

    /// Adds in-app connections until the download uses as many as it's allowed.
    private func fillConnections(at i: Int) {
        guard inApp, networkWait == nil, items[i].state == .downloading, items[i].segments != nil,
              let request = transferRequest(for: items[i]) else { return }
        let id = items[i].id
        let single = items[i].singleConnection == true
        let limit = single ? 1 : connectionLimit(for: id)
        var added = 0
        while connectionsInUse(id) < limit, added < 32, let job = nextJob(at: i, steal: !single) {
            spawnWorker(id, part: job.part, from: job.from, end: job.end, request: request)
            added += 1
        }
    }

    /// The next stretch of a download for a free connection: a part nobody is working on,
    /// or else the second half of what the busiest connection still has to fetch.
    private func nextJob(at i: Int, steal: Bool) -> (part: Int64, from: Int64, end: Int64)? {
        guard var segs = items[i].segments else { return nil }
        let id = items[i].id
        let taken = busyParts(id).union(bgLive[id] ?? [])
        if let s = segs.first(where: { !$0.done && $0.background != true && $0.end != TurboWorker.unknownEnd
                                        && !taken.contains($0.start) && $0.received < $0.length }) {
            return (part: s.start, from: s.start + s.received, end: s.end)
        }
        guard steal else { return nil }
        var victim: TurboWorker?
        var most: Int64 = 0
        for worker in workers[id] ?? [] {
            if let left = worker.bytesLeft, left > most {
                victim = worker
                most = left
            }
        }
        guard let victim, most >= Self.minStealSize * 2,
              let cut = victim.giveAwayHalf(minimum: Self.minStealSize) else { return nil }
        if let k = segs.firstIndex(where: { $0.start == cut.part }) { segs[k].end = cut.start - 1 }
        segs.append(Segment(start: cut.start, end: cut.end))
        segs.sort { $0.start < $1.start }
        items[i].segments = segs
        return (part: cut.start, from: cut.start, end: cut.end)
    }

    /// A connection finished a stretch of work (or failed at it).
    func turboDone(_ worker: TurboWorker, part: Int64, outcome: TurboOutcome, position: Int64, end: Int64) {
        let id = worker.downloadID
        guard isCurrent(worker) else { return }   // stopped meanwhile
        guard let i = index(of: id), items[i].state == .downloading else {
            retire(worker)
            return
        }
        switch outcome {
        case .finished:
            if items[i].segments == nil {
                // A small file that arrived before its first reply was handled.
                items[i].segments = [Segment(start: 0, end: position - 1)]
                items[i].bytesTotal = position
                items[i].layout = 2
            }
            if var segs = items[i].segments, let k = segs.firstIndex(where: { $0.start == part }) {
                if segs[k].end == TurboWorker.unknownEnd {
                    segs[k].end = position - 1
                    items[i].bytesTotal = position
                }
                segs[k].received = segs[k].length
                segs[k].done = true
                items[i].segments = segs
            }
            attempts[Self.partKey(id, part)] = nil
            refreshProgress(at: i)
            continueWork(worker, at: i)
        case .incomplete:
            recordProgress(at: i, part: part, position: position)
            if let delay = nextAttempt(id, part: part, position: position) {
                retry(worker, after: delay)
            } else {
                retire(worker)
                failDownload(id, message: "The server keeps dropping the connection.", retryable: true)
            }
        case .failed(let message, let retryable):
            recordProgress(at: i, part: part, position: position)
            if retryable, let delay = nextAttempt(id, part: part, position: position) {
                retry(worker, after: delay)
            } else {
                retire(worker)
                failDownload(id, message: message, retryable: retryable)
            }
        case .http(let status, let message):
            recordProgress(at: i, part: part, position: position)
            httpTrouble(worker, at: i, part: part, position: position, status: status, message: message)
        case .webPage:
            retire(worker)
            gotWebPage(id)
        case .rangesIgnored:
            retire(worker)
            fallBackToWhole(at: i)
        }
    }

    private func httpTrouble(_ worker: TurboWorker, at i: Int, part: Int64, position: Int64,
                             status: Int, message: String?) {
        let id = items[i].id
        let others = (workers[id]?.count ?? 1) - 1
        if status == 429 || status == 503, others > 0 {
            // The server limits how many connections it allows: carry on with fewer.
            workerLimit[id] = max(1, others)
            retire(worker)
            return
        }
        if [401, 403, 404, 410].contains(status), directURLs[id] != nil {
            // The direct link may have expired: go through the original link again.
            directURLs[id] = nil
            if let delay = nextAttempt(id, part: part, position: position) {
                retry(worker, after: delay)
                return
            }
        }
        if status == 429 || status >= 500, let delay = nextAttempt(id, part: part, position: position) {
            retry(worker, after: max(delay, 2))
            return
        }
        retire(worker)
        let text = message.map { "HTTP \(status): \($0)" } ?? "HTTP \(status)"
        failDownload(id, message: text, resolveAgain: true, retryable: status == 429 || status >= 500)
    }

    /// Gives a connection that finished its job something else to do, or lets it go.
    private func continueWork(_ worker: TurboWorker, at i: Int) {
        let id = items[i].id
        normalize(at: i)
        if items[i].segments?.allSatisfy({ $0.done }) == true {
            completeFile(at: i)
            return
        }
        let single = items[i].singleConnection == true
        let limit = single ? 1 : connectionLimit(for: id)
        if inApp, networkWait == nil, connectionsInUse(id) <= limit,
           let job = nextJob(at: i, steal: !single),
           let request = transferRequest(for: items[i]) {
            worker.start(part: job.part, from: job.from, end: job.end, request: request)
        } else {
            retire(worker)
        }
        save()
    }

    /// Tries a connection's work again after a pause.
    private func retry(_ worker: TurboWorker, after delay: Double) {
        let id = worker.downloadID
        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard self.isCurrent(worker), let i = self.index(of: id),
                  self.items[i].state == .downloading else { return }
            if self.items[i].segments == nil || self.items[i].singleConnection == true {
                // Nothing to carry on from: start the download again.
                self.retire(worker)
                if let request = self.downloadRequest(for: self.items[i]) {
                    self.startFresh(at: i, request: request)
                }
                self.save()
            } else {
                self.continueWork(worker, at: i)
            }
        }
    }

    /// Counts tries at a part that make no progress. Returns how long to wait before the
    /// next try, or nil to give up.
    private func nextAttempt(_ id: UUID, part: Int64, position: Int64) -> Double? {
        let key = Self.partKey(id, part)
        var entry = attempts[key] ?? (count: 0, position: Int64.min)
        if position > entry.position { entry = (count: 0, position: position) }   // it got further: count again
        entry.count += 1
        attempts[key] = entry
        let delays: [Double] = [0.5, 1, 2, 4, 8, 15]
        return entry.count <= delays.count ? delays[entry.count - 1] : nil
    }

    private func clearAttempts(_ id: UUID) {
        let prefix = id.uuidString + "/"
        attempts = attempts.filter { !$0.key.hasPrefix(prefix) }
    }

    private func recordProgress(at i: Int, part: Int64, position: Int64) {
        guard var segs = items[i].segments, let k = segs.firstIndex(where: { $0.start == part }),
              !segs[k].done, segs[k].end != TurboWorker.unknownEnd else { return }
        segs[k].received = min(max(position - part, 0), segs[k].length)
        items[i].segments = segs
    }

    /// Stops a download's in-app connections, keeping what they've saved.
    private func turboStop(_ id: UUID) {
        guard let list = workers.removeValue(forKey: id) else { return }
        let i = index(of: id)
        for worker in list {
            guard let reached = worker.stop(), let i else { continue }
            recordProgress(at: i, part: reached.part, position: reached.position)
        }
    }

    private func retire(_ worker: TurboWorker) {
        worker.stop()
        let id = worker.downloadID
        workers[id]?.removeAll { $0 === worker }
        if workers[id]?.isEmpty == true { workers[id] = nil }
    }

    private func isCurrent(_ worker: TurboWorker) -> Bool {
        workers[worker.downloadID]?.contains { $0 === worker } == true
    }

    private func busyParts(_ id: UUID) -> Set<Int64> {
        Set((workers[id] ?? []).compactMap { $0.currentPart })
    }

    private func connectionsInUse(_ id: UUID) -> Int {
        (workers[id]?.count ?? 0) + (bgLive[id]?.count ?? 0)
    }

    private func connectionLimit(for id: UUID) -> Int {
        max(1, min(AppSettings.shared.connectionsPerDownload, workerLimit[id] ?? Int.max))
    }

    /// Marks parts whose bytes are all saved as done.
    private func normalize(at i: Int) {
        guard var segs = items[i].segments else { return }
        var changed = false
        for k in segs.indices where !segs[k].done && segs[k].background != true
            && segs[k].end != TurboWorker.unknownEnd && segs[k].received >= segs[k].length {
            segs[k].done = true
            segs[k].received = segs[k].length
            changed = true
        }
        if changed { items[i].segments = segs }
    }

    /// Every part is saved: move the finished file into Downloads.
    private func completeFile(at i: Int) {
        let id = items[i].id
        guard !delivering.contains(id) else { return }   // already being saved
        if let list = workers.removeValue(forKey: id) {
            for worker in list { worker.stop() }
        }
        guard let segs = items[i].segments, let lastByte = segs.map({ $0.end }).max() else { return }
        let total = max(lastByte + 1, 0)
        let data = Self.dataURL(id)
        ensureFileExists(data)
        if Self.fileSize(data) > total, let handle = try? FileHandle(forWritingTo: data) {
            try? handle.truncate(atOffset: UInt64(total))
            try? handle.close()
        }
        if jsonReplies.remove(id) != nil, let json = Self.smallJSON(at: data), (json["success"] as? Bool) == false {
            // The "file" was an error message from the server.
            try? FileManager.default.removeItem(at: Self.partsDir(id))
            items[i].segments = nil
            items[i].bytesReceived = 0
            downloadFailed(id, message: Self.message(in: json) ?? "The server returned an error.")
            return
        }
        deliver(id, file: data, name: Self.cleanName(items[i].preferredName ?? items[i].fileName))
    }

    /// Moves a finished file into JDLite's Downloads folder (into its torrent's folder, for a
    /// torrent's files), under a name that's free.
    private func deliver(_ id: UUID, file: URL, name: String) {
        guard !delivering.contains(id) else { return }
        delivering.insert(id)
        mutate(id, persist: false) { $0.status = "Saving…" }
        if UIApplication.shared.applicationState == .background { beginFinishUpTime() }
        let folder = items.first(where: { $0.id == id })?.folder
        Task {
            let result = await Self.saveFinished(file, name: name, folder: folder)
            self.delivering.remove(id)
            switch result {
            case .success(let saved):
                try? FileManager.default.removeItem(at: Self.partsDir(id))
                self.finished(id, saved: saved)
            case .failure(let error):
                self.mutate(id) {
                    $0.state = .failed
                    $0.status = nil
                    $0.error = "Couldn't save the file: " + error.localizedDescription
                }
                self.notifyFailed(id)
                self.startNext()
            }
        }
    }

    nonisolated static func saveFinished(_ file: URL, name: String, folder: String?) async -> Result<FinishedFile, Error> {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result<FinishedFile, Error>, Never>) in
            DownloadManager.fileQueue.async {
                continuation.resume(returning: Result { try DownloadManager.moveToDownloads(file, name: name, folder: folder) })
            }
        }
    }

    nonisolated private static func moveToDownloads(_ file: URL, name: String, folder: String?) throws -> FinishedFile {
        var dir = downloadsDir
        let sub = (folder ?? "").isEmpty ? nil : folder
        if let sub { dir = dir.appendingPathComponent(sub, isDirectory: true) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = uniqueURL(for: name, in: dir)
        try FileManager.default.moveItem(at: file, to: dest)
        let path = sub.map { $0 + "/" + dest.lastPathComponent } ?? dest.lastPathComponent
        return FinishedFile(url: dest, path: path, size: fileSize(dest))
    }

    /// Stops a download that keeps failing, keeping its progress so retry carries on.
    /// `retryable`: the connection or a busy server was to blame, so it tries again by itself.
    private func failDownload(_ id: UUID, message: String, resolveAgain: Bool = false, retryable: Bool = false) {
        turboStop(id)
        bgLive[id] = nil
        refreshProgress(id)
        mutate(id) {
            $0.state = .failed
            $0.error = message
            $0.status = nil
            // Links found by a plugin can expire, so look the page up again on retry.
            if resolveAgain, !$0.isCloudFile, let source = $0.sourceURL, source != $0.url {
                $0.needsResolve = true
            }
        }
        if !(retryable && planAutoRetry(id)) { notifyFailed(id) }
        clearTransfer(id)
        startNext()
        Task { await stopTransfers(for: id) }
    }

    // MARK: Keeping parts moving

    /// Keeps every unfinished part of a download moving: in-app connections while JDLite can
    /// use them, background transfers otherwise. Also saves parts that arrived in the background.
    private func drive(_ i: Int) {
        guard items[i].state == .downloading, items[i].segments != nil else { return }
        let id = items[i].id
        normalize(at: i)
        guard var segs = items[i].segments else { return }
        if segs.allSatisfy({ $0.done }) {
            if workers[id] == nil, (bgLive[id] ?? []).isEmpty { completeFile(at: i) }
            return
        }
        guard let request = transferRequest(for: items[i]) else {
            failDownload(id, message: TorBoxError.noKey.errorDescription ?? "Add your TorBox API key.")
            return
        }
        let live = bgLive[id] ?? []
        let busy = busyParts(id)
        var launch: [Int64] = []
        var ready: [Int64] = []
        for start in segs.map({ $0.start }) {
            guard let k = segs.firstIndex(where: { $0.start == start }) else { continue }
            let s = segs[k]
            if s.done || live.contains(start) || busy.contains(start)
                || absorbing.contains(Self.partKey(id, start)) { continue }
            if s.background == true, Self.partReady(id, s) {
                ready.append(start)
                continue
            }
            if inApp {
                guard s.background == true else { continue }   // fillConnections picks it up
                if s.resumeData != nil, s.received >= Self.reclaimLimit {
                    launch.append(start)   // got a good way in the background: let it finish there
                } else {
                    segs[k].background = nil
                    segs[k].received = 0
                    segs[k].resumeData = nil
                    try? FileManager.default.removeItem(at: Self.partURL(id, start))
                }
            } else if s.background == true {
                launch.append(start)
            } else if s.end == TurboWorker.unknownEnd {
                continue   // size unknown: handOff restarts these
            } else if s.received > 0 {
                // Keep what's saved; fetch the rest in the background.
                segs[k].end = s.start + s.received - 1
                segs[k].received = segs[k].length
                segs[k].done = true
                var rest = Segment(start: s.start + s.received, end: s.end)
                rest.background = true
                segs.append(rest)
                launch.append(rest.start)
            } else {
                segs[k].background = true
                launch.append(start)
            }
        }
        segs.sort { $0.start < $1.start }
        items[i].segments = segs
        for start in launch { launchBackground(at: i, part: start, request: request) }
        for start in ready { absorb(id, part: start) }
        if inApp { fillConnections(at: i) }
        save()
    }

    /// Starts a background transfer for one part.
    private func launchBackground(at i: Int, part start: Int64, request: URLRequest) {
        guard let k = items[i].segments?.firstIndex(where: { $0.start == start }),
              let seg = items[i].segments?[k] else { return }
        let id = items[i].id
        let lane = lanes[nextLane % lanes.count]
        nextLane += 1
        let task: URLSessionDownloadTask
        if let data = seg.resumeData {
            task = lane.downloadTask(withResumeData: data)
        } else {
            var req = request
            req.setValue("bytes=\(seg.start)-\(seg.end)", forHTTPHeaderField: "Range")
            task = lane.downloadTask(with: req)
            items[i].segments?[k].received = 0
            liveBytes[id]?[start] = nil
        }
        items[i].segments?[k].background = true
        items[i].segments?[k].resumeData = nil
        task.taskDescription = Self.describe(id, name: items[i].preferredName, part: start, length: seg.length)
        task.resume()
        bgLive[id, default: []].insert(start)
    }

    /// Moves a download from in-app connections to iOS's background downloader.
    private func handOff(_ id: UUID) {
        guard let i = index(of: id), items[i].state == .downloading else { return }
        let hadWorkers = workers[id] != nil
        turboStop(id)
        guard let segs = items[i].segments, items[i].singleConnection != true,
              !segs.contains(where: { $0.end == TurboWorker.unknownEnd }) else {
            // Nothing to carry on from (no reply yet, or a server that can't send parts):
            // start it again in the background.
            if hadWorkers { restartInBackground(at: i) }
            return
        }
        drive(i)
    }

    private func restartInBackground(at i: Int) {
        let id = items[i].id
        try? FileManager.default.removeItem(at: Self.partsDir(id))
        items[i].segments = nil
        items[i].bytesReceived = 0
        items[i].layout = nil
        guard let request = downloadRequest(for: items[i]) else { return }
        if items[i].singleConnection == true {
            startWhole(items[i], request: request)
        } else {
            items[i].status = "Connecting…"
            Task { await self.backgroundSplit(id, request: request) }
        }
        save()
    }

    // MARK: Background parts

    nonisolated private static let probeSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        return URLSession(configuration: cfg)
    }()

    /// Asks for just the first byte to learn the size and whether the server can send parts.
    nonisolated private static func probe(_ request: URLRequest) async -> Probe? {
        var req = request
        req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        do {
            let (stream, response) = try await probeSession.bytes(for: req)
            stream.task.cancel()   // never read the body
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            if (http.mimeType ?? "").lowercased().contains("html") { return nil }
            if http.statusCode == 206, let range = http.value(forHTTPHeaderField: "Content-Range"),
               let slash = range.lastIndex(of: "/"),
               let total = Int64(range[range.index(after: slash)...].trimmingCharacters(in: .whitespaces)) {
                return Probe(total: total, acceptsRanges: true)
            }
            return Probe(total: max(http.expectedContentLength, 0), acceptsRanges: false)
        } catch {
            return nil
        }
    }

    nonisolated static func makeSegments(total: Int64, parts: Int) -> [Segment] {
        let size = total / Int64(parts)
        return (0..<parts).map { k in
            let start = Int64(k) * size
            let end = k == parts - 1 ? total - 1 : start + size - 1
            return Segment(start: start, end: end)
        }
    }

    /// Starts a new download while JDLite is in the background: split into parts for iOS's
    /// background downloader if the server allows it, else one transfer for the whole file.
    private func backgroundSplit(_ id: UUID, request: URLRequest) async {
        probing.insert(id)
        defer { probing.remove(id) }
        if UIApplication.shared.applicationState == .background { beginFinishUpTime() }
        let probe = await Self.probe(request)
        guard let i = index(of: id), items[i].state == .downloading, items[i].segments == nil,
              workers[id] == nil else { return }   // paused, deleted or started meanwhile
        items[i].status = nil
        if inApp {
            startFresh(at: i, request: request)   // JDLite is open again: use in-app connections
            save()
            return
        }
        if let probe, probe.acceptsRanges, probe.total > 0 {
            let parts = Int(min(Int64(AppSettings.shared.connectionsPerDownload), max(1, probe.total / Self.minPartSize)))
            try? FileManager.default.removeItem(at: Self.partsDir(id))
            items[i].bytesTotal = probe.total
            items[i].layout = 2
            var segs = Self.makeSegments(total: probe.total, parts: max(parts, 1))
            for k in segs.indices { segs[k].background = true }
            items[i].segments = segs
            for s in segs { launchBackground(at: i, part: s.start, request: request) }
            save()
            return
        }
        if probe?.acceptsRanges == false { items[i].singleConnection = true }
        startWhole(items[i], request: request)
        save()
    }

    /// Running background transfers for these downloads, with the part each carries (nil = whole file).
    private func liveTasks(for ids: Set<UUID>) async -> [(task: URLSessionTask, part: Int64?)] {
        var out: [(task: URLSessionTask, part: Int64?)] = []
        for lane in lanes {
            for task in await lane.allTasks {
                if let tag = Self.parseDesc(task.taskDescription), !tag.outdated, ids.contains(tag.id) {
                    out.append((task: task, part: tag.part))
                }
            }
        }
        return out
    }

    /// Cancels a download's background transfers, keeping resume data so it can carry on later.
    private func stopTransfers(for id: UUID) async {
        for (task, part) in await liveTasks(for: [id]) {
            if let download = task as? URLSessionDownloadTask {
                let data = await download.cancelByProducingResumeData()
                keepResumeData(id, part: part, data: data)
            } else {
                task.cancel()
            }
        }
    }

    private func keepResumeData(_ id: UUID, part: Int64?, data: Data?) {
        guard let i = index(of: id), items[i].state == .paused || items[i].state == .failed || items[i].state == .queued else { return }
        if let part {
            guard let k = items[i].segments?.firstIndex(where: { $0.start == part }) else { return }
            items[i].segments?[k].resumeData = data
        } else {
            items[i].resumeData = data
        }
        save()
    }

    fileprivate func partFinished(_ id: UUID, part start: Int64, moved: Bool, ok: Bool, size: Int64, status: Int) {
        bgLive[id]?.remove(start)
        liveBytes[id]?[start] = nil
        let file = Self.partURL(id, start)
        guard let i = index(of: id) else {
            try? FileManager.default.removeItem(at: Self.partsDir(id))   // deleted meanwhile
            return
        }
        guard let k = items[i].segments?.firstIndex(where: { $0.start == start }),
              let seg = items[i].segments?[k], seg.background == true, !seg.done else {
            try? FileManager.default.removeItem(at: file)   // no longer needed
            return
        }
        guard moved, ok, size >= seg.length else {
            try? FileManager.default.removeItem(at: file)
            if status == 200 {
                if items[i].state == .downloading { fallBackToWhole(at: i) }   // the server ignored the range
                return
            }
            partFailed(id, part: start, message: "Part of the file came back incomplete.", resumeData: nil)
            return
        }
        if size > seg.length, let handle = try? FileHandle(forWritingTo: file) {
            // The server sent more than asked for; the first `length` bytes are this part.
            try? handle.truncate(atOffset: UInt64(seg.length))
            try? handle.close()
        }
        items[i].segments?[k].received = seg.length
        items[i].segments?[k].resumeData = nil
        save()
        absorb(id, part: start)
    }

    /// Copies a part that arrived in the background into the download's data file.
    private func absorb(_ id: UUID, part start: Int64) {
        let key = Self.partKey(id, start)
        guard !absorbing.contains(key), let i = index(of: id),
              let seg = items[i].segments?.first(where: { $0.start == start }) else { return }
        absorbing.insert(key)
        if UIApplication.shared.applicationState == .background { beginFinishUpTime() }
        let length = seg.length
        Task {
            let ok = await Self.absorbPart(id, start: start, length: length)
            self.absorbing.remove(key)
            self.partSaved(id, part: start, ok: ok)
        }
    }

    private func partSaved(_ id: UUID, part start: Int64, ok: Bool) {
        guard let i = index(of: id) else {
            try? FileManager.default.removeItem(at: Self.partsDir(id))   // deleted meanwhile
            return
        }
        guard let k = items[i].segments?.firstIndex(where: { $0.start == start }) else { return }
        guard ok else {
            if items[i].state == .downloading {
                failDownload(id, message: "Couldn't save part of the download. Check there's enough free space, then tap retry.")
            }
            return
        }
        items[i].segments?[k].done = true
        items[i].segments?[k].background = nil
        items[i].segments?[k].resumeData = nil
        if let length = items[i].segments?[k].length { items[i].segments?[k].received = length }
        refreshProgress(at: i)
        save()
        // Finishes the file once every part is in, or puts the free connection to work.
        if items[i].state == .downloading { drive(i) }
    }

    fileprivate func partFailed(_ id: UUID, part start: Int64, message: String, resumeData: Data?) {
        bgLive[id]?.remove(start)
        liveBytes[id]?[start] = nil
        guard let i = index(of: id), let k = items[i].segments?.firstIndex(where: { $0.start == start }) else { return }
        items[i].segments?[k].resumeData = resumeData
        guard items[i].state == .downloading else { save(); return }   // paused or failed already
        directURLs[id] = nil   // in case the direct link expired
        let retries = (items[i].segments?[k].retries ?? 0) + 1
        items[i].segments?[k].retries = retries
        save()
        if retries <= 3 {
            Task {
                try? await Task.sleep(nanoseconds: UInt64(retries) * 2_000_000_000)
                if let j = self.index(of: id), self.items[j].state == .downloading { self.drive(j) }
            }
        } else {
            failDownload(id, message: message, retryable: true)
        }
    }

    /// A background part isn't the byte range we asked for: fetch it again, or give up on
    /// splitting this file.
    fileprivate func partMismatch(_ id: UUID, part start: Int64, rangesIgnored: Bool) {
        bgLive[id]?.remove(start)
        liveBytes[id]?[start] = nil
        guard let i = index(of: id), items[i].state == .downloading,
              let k = items[i].segments?.firstIndex(where: { $0.start == start }) else { return }
        let retries = (items[i].segments?[k].retries ?? 0) + 1
        if rangesIgnored || retries > 2 {
            fallBackToWhole(at: i)
            return
        }
        items[i].segments?[k].retries = retries
        items[i].segments?[k].resumeData = nil
        items[i].segments?[k].received = 0
        save()
        drive(i)
    }

    /// The server won't send parts after all: download the file over one connection.
    private func fallBackToWhole(at i: Int) {
        let id = items[i].id
        turboStop(id)
        try? FileManager.default.removeItem(at: Self.partsDir(id))
        items[i].segments = nil
        items[i].singleConnection = true
        items[i].bytesReceived = 0
        items[i].layout = nil
        liveBytes[id] = nil
        bgLive[id] = nil
        clearTransfer(id)
        save()
        Task {
            for (task, part) in await self.liveTasks(for: [id]) where part != nil { task.cancel() }
            guard let j = self.index(of: id), self.items[j].state == .downloading,
                  self.items[j].segments == nil, self.workers[id] == nil,
                  let request = self.downloadRequest(for: self.items[j]) else { return }
            if self.inApp {
                self.startFresh(at: j, request: request)
            } else {
                self.startWhole(self.items[j], request: request)
            }
            self.save()
        }
    }

    // MARK: Leaving and coming back to the app

    private func observeAppState() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.appWillResignActive()
            }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.appDidEnterBackground()
            }
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.appDidBecomeActive()
            }
        })
        observers.append(center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.appMemoryWarning()
            }
        })
        observers.append(center.addObserver(forName: UIApplication.willTerminateNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.appWillTerminate()
            }
        })
    }

    private var waitingForTorBox: [DownloadItem] {
        items.filter { $0.state == .resolving && $0.torboxId != nil && $0.torboxFileId == nil }
    }

    /// Steps that need the app itself running for a moment (iOS's downloader handles background transfers).
    private var needsAppTime: Bool {
        !probing.isEmpty || !absorbing.isEmpty || !delivering.isEmpty
            || items.contains { $0.state == .resolving && $0.torboxId == nil && $0.offcloudId == nil }
    }

    /// Work that keeps JDLite awake in the background: in-app transfers, downloads waiting
    /// their turn, and links being looked up or fetched by TorBox.
    private var hasAwakeWork: Bool {
        let canStart = networkWait == nil
        return !workers.isEmpty || !absorbing.isEmpty || !delivering.isEmpty
            || items.contains { ($0.state == .queued && canStart) || $0.state == .resolving }
            || (canStart && NetworkMonitor.shared.connected && waitingToRetry)
    }

    private func appWillResignActive() {
        if AppSettings.shared.keepAwakeInBackground {
            // Start staying awake while JDLite is still in front, which iOS always allows.
            if hasAwakeWork { BackgroundKeeper.shared.start() }
        } else {
            // Hand downloads to iOS now, while it still starts them promptly.
            leaveApp()
        }
    }

    private func appDidEnterBackground() {
        if inApp {
            let stayAwake = AppSettings.shared.keepAwakeInBackground && hasAwakeWork && BackgroundKeeper.shared.start()
            if !stayAwake {
                BackgroundKeeper.shared.stop()
                leaveApp()
            }
        }
        beginFinishUpTime()
        if !BackgroundKeeper.shared.isRunning { scheduleTorBoxChecks() }
    }

    private func appDidBecomeActive() {
        BackgroundKeeper.shared.stop()
        endFinishUpTime()
        inApp = true
        Task { for task in await checks.allTasks { task.cancel() } }   // the in-app poller takes over
        if !waitingForTorBox.isEmpty { startTorBoxPolling() }
        if !waitingForOffcloud.isEmpty { startOffcloudPolling() }
        networkChanged()   // holds downloads if the network setting doesn't allow them, else starts the queue
        Task { await self.reclaim() }
    }

    private func appMemoryWarning() {
        // In the background this can mean iOS is about to close JDLite: let its own downloader take over.
        guard UIApplication.shared.applicationState == .background, BackgroundKeeper.shared.isRunning else { return }
        BackgroundKeeper.shared.stop()
        leaveApp()
        scheduleTorBoxChecks()
    }

    private func appWillTerminate() {
        for id in Array(workers.keys) { turboStop(id) }
        BackgroundKeeper.shared.stop()
        save()
    }

    /// Called when a phone call or another app's audio stops JDLite staying awake.
    func keeperInterrupted() {
        guard UIApplication.shared.applicationState == .background else { return }
        leaveApp()
        beginFinishUpTime()
        scheduleTorBoxChecks()
    }

    /// Hands every running download over to iOS's background downloader.
    private func leaveApp() {
        guard inApp else { return }
        inApp = false
        for item in items where item.state == .downloading { handOff(item.id) }
        if networkWait != nil { startHeldInBackground() }
        save()
    }

    /// Lets JDLite go to sleep once nothing needs it awake in the background.
    private func refreshKeepAwake() {
        guard BackgroundKeeper.shared.isRunning, UIApplication.shared.applicationState == .background,
              !hasAwakeWork else { return }
        BackgroundKeeper.shared.stop()
        leaveApp()
        scheduleTorBoxChecks()
    }

    private func scheduleKeepAwakeCheck() {
        guard keepAwakeCheck == nil, BackgroundKeeper.shared.isRunning else { return }
        keepAwakeCheck = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self.keepAwakeCheck = nil
            self.refreshKeepAwake()
        }
    }

    /// Back in the app: parts that background transfers had barely started on move to the
    /// faster in-app connections. Parts that got a good way finish in the background.
    private func reclaim() async {
        try? await Task.sleep(nanoseconds: 2_000_000_000)   // let fresh progress come in first
        guard inApp, networkWait == nil, UIApplication.shared.applicationState == .active else { return }
        let ids = Set(items.filter { $0.state == .downloading && !(bgLive[$0.id] ?? []).isEmpty }.map { $0.id })
        guard !ids.isEmpty else { return }
        var touched = Set<UUID>()
        for (task, part) in await liveTasks(for: ids) {
            guard let part, let tag = Self.parseDesc(task.taskDescription), let i = index(of: tag.id),
                  items[i].state == .downloading, items[i].singleConnection != true,
                  let k = items[i].segments?.firstIndex(where: { $0.start == part }) else { continue }
            let got = max(task.countOfBytesReceived, liveBytes[tag.id]?[part] ?? 0)
            guard got < Self.reclaimLimit else { continue }
            task.cancel()
            bgLive[tag.id]?.remove(part)
            liveBytes[tag.id]?[part] = nil
            items[i].segments?[k].background = nil
            items[i].segments?[k].received = 0
            items[i].segments?[k].resumeData = nil
            touched.insert(tag.id)
        }
        for id in touched {
            if let i = index(of: id) { drive(i) }
        }
        if !touched.isEmpty { save() }
    }

    /// Asks iOS for a little extra time so in-app steps can finish after you leave the app.
    private func beginFinishUpTime() {
        guard finishUp == .invalid, needsAppTime || !waitingForTorBox.isEmpty || !waitingForOffcloud.isEmpty else { return }
        finishUp = UIApplication.shared.beginBackgroundTask(withName: "Finish up") { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.endFinishUpTime()
            }
        }
        Task {
            repeat {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            } while self.finishUp != .invalid && self.needsAppTime
            self.endFinishUpTime()
        }
    }

    private func endFinishUpTime() {
        guard finishUp != .invalid else { return }
        UIApplication.shared.endBackgroundTask(finishUp)
        finishUp = .invalid
    }

    private func scheduleTorBoxChecks() {
        let waiting = waitingForTorBox
        guard !waiting.isEmpty else { return }
        Task {
            // Replace earlier checks, then let iOS run new ones on schedule while the app sleeps.
            for task in await checks.allTasks { task.cancel() }
            for item in waiting {
                if let webId = item.torboxId {
                    scheduleTorBoxCheck(item.id, webId: webId, kind: item.torboxKind ?? .web, after: 20)
                }
            }
        }
    }

    /// While the app sleeps, a small background transfer asks TorBox how it's getting on.
    /// iOS runs it around the given time and wakes JDLite with the answer, so once TorBox
    /// has the file, the download starts even with the app closed.
    private func scheduleTorBoxCheck(_ id: UUID, webId: Int, kind: TorBoxKind, after seconds: TimeInterval) {
        guard let request = TorBox.shared.statusRequest(kind, id: webId) else { return }
        let task = checks.downloadTask(with: request)
        task.earliestBeginDate = Date().addingTimeInterval(seconds)
        task.countOfBytesClientExpectsToSend = 500
        task.countOfBytesClientExpectsToReceive = 10_000
        task.taskDescription = "\(Self.checkPrefix)\n\(id.uuidString)\n\(webId)\n\(Int(seconds))\n\(kind.rawValue)"
        task.resume()
    }

    fileprivate func torboxCheckFinished(_ id: UUID, webId: Int, kind: TorBoxKind, interval: Int, body: Data?, status: Int) {
        // While the app is open (or kept awake), the regular poller handles TorBox.
        guard UIApplication.shared.applicationState == .background, !BackgroundKeeper.shared.isRunning,
              let item = items.first(where: { $0.id == id }), item.state == .resolving,
              item.torboxId == webId, item.torboxFileId == nil else { return }
        do {
            guard let body, (200..<300).contains(status) else { throw URLError(.badServerResponse) }
            let dl = try TorBox.parseStatus(body, id: webId)
            if let failure = dl.failure {
                mutate(id) { $0.torboxId = nil; $0.cloudProgress = nil }   // retry adds it again
                failResolve(id, "TorBox: " + failure)
            } else if dl.ready {
                beginFinishUpTime()   // starting the download may need a moment
                torboxReady(id, webId: webId, download: dl)
            } else {
                mutate(id, persist: false) {
                    $0.status = dl.statusText
                    $0.cloudProgress = dl.fraction
                }
                scheduleTorBoxCheck(id, webId: webId, kind: kind, after: Self.nextCheckDelay(after: interval))
            }
        } catch TorBoxError.gone {
            mutate(id) { $0.torboxId = nil; $0.cloudProgress = nil }
            failResolve(id, "TorBox: " + (TorBoxError.gone.errorDescription ?? "download gone"))
        } catch {
            scheduleTorBoxCheck(id, webId: webId, kind: kind, after: Self.nextCheckDelay(after: interval))
        }
    }

    fileprivate func torboxCheckFailed(_ id: UUID, webId: Int, kind: TorBoxKind, interval: Int) {
        guard UIApplication.shared.applicationState == .background, !BackgroundKeeper.shared.isRunning,
              let item = items.first(where: { $0.id == id }), item.state == .resolving,
              item.torboxId == webId, item.torboxFileId == nil else { return }
        scheduleTorBoxCheck(id, webId: webId, kind: kind, after: Self.nextCheckDelay(after: interval))
    }

    /// The first check runs after 20 s; each later one waits twice as long, up to every 5 minutes.
    nonisolated static func nextCheckDelay(after previous: Int) -> TimeInterval {
        TimeInterval(min(max(previous * 2, 30), 300))
    }

    nonisolated static func parseCheck(_ s: String?) -> (id: UUID, webId: Int, kind: TorBoxKind, interval: Int)? {
        guard let s, s.hasPrefix(checkPrefix) else { return nil }
        let lines = s.components(separatedBy: "\n")
        guard lines.count >= 4, let id = UUID(uuidString: lines[1]), let webId = Int(lines[2]),
              let interval = Int(lines[3]) else { return nil }
        let kind = lines.count > 4 ? (TorBoxKind(rawValue: lines[4]) ?? .web) : .web
        return (id: id, webId: webId, kind: kind, interval: interval)
    }

    /// iOS cancelled background transfers on its own (app swiped away, Background App Refresh
    /// off, low on resources). Keep their progress and carry on once possible.
    fileprivate func systemCancelled(_ id: UUID, part: Int64?, resumeData: Data?) {
        guard let i = index(of: id) else { return }
        if let part {
            bgLive[id]?.remove(part)
            guard let k = items[i].segments?.firstIndex(where: { $0.start == part }),
                  items[i].segments?[k].done == false else { return }
            items[i].segments?[k].resumeData = resumeData
        } else {
            items[i].resumeData = resumeData
        }
        save()
        pendingRestarts.insert(id)
        restartTask?.cancel()
        restartTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)   // collect every cancelled part first
            guard !Task.isCancelled else { return }
            await self.restartCancelled()
        }
    }

    private func restartCancelled() async {
        let ids = pendingRestarts
        pendingRestarts.removeAll()
        let tasks = await liveTasks(for: ids)
        let awake = inApp
        for id in ids {
            guard let i = index(of: id), items[i].state == .downloading else { continue }
            let mine = tasks.filter { Self.parseDesc($0.task.taskDescription)?.id == id }
            if mine.isEmpty && workers[id] == nil {
                // Nothing left running: queue it to carry on from where it stopped.
                refreshProgress(at: i)
                items[i].state = .queued
                clearTransfer(id)
            } else if awake, items[i].segments != nil {
                drive(i)   // restart just the parts that stopped
            }
        }
        save()
        // Starting again in the background could just get cancelled again; carry on in the app.
        if awake { startNext() }
    }

    private func notifyFailed(_ id: UUID) {
        if let item = items.first(where: { $0.id == id }), item.state == .failed {
            Notifier.shared.failed(item)
        }
    }

    // MARK: Launch

    /// Downloads split by an older version saved each part as its own file; those start again.
    private func migrateOldParts() {
        var changed = false
        for i in items.indices where items[i].segments != nil && items[i].layout != 2 && items[i].state != .completed {
            try? FileManager.default.removeItem(at: Self.partsDir(items[i].id))
            items[i].segments = nil
            items[i].bytesReceived = 0
            items[i].resumeData = nil
            if items[i].state == .downloading { items[i].state = .queued }
            changed = true
        }
        if changed { save() }
    }

    private func reconcile() {
        Task {
            // Give iOS a moment to deliver events for transfers that finished while the app was closed.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            var live: [UUID: Set<Int64>] = [:]
            var whole = Set<UUID>()
            for lane in lanes {
                for task in await lane.allTasks {
                    guard let tag = Self.parseDesc(task.taskDescription) else { continue }
                    if tag.outdated {
                        task.cancel()   // a part from an older version; its download starts again
                    } else if let part = tag.part {
                        live[tag.id, default: []].insert(part)
                    } else {
                        whole.insert(tag.id)
                    }
                }
            }
            for (id, parts) in live { bgLive[id, default: []].formUnion(parts) }
            var toResolve: [UUID] = []
            var toDrive: [UUID] = []
            for i in items.indices {
                let item = items[i]
                if item.state == .downloading, workers[item.id] == nil {
                    if item.segments != nil {
                        if (bgLive[item.id] ?? []).isEmpty {
                            items[i].state = .queued
                        } else {
                            toDrive.append(item.id)
                        }
                    } else if !whole.contains(item.id), !probing.contains(item.id) {
                        items[i].state = .queued
                    }
                }
                if item.state == .resolving { toResolve.append(item.id) }
            }
            save()
            for id in toResolve { Task { await self.runResolve(id) } }
            for id in toDrive {
                if let i = index(of: id) { drive(i) }
            }
            startNext()
            runDueRetries()
        }
    }

    fileprivate func mutate(_ id: UUID, persist: Bool = true, _ body: (inout DownloadItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        body(&items[i])
        if persist { save() }
    }

    private func index(of id: UUID) -> Int? {
        items.firstIndex { $0.id == id }
    }

    fileprivate func finishEvents(for identifier: String?) {
        guard let identifier, let handler = backgroundCompletionHandlers.removeValue(forKey: identifier) else { return }
        Task {
            await LiveActivityController.shared.refresh(force: true)
            handler()
        }
    }

    fileprivate func advance() { startNext() }

    // MARK: Progress

    private func ensureProgressLoop() {
        guard progressLoop == nil else { return }
        progressLoop = Task {
            while !self.workers.isEmpty {
                try? await Task.sleep(nanoseconds: 500_000_000)
                self.tick()
            }
            self.progressLoop = nil
            self.updateConnectionCounts()
        }
    }

    /// Twice a second while in-app connections run: progress, speed, and now and then a save.
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        for id in Array(workers.keys) {
            guard let i = index(of: id), items[i].state == .downloading else { continue }
            refreshProgress(at: i)
            updateSpeed(id, total: items[i].bytesReceived, now: now)
        }
        updateConnectionCounts()
        if now - lastSave >= 5 { save() }
    }

    /// Background transfer progress (called from the URLSession delegate).
    fileprivate func noteProgress(_ id: UUID, part: Int64?, written: Int64, expected: Int64) {
        if let part { liveBytes[id, default: [:]][part] = written }
        if workers[id] != nil { return }   // the in-app progress loop updates this download
        let now = ProcessInfo.processInfo.systemUptime
        if let last = samples[id], now - last.time < 0.5 { return }   // at most two screen updates a second
        guard let i = index(of: id), items[i].state == .downloading else { return }
        if part != nil {
            refreshProgress(at: i)
        } else {
            items[i].bytesReceived = written
            if expected > 0 { items[i].bytesTotal = expected }
        }
        updateSpeed(id, total: items[i].bytesReceived, now: now)
    }

    /// Adds up a download's progress: finished parts, bytes in-app connections have written,
    /// and what background transfers have fetched so far.
    private func refreshProgress(at i: Int) {
        guard var segs = items[i].segments else { return }
        let id = items[i].id
        var unsynced: Int64 = 0
        for worker in workers[id] ?? [] {
            guard let snap = worker.snapshot, let k = segs.firstIndex(where: { $0.start == snap.part }),
                  !segs[k].done else { continue }
            let cap = segs[k].end == TurboWorker.unknownEnd ? Int64.max : segs[k].length
            segs[k].received = min(max(snap.synced - snap.part, 0), cap)
            unsynced += max(0, min(snap.written - snap.part, cap) - segs[k].received)
        }
        for (start, bytes) in liveBytes[id] ?? [:] {
            guard let k = segs.firstIndex(where: { $0.start == start }), !segs[k].done,
                  segs[k].background == true else { continue }
            segs[k].received = min(bytes, segs[k].length)
        }
        items[i].segments = segs
        items[i].bytesReceived = segs.reduce(Int64(0)) { $0 + ($1.done ? $1.length : $1.received) } + unsynced
    }

    private func refreshProgress(_ id: UUID) {
        if let i = index(of: id) { refreshProgress(at: i) }
    }

    private func updateSpeed(_ id: UUID, total: Int64, now: TimeInterval) {
        if let last = samples[id], now > last.time {
            let instant = max(0, Double(total - last.bytes) / (now - last.time))
            speeds[id] = speeds[id].map { $0 * 0.6 + instant * 0.4 } ?? instant
        }
        samples[id] = (time: now, bytes: total)
    }

    private func updateConnectionCounts() {
        var counts: [UUID: Int] = [:]
        for item in items where item.state == .downloading {
            let n = connectionsInUse(item.id)
            if n > 0 { counts[item.id] = n }
        }
        if counts != connectionCounts { connectionCounts = counts }
    }

    fileprivate func clearTransfer(_ id: UUID) {
        samples[id] = nil
        speeds[id] = nil
    }

    fileprivate func finished(_ id: UUID, saved: FinishedFile) {
        clearTransfer(id)
        liveBytes[id] = nil
        bgLive[id] = nil
        directURLs[id] = nil
        workerLimit[id] = nil
        jsonReplies.remove(id)
        clearAttempts(id)
        if let list = workers.removeValue(forKey: id) {
            for worker in list { worker.stop() }
        }
        guard items.contains(where: { $0.id == id }) else {
            // Deleted while it was finishing: don't leave the file behind.
            try? FileManager.default.removeItem(at: saved.url)
            Self.removeEmptyFolders(above: saved.url)
            return
        }
        mutate(id) {
            $0.state = .completed
            $0.fileName = saved.url.lastPathComponent
            $0.savedName = saved.path
            $0.bytesReceived = saved.size
            $0.bytesTotal = saved.size
            $0.completedAt = Date()
            $0.error = nil
            $0.status = nil
            $0.segments = nil
            $0.layout = nil
            $0.autoRetries = nil
            $0.retryAt = nil
            $0.retryMark = nil
        }
        if let item = items.first(where: { $0.id == id }) {
            notifyFinished(item)
            removeFromTorBoxIfDone(item)
        }
        startNext()
    }

    /// One notification per file, or one for a whole torrent once all its files are in.
    private func notifyFinished(_ item: DownloadItem) {
        guard let group = item.groupID else {
            Notifier.shared.finished(item)
            return
        }
        let members = items.filter { $0.groupID == group }
        if members.count < 2 {
            Notifier.shared.finished(item)
        } else if members.allSatisfy({ $0.state == .completed }) {
            Notifier.shared.torrentFinished(name: item.groupName ?? item.fileName, files: members.count, group: group)
        }
    }

    fileprivate func downloadFailed(_ id: UUID, message: String, retryable: Bool = false) {
        turboStop(id)
        clearTransfer(id)
        mutate(id) {
            $0.state = .failed
            $0.error = message
            $0.resumeData = nil
            // Links found by a plugin (or Offcloud's instant links) can expire, so look the page
            // up again on retry. (Files in TorBox's or Offcloud's cloud keep their links.)
            if !$0.isCloudFile, let source = $0.sourceURL, source != $0.url {
                $0.needsResolve = true
            }
        }
        if !(retryable && planAutoRetry(id)) { notifyFailed(id) }
        startNext()
    }

    fileprivate func gotWebPage(_ id: UUID) {
        turboStop(id)
        clearTransfer(id)
        bgLive[id] = nil
        try? FileManager.default.removeItem(at: Self.partsDir(id))
        guard let item = items.first(where: { $0.id == id }) else { return }
        let source = item.sourceURL ?? item.url
        // A web page instead of the file usually means the site wants a premium account:
        // Offcloud has a go, even if it doesn't list the site.
        if !item.isCloudFile, item.viaOffcloud != true, Offcloud.shared.isActive,
           !(item.triedServices ?? []).contains(PremiumService.offcloud.rawValue),
           ["http", "https"].contains(source.scheme?.lowercased() ?? "") {
            mutate(id) {
                $0.url = source
                $0.headers = nil
                $0.resumeData = nil
                $0.segments = nil
                $0.layout = nil
                $0.bytesReceived = 0
                $0.state = .resolving
                $0.needsResolve = true
                $0.askOffcloud = true
                $0.error = nil
                $0.status = "The site sent a web page. Trying Offcloud…"
            }
            startNext()
            Task { await self.runResolve(id) }
            return
        }
        let hint: String
        var switchedOff: [String] = []
        if TorBox.shared.hasKey && !TorBox.shared.isActive { switchedOff.append("TorBox") }
        if Offcloud.shared.hasKey && !Offcloud.shared.isActive { switchedOff.append("Offcloud") }
        if item.viaOffcloud == true {
            hint = "Offcloud's link led to a web page too."
        } else if TorBox.shared.isActive {
            hint = "TorBox doesn't list this site as supported."
        } else if !switchedOff.isEmpty {
            hint = switchedOff.joined(separator: " and ") + (switchedOff.count == 1 ? " is" : " are") + " switched off in the ⋯ menu."
        } else {
            hint = "For file hosters like this one, add your TorBox or Offcloud account in the ⋯ menu, then tap retry."
        }
        mutate(id) {
            $0.state = .failed
            $0.resumeData = nil
            $0.segments = nil
            $0.layout = nil
            $0.bytesReceived = 0
            $0.error = "Got a web page instead of a file. " + hint
            if !$0.isCloudFile {
                if let source = $0.sourceURL { $0.url = source }
                $0.headers = nil
                $0.needsResolve = true   // retry checks plugins, TorBox and Offcloud again
            }
        }
        notifyFailed(id)
        startNext()
    }

    // MARK: Persistence

    private func save() {
        lastSave = ProcessInfo.processInfo.systemUptime
        if let d = try? JSONEncoder().encode(items) { try? d.write(to: storeURL, options: .atomic) }
        updateConnectionCounts()
        scheduleKeepAwakeCheck()
    }

    private func load() {
        if let d = try? Data(contentsOf: storeURL),
           let x = try? JSONDecoder().decode([DownloadItem].self, from: d) { items = x }
    }

    // MARK: Files

    /// Task description: "<id>\n<file name>", plus "\n@<part start>\n<part length>" for a part.
    nonisolated static func describe(_ id: UUID, name: String?, part: Int64?, length: Int64?) -> String {
        var s = id.uuidString + "\n" + (name ?? "")
        if let part { s += "\n@\(part)\n\(length ?? 0)" }
        return s
    }

    nonisolated static func parseDesc(_ s: String?) -> TransferTag? {
        guard let s else { return nil }
        let lines = s.components(separatedBy: "\n")
        guard let first = lines.first, let id = UUID(uuidString: first) else { return nil }
        let name = lines.count > 1 && !lines[1].isEmpty ? lines[1] : nil
        var part: Int64?
        var outdated = false
        if lines.count > 2 {
            if lines[2].hasPrefix("@") {
                part = Int64(lines[2].dropFirst())
                outdated = part == nil
            } else {
                outdated = true   // older versions numbered their parts
            }
        }
        let length = lines.count > 3 ? Int64(lines[3]) : nil
        return TransferTag(id: id, name: name, part: part, length: length, outdated: outdated)
    }

    nonisolated static func cleanName(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    nonisolated static var downloadsDir: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    nonisolated static var partsRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Parts", isDirectory: true)
    }

    nonisolated static func partsDir(_ id: UUID) -> URL {
        partsRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// .torrent files waiting to be sent to TorBox.
    nonisolated static var torrentsDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Torrents", isDirectory: true)
    }

    /// The file a download's bytes are written into while it downloads.
    nonisolated static func dataURL(_ id: UUID) -> URL {
        partsDir(id).appendingPathComponent("data")
    }

    /// A part that arrived through a background transfer, waiting to be copied into the data file.
    nonisolated static func partURL(_ id: UUID, _ start: Int64) -> URL {
        partsDir(id).appendingPathComponent("\(start).part")
    }

    nonisolated static func partKey(_ id: UUID, _ start: Int64) -> String {
        "\(id.uuidString)/\(start)"
    }

    nonisolated static func partReady(_ id: UUID, _ seg: Segment) -> Bool {
        let url = partURL(id, seg.start)
        return FileManager.default.fileExists(atPath: url.path) && fileSize(url) >= seg.length
    }

    nonisolated private static let fileQueue = DispatchQueue(label: "com.codeymoore.jdlite.parts", qos: .utility)

    /// Copies a finished background part into the data file, off the main thread.
    nonisolated static func absorbPart(_ id: UUID, start: Int64, length: Int64) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DownloadManager.fileQueue.async {
                continuation.resume(returning: DownloadManager.copyPart(id, start: start, length: length))
            }
        }
    }

    nonisolated static func copyPart(_ id: UUID, start: Int64, length: Int64) -> Bool {
        let fm = FileManager.default
        let part = partURL(id, start)
        let data = dataURL(id)
        guard fm.fileExists(atPath: part.path) else { return false }
        if start == 0, !fm.fileExists(atPath: data.path), (try? fm.moveItem(at: part, to: data)) != nil {
            return true   // nothing saved yet: the part simply becomes the data file
        }
        ensureFileExists(data)
        guard let output = try? FileHandle(forWritingTo: data),
              let input = try? FileHandle(forReadingFrom: part) else { return false }
        defer {
            try? output.close()
            try? input.close()
        }
        do {
            try output.seek(toOffset: UInt64(start))
            var left = length
            while left > 0 {
                guard let chunk = try input.read(upToCount: Int(min(left, 4 << 20))), !chunk.isEmpty else {
                    return false
                }
                try output.write(contentsOf: chunk)
                left -= Int64(chunk.count)
            }
            try output.synchronize()
        } catch {
            return false
        }
        try? fm.removeItem(at: part)
        return true
    }

    /// Parts are temporary, so keep them out of iCloud backups.
    nonisolated static func preparePartsFolder() {
        var root = partsRoot
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
    }

    nonisolated static func fileSize(_ url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// The folder inside Downloads for one file of a torrent: the torrent's own folder, then
    /// the file's subfolders as they are in the torrent.
    nonisolated static func torrentFolder(torrent: String, file path: String) -> String {
        let root = safeComponent(torrent) ?? "Torrent"
        var parts = path.split(separator: "/").compactMap { DownloadManager.safeComponent(String($0)) }
        if !parts.isEmpty { parts.removeLast() }          // the file's own name
        if parts.first == root { parts.removeFirst() }    // TorBox's paths start with the torrent's folder
        return ([root] + parts).joined(separator: "/")
    }

    /// A name that's safe for a folder: no slashes or control characters, not "." or "..",
    /// and not too long.
    nonisolated static func safeComponent(_ raw: String) -> String? {
        var name = raw.components(separatedBy: .controlCharacters).joined()
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.utf8.count > 200 { name.removeLast() }
        if name.isEmpty || name == "." || name == ".." { return nil }
        return name
    }

    /// Deletes folders inside Downloads that a deleted file has left empty.
    nonisolated static func removeEmptyFolders(above file: URL) {
        let fm = FileManager.default
        let root = downloadsDir.standardizedFileURL.path
        var dir = file.deletingLastPathComponent().standardizedFileURL
        while dir.path.hasPrefix(root + "/") {
            guard let contents = try? fm.contentsOfDirectory(atPath: dir.path),
                  contents.allSatisfy({ $0 == ".DS_Store" }) else { return }
            try? fm.removeItem(at: dir)
            dir = dir.deletingLastPathComponent()
        }
    }

    nonisolated static func uniqueURL(for name: String, in folder: URL? = nil) -> URL {
        let base = folder ?? downloadsDir
        var candidate = base.appendingPathComponent(name)
        let ext = candidate.pathExtension
        let stem = candidate.deletingPathExtension().lastPathComponent
        var n = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = base.appendingPathComponent(ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)")
            n += 1
        }
        return candidate
    }

    /// Reads a small JSON body (error replies are small; real files are skipped).
    nonisolated static func smallJSON(at url: URL) -> [String: Any]? {
        let size = fileSize(url)
        guard size > 0, size < 65_536, let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    nonisolated static func message(in json: [String: Any]) -> String? {
        let text = (json["detail"] as? String) ?? (json["error"] as? String) ?? ""
        return text.isEmpty ? nil : text
    }
}

// MARK: - Background URLSession delegate (runs off the main actor)

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        guard downloadTask.state == .running, let tag = Self.parseDesc(downloadTask.taskDescription),
              !tag.outdated else { return }
        let id = tag.id
        if let part = tag.part, let length = tag.length, length > 0,
           totalBytesExpectedToWrite > 0, totalBytesExpectedToWrite != length {
            // Not the byte range we asked for: stop it before it wastes data.
            downloadTask.cancel()
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            Task { @MainActor in self.partMismatch(id, part: part, rangesIgnored: status == 200) }
            return
        }
        let part = tag.part
        Task { @MainActor in
            self.noteProgress(id, part: part, written: totalBytesWritten, expected: totalBytesExpectedToWrite)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
        // A resumed part must still add up to exactly its byte range; otherwise start it over.
        guard let tag = Self.parseDesc(downloadTask.taskDescription), !tag.outdated, let part = tag.part,
              let length = tag.length, length > 0, expectedTotalBytes != length else { return }
        downloadTask.cancel()
        let id = tag.id
        Task { @MainActor in self.partMismatch(id, part: part, rangesIgnored: false) }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        if let check = Self.parseCheck(downloadTask.taskDescription) {
            // A TorBox status check made while the app was asleep (a small JSON reply).
            let body: Data? = Self.fileSize(location) < 1_000_000 ? (try? Data(contentsOf: location)) : nil
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            Task { @MainActor in
                self.torboxCheckFinished(check.id, webId: check.webId, kind: check.kind,
                                         interval: check.interval, body: body, status: status)
            }
            return
        }
        guard let tag = Self.parseDesc(downloadTask.taskDescription), !tag.outdated else { return }
        let id = tag.id
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let mime = downloadTask.response?.mimeType?.lowercased() ?? ""

        if let part = tag.part {
            // Keep the part (the temp file is deleted when this method returns).
            let dest = Self.partURL(id, part)
            var moved = false
            do {
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: location, to: dest)
                moved = true
            } catch {}
            let size = moved ? Self.fileSize(dest) : 0
            let ok = status == 206 && !mime.contains("html")
            Task { @MainActor in
                self.partFinished(id, part: part, moved: moved, ok: ok, size: size, status: status)
            }
            return
        }

        if downloadTask.response is HTTPURLResponse, !(200..<300).contains(status) {
            let detail = Self.smallJSON(at: location).flatMap { Self.message(in: $0) }
            let message = detail.map { "HTTP \(status): \($0)" } ?? "HTTP \(status)"
            let busy = status == 429 || status >= 500
            Task { @MainActor in self.downloadFailed(id, message: message, retryable: busy) }
            return
        }

        // A web page instead of a file (e.g. a file hoster's download page): don't save it.
        if mime == "text/html" || mime == "application/xhtml+xml" {
            Task { @MainActor in self.gotWebPage(id) }
            return
        }
        if mime == "application/json", let json = Self.smallJSON(at: location),
           (json["success"] as? Bool) == false {
            let message = Self.message(in: json) ?? "The server returned an error."
            Task { @MainActor in self.downloadFailed(id, message: message) }
            return
        }

        // The temp file is deleted when this method returns, so move it now; it then goes
        // into Downloads.
        let name = Self.cleanName(tag.name ?? downloadTask.response?.suggestedFilename ?? "download")
        let holding = Self.dataURL(id)
        do {
            try FileManager.default.createDirectory(at: holding.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: holding)
            try FileManager.default.moveItem(at: location, to: holding)
            Task { @MainActor in self.deliver(id, file: holding, name: name) }
        } catch {
            let msg = error.localizedDescription
            Task { @MainActor in
                self.clearTransfer(id)
                self.mutate(id) { $0.state = .failed; $0.error = msg }
                self.advance()
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let ns = error as NSError
        if let check = Self.parseCheck(task.taskDescription) {
            if ns.code != NSURLErrorCancelled {
                Task { @MainActor in
                    self.torboxCheckFailed(check.id, webId: check.webId, kind: check.kind, interval: check.interval)
                }
            }
            return
        }
        guard let tag = Self.parseDesc(task.taskDescription), !tag.outdated else { return }
        let id = tag.id
        let part = tag.part
        let data = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        if ns.code == NSURLErrorCancelled {
            // Our own pause/delete cancels are handled where they happen. iOS also cancels
            // transfers itself (app swiped away, Background App Refresh off, low on
            // resources): keep their progress so they carry on later.
            if ns.userInfo[NSURLErrorBackgroundTaskCancelledReasonKey] != nil {
                Task { @MainActor in self.systemCancelled(id, part: part, resumeData: data) }
            }
            return
        }
        let msg = error.localizedDescription
        if let part {
            Task { @MainActor in self.partFailed(id, part: part, message: msg, resumeData: data) }
            return
        }
        let retryable = TurboWorker.isRetryable(error)
        Task { @MainActor in
            self.clearTransfer(id)
            var failedNow = false
            self.mutate(id) {
                guard $0.state == .downloading else { return }
                $0.state = .failed
                $0.error = msg
                $0.resumeData = data
                failedNow = true
            }
            if failedNow, !(retryable && self.planAutoRetry(id)) { self.notifyFailed(id) }
            self.advance()
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let identifier = session.configuration.identifier
        Task { @MainActor in self.finishEvents(for: identifier) }
    }
}
