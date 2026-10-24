import Foundation
import Combine
import UIKit

enum DownloadState: String, Codable { case queued, resolving, downloading, paused, completed, failed }

/// One byte range of a file, downloaded over its own connection.
struct Segment: Codable, Equatable {
    var start: Int64
    var end: Int64                   // inclusive
    var received: Int64 = 0
    var done = false
    var retries = 0
    var resumeData: Data?

    var length: Int64 { end - start + 1 }
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
    var preferredName: String?       // file name chosen by a plugin or TorBox
    var status: String?              // progress note (resolving, connecting, joining)
    var sourceURL: URL?              // the link as it was added
    var torboxId: Int?               // TorBox web download ID
    var torboxFileId: Int?           // file inside that TorBox download
    var cloudProgress: Double?       // how far TorBox has fetched the file (0...1)
    var savedName: String?           // file name in Downloads once finished
    var addedAt: Date?
    var completedAt: Date?
    var segments: [Segment]?         // set when the file downloads over several connections
    var singleConnection: Bool?      // the server can't send parts of this file
    var mergedThrough: Int?          // parts joined so far (survives app restarts)

    var progress: Double { bytesTotal > 0 ? min(Double(bytesReceived) / Double(bytesTotal), 1) : 0 }

    /// The finished file in Downloads, if there is one.
    var savedFileName: String? { savedName ?? (state == .completed ? fileName : nil) }
}

@MainActor
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var items: [DownloadItem] = []
    /// Current speed (bytes per second) of each running download.
    @Published private(set) var speeds: [UUID: Double] = [:]
    /// Handed over by iOS when it wakes the app for finished background transfers.
    var backgroundCompletionHandlers: [String: () -> Void] = [:]

    /// Several background sessions ("lanes"). Each part of a file goes through its own
    /// lane, so the parts travel over separate connections and keep going in the background.
    private var lanes: [URLSession] = []
    private static let laneCount = 8
    private static let minSplitSize: Int64 = 8 << 20   // smaller files use one connection
    private static let minPartSize: Int64 = 2 << 20

    private var torboxPoller: Task<Void, Never>?
    private var samples: [UUID: (time: TimeInterval, bytes: Int64)] = [:]
    private var liveBytes: [UUID: [Int: Int64]] = [:]   // per-part progress not yet copied into items
    private var merging = Set<UUID>()
    private var backgroundTime: [UUID: UIBackgroundTaskIdentifier] = [:]
    private let storeURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("downloads.json")
    }()

    private var maxConcurrent: Int { AppSettings.shared.simultaneousDownloads }

    override init() {
        super.init()
        load()
        Self.preparePartsFolder()
        let base = "\(Bundle.main.bundleIdentifier ?? "jdlite").downloads"
        for n in 0..<Self.laneCount {
            let cfg = URLSessionConfiguration.background(withIdentifier: n == 0 ? base : "\(base).lane\(n)")
            cfg.sessionSendsLaunchEvents = true
            cfg.isDiscretionary = false
            cfg.httpMaximumConnectionsPerHost = 6
            lanes.append(URLSession(configuration: cfg, delegate: self, delegateQueue: nil))
        }
        reconcile()
    }

    // MARK: Public API

    func add(urls: [URL]) {
        var ids: [UUID] = []
        for url in urls where !items.contains(where: { ($0.sourceURL ?? $0.url) == url && $0.state != .completed }) {
            var name = url.lastPathComponent
            if name.isEmpty || name == "/" { name = url.host ?? "download" }
            var item = DownloadItem(url: url, fileName: Self.cleanName(name))
            item.state = .resolving
            item.needsResolve = true
            item.sourceURL = url
            item.addedAt = Date()
            items.append(item)
            ids.append(item.id)
        }
        save()
        for id in ids { Task { await runResolve(id) } }
    }

    /// Handles jdlite://add?u=<url>&u=<url> links sent by the Safari extension.
    func handleOpen(_ url: URL) {
        guard url.scheme == "jdlite", url.host == "add",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let urls = (comps.queryItems ?? [])
            .filter { $0.name == "u" }
            .compactMap { $0.value }
            .compactMap { URL(string: $0) }
            .filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
        add(urls: urls)
    }

    func resume(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
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
            if merging.contains(id) { return }   // only joining is left: let it finish
            flushProgress(id)
            mutate(id) { $0.state = .paused; $0.status = nil }
            clearTransfer(id)
            startNext()
            Task { await stopTransfers(for: id) }
        default:
            break
        }
    }

    /// Removes downloads from the list and deletes their files: the finished file,
    /// or whatever was downloaded so far.
    func delete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        Task {
            for (task, _) in await liveTasks(for: ids) { task.cancel() }
        }
        let remaining = items.filter { !ids.contains($0.id) }
        let stillUsed = Set(remaining.compactMap { $0.savedFileName })
        for item in items where ids.contains(item.id) {
            clearTransfer(item.id)
            liveBytes[item.id] = nil
            try? FileManager.default.removeItem(at: Self.partsDir(item.id))
            if let name = item.savedFileName, !stillUsed.contains(name) {
                try? FileManager.default.removeItem(at: Self.downloadsDir.appendingPathComponent(name))
            }
        }
        items = remaining
        save()
        startNext()
    }

    /// Removes finished downloads from the list. Their files stay in Downloads.
    func clearCompleted() {
        items.removeAll { $0.state == .completed }
        save()
    }

    /// Called when the "downloads at once" setting changes.
    func settingsChanged() { startNext() }

    nonisolated static func extractLinks(from text: String) -> [URL] {
        guard let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        var seen = Set<URL>()
        var out: [URL] = []
        det.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) { m, _, _ in
            if let u = m?.url, ["http", "https"].contains(u.scheme?.lowercased() ?? ""), seen.insert(u).inserted {
                out.append(u)
            }
        }
        return out
    }

    // MARK: Resolving: plugins first, then TorBox, otherwise download the link directly

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

        if await TorBox.shared.supports(link) {
            guard isResolving(id) else { return }
            setStatus(id, "Sending to TorBox…")
            do {
                let webId = try await TorBox.shared.create(link: link)
                guard items.contains(where: { $0.id == id }) else { return }
                mutate(id) { $0.torboxId = webId }
                guard isResolving(id) else { return }
                setStatus(id, "Waiting for TorBox…")
                startTorBoxPolling()
            } catch {
                failResolve(id, "TorBox: " + error.localizedDescription)
            }
            return
        }

        guard isResolving(id) else { return }
        mutate(id) { $0.state = .queued; $0.needsResolve = nil; $0.status = nil }
        startNext()
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
    private func startTorBoxPolling() {
        guard torboxPoller == nil else { return }
        torboxPoller = Task {
            await self.pollTorBox()
            self.torboxPoller = nil
        }
    }

    private func pollTorBox() async {
        var delay: Double = 2
        var strikes: [UUID: Int] = [:]
        while true {
            let waiting = items.filter { $0.state == .resolving && $0.torboxId != nil && $0.torboxFileId == nil }
            if waiting.isEmpty { return }
            for item in waiting {
                guard let webId = item.torboxId, isResolving(item.id) else { continue }
                do {
                    let dl = try await TorBox.shared.webDownload(id: webId)
                    strikes[item.id] = nil
                    guard isResolving(item.id) else { continue }
                    if let failure = dl.failure {
                        mutate(item.id) { $0.torboxId = nil; $0.cloudProgress = nil }   // retry adds it again
                        failResolve(item.id, "TorBox: " + failure)
                    } else if dl.ready {
                        torboxReady(item.id, webId: webId, files: dl.files)
                    } else {
                        mutate(item.id, persist: false) {
                            $0.status = dl.statusText
                            $0.cloudProgress = dl.fraction
                        }
                    }
                } catch TorBoxError.gone {
                    mutate(item.id) { $0.torboxId = nil; $0.cloudProgress = nil }
                    failResolve(item.id, "TorBox: " + (TorBoxError.gone.errorDescription ?? "download gone"))
                } catch is URLError {
                    let n = (strikes[item.id] ?? 0) + 1
                    strikes[item.id] = n
                    if n >= 6 {
                        failResolve(item.id, "TorBox: can't connect. Tap retry.")
                    } else {
                        setStatus(item.id, "TorBox: connection problem, retrying…")
                    }
                } catch {
                    failResolve(item.id, "TorBox: " + error.localizedDescription)
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            delay = min(delay * 1.5, 10)
        }
    }

    private func torboxReady(_ id: UUID, webId: Int, files: [TorBoxFile]) {
        guard let first = files.first, let item = items.first(where: { $0.id == id }) else { return }
        let origin = item.sourceURL ?? item.url
        mutate(id, persist: false) {
            $0.torboxFileId = first.id
            $0.fileName = Self.cleanName(first.name)
            $0.preferredName = Self.cleanName(first.name)
            $0.sourceURL = origin
            if let size = first.size, size > 0 { $0.bytesTotal = size }
            $0.cloudProgress = nil
            $0.state = .queued
            $0.needsResolve = nil
            $0.status = nil
            $0.error = nil
        }
        for file in files.dropFirst() {
            var extra = DownloadItem(url: origin, fileName: Self.cleanName(file.name))
            extra.preferredName = Self.cleanName(file.name)
            extra.sourceURL = origin
            extra.torboxId = webId
            extra.torboxFileId = file.id
            extra.bytesTotal = max(file.size ?? 0, 0)
            extra.addedAt = Date()
            items.append(extra)
        }
        save()
        startNext()
    }

    private func isResolving(_ id: UUID) -> Bool {
        items.first(where: { $0.id == id })?.state == .resolving
    }

    private func setStatus(_ id: UUID, _ text: String) {
        mutate(id, persist: false) { $0.status = text }
    }

    private func failResolve(_ id: UUID, _ message: String) {
        guard isResolving(id) else { return }   // paused or removed meanwhile
        mutate(id) { $0.state = .failed; $0.error = message; $0.status = nil }
    }

    // MARK: Queue

    private func startNext() {
        var active = items.filter { $0.state == .downloading }.count
        for i in items.indices where active < maxConcurrent && items[i].state == .queued {
            if begin(at: i) { active += 1 }
        }
    }

    /// The request for the file itself (TorBox downloads use TorBox's permanent link).
    private func downloadRequest(for item: DownloadItem) -> URLRequest? {
        var target = item.url
        if let webId = item.torboxId, let fileId = item.torboxFileId {
            guard let link = TorBox.shared.permalink(webId: webId, fileId: fileId) else { return nil }
            target = link
        }
        var req = URLRequest(url: target)
        for (k, v) in item.headers ?? [:] { req.setValue(v, forHTTPHeaderField: k) }
        return req
    }

    /// Starts or continues a queued download. Returns false if it couldn't start.
    @discardableResult
    private func begin(at i: Int) -> Bool {
        let item = items[i]
        guard let request = downloadRequest(for: item) else {
            items[i].state = .failed
            items[i].error = TorBoxError.noKey.errorDescription
            save()
            return false
        }
        clearTransfer(item.id)
        items[i].state = .downloading
        items[i].error = nil
        items[i].status = nil

        if let segments = item.segments {
            // A split download: continue every part that isn't done yet.
            if segments.allSatisfy({ $0.done }) {
                save()
                merge(item.id)
                return true
            }
            for k in segments.indices where !segments[k].done {
                launchPart(at: i, part: k, request: request)
            }
            flushProgress(at: i)
            save()
            return true
        }

        let fresh = item.resumeData == nil && item.bytesReceived == 0
        if fresh && item.singleConnection != true && AppSettings.shared.connectionsPerDownload > 1 {
            items[i].status = "Connecting…"
            save()
            Task { await self.split(item.id, request: request) }
            return true
        }
        startWhole(item, request: request)
        items[i].resumeData = nil
        save()
        return true
    }

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

    /// Starts one part of a split download in its own lane.
    private func launchPart(at i: Int, part k: Int, request: URLRequest) {
        guard let segs = items[i].segments, segs.indices.contains(k) else { return }
        let id = items[i].id
        let seg = segs[k]
        let lane = lanes[k % lanes.count]
        let task: URLSessionDownloadTask
        if let data = seg.resumeData {
            task = lane.downloadTask(withResumeData: data)
        } else {
            var req = request
            req.setValue("bytes=\(seg.start)-\(seg.end)", forHTTPHeaderField: "Range")
            task = lane.downloadTask(with: req)
            items[i].segments?[k].received = 0
            liveBytes[id]?[k] = nil
        }
        items[i].segments?[k].resumeData = nil
        task.taskDescription = Self.describe(id, name: items[i].preferredName, part: k, length: seg.length)
        task.resume()
    }

    // MARK: Split downloads

    private struct Probe: Sendable {
        let total: Int64
        let acceptsRanges: Bool
    }

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

    /// Splits a new download into parts if the server allows it, else uses one connection.
    private func split(_ id: UUID, request: URLRequest) async {
        let probe = await Self.probe(request)
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].state == .downloading,
              items[i].segments == nil else { return }   // paused or deleted meanwhile
        items[i].status = nil
        if let probe, probe.acceptsRanges, probe.total >= Self.minSplitSize {
            let parts = Int(min(Int64(AppSettings.shared.connectionsPerDownload), probe.total / Self.minPartSize))
            if parts >= 2 {
                try? FileManager.default.removeItem(at: Self.partsDir(id))
                items[i].bytesTotal = probe.total
                items[i].mergedThrough = nil
                items[i].segments = Self.makeSegments(total: probe.total, parts: parts)
                for k in 0..<parts { launchPart(at: i, part: k, request: request) }
                save()
                return
            }
        }
        if probe?.acceptsRanges == false { items[i].singleConnection = true }
        startWhole(items[i], request: request)
        save()
    }

    /// Running transfers for these downloads, with the part each carries (nil = whole file).
    private func liveTasks(for ids: Set<UUID>) async -> [(task: URLSessionTask, part: Int?)] {
        var out: [(task: URLSessionTask, part: Int?)] = []
        for lane in lanes {
            for task in await lane.allTasks {
                if let d = Self.parseDesc(task.taskDescription), ids.contains(d.id) {
                    out.append((task: task, part: d.part))
                }
            }
        }
        return out
    }

    /// Cancels a download's transfers, keeping resume data so it can carry on later.
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

    private func keepResumeData(_ id: UUID, part: Int?, data: Data?) {
        guard let i = items.firstIndex(where: { $0.id == id }),
              items[i].state == .paused || items[i].state == .failed else { return }
        if let part {
            guard let segs = items[i].segments, segs.indices.contains(part) else { return }
            items[i].segments?[part].resumeData = data
        } else {
            items[i].resumeData = data
        }
        save()
    }

    fileprivate func partFinished(_ id: UUID, part k: Int, moved: Bool, ok: Bool, size: Int64, status: Int) {
        guard let i = items.firstIndex(where: { $0.id == id }), let segs = items[i].segments,
              segs.indices.contains(k) else {
            try? FileManager.default.removeItem(at: Self.partsDir(id))   // deleted meanwhile
            return
        }
        let file = Self.partURL(id, k)
        let length = segs[k].length
        guard moved, ok, size >= length else {
            try? FileManager.default.removeItem(at: file)
            if status == 200 { fallBackToWhole(at: i); return }   // the server ignored the range
            partFailed(id, part: k, message: "Part \(k + 1) of the file came back incomplete.", resumeData: nil)
            return
        }
        if size > length, let handle = try? FileHandle(forWritingTo: file) {
            // The server sent more than asked for; the first `length` bytes are this part.
            try? handle.truncate(atOffset: UInt64(length))
            try? handle.close()
        }
        items[i].segments?[k].done = true
        items[i].segments?[k].received = length
        items[i].segments?[k].resumeData = nil
        liveBytes[id]?[k] = nil
        flushProgress(at: i)
        save()
        if items[i].segments?.allSatisfy({ $0.done }) == true, items[i].state == .downloading {
            merge(id)
        }
    }

    fileprivate func partFailed(_ id: UUID, part k: Int, message: String, resumeData: Data?) {
        guard let i = items.firstIndex(where: { $0.id == id }), let segs = items[i].segments,
              segs.indices.contains(k) else { return }
        items[i].segments?[k].resumeData = resumeData
        liveBytes[id]?[k] = nil
        guard items[i].state == .downloading else { save(); return }   // paused or failed already
        let retries = segs[k].retries + 1
        items[i].segments?[k].retries = retries
        save()
        if retries <= 3 {
            Task {
                try? await Task.sleep(nanoseconds: UInt64(retries) * 2_000_000_000)
                self.retryPart(id, part: k)
            }
        } else {
            failSplit(id, message: message)
        }
    }

    private func retryPart(_ id: UUID, part k: Int) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].state == .downloading,
              let segs = items[i].segments, segs.indices.contains(k), !segs[k].done,
              let request = downloadRequest(for: items[i]) else { return }
        launchPart(at: i, part: k, request: request)
        save()
    }

    /// A part isn't the byte range we asked for: restart it, or give up on splitting this file.
    fileprivate func partMismatch(_ id: UUID, part k: Int, rangesIgnored: Bool) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].state == .downloading,
              let segs = items[i].segments, segs.indices.contains(k) else { return }
        if rangesIgnored || (segs[k].resumeData == nil && segs[k].received == 0) {
            fallBackToWhole(at: i)
        } else {
            // Resuming this part went wrong: start it again from its beginning.
            items[i].segments?[k].resumeData = nil
            items[i].segments?[k].received = 0
            liveBytes[id]?[k] = nil
            save()
            retryPart(id, part: k)
        }
    }

    /// Stops a split download that keeps failing, keeping its progress for a retry.
    private func failSplit(_ id: UUID, message: String) {
        flushProgress(id)
        mutate(id) { $0.state = .failed; $0.error = message; $0.status = nil }
        clearTransfer(id)
        startNext()
        Task { await stopTransfers(for: id) }
    }

    /// The server won't send parts after all: download the file over one connection.
    private func fallBackToWhole(at i: Int) {
        let id = items[i].id
        items[i].segments = nil
        items[i].mergedThrough = nil
        items[i].singleConnection = true
        items[i].bytesReceived = 0
        liveBytes[id] = nil
        clearTransfer(id)
        save()
        Task {
            for (task, part) in await self.liveTasks(for: [id]) where part != nil { task.cancel() }
            try? FileManager.default.removeItem(at: Self.partsDir(id))
            guard let j = self.items.firstIndex(where: { $0.id == id }), self.items[j].state == .downloading,
                  let request = self.downloadRequest(for: self.items[j]) else { return }
            self.startWhole(self.items[j], request: request)
        }
    }

    // MARK: Joining parts

    private func merge(_ id: UUID) {
        guard !merging.contains(id), let i = items.firstIndex(where: { $0.id == id }),
              let segs = items[i].segments, !segs.isEmpty, segs.allSatisfy({ $0.done }) else { return }
        merging.insert(id)
        items[i].status = "Joining parts…"
        clearTransfer(id)
        let name = Self.cleanName(items[i].preferredName ?? items[i].fileName)
        let startAt = min(max(items[i].mergedThrough ?? 0, 0), segs.count - 1)
        // Ask iOS for extra time in case this happens while the app is in the background.
        // If time runs out, the join carries on from its last checkpoint next time.
        backgroundTime[id] = UIApplication.shared.beginBackgroundTask(withName: "Join parts") { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.endBackgroundTime(id)
            }
        }
        Task {
            let joined = await self.joinParts(id, segments: segs, startAt: startAt)
            self.merging.remove(id)
            self.joinFinished(id, joined: joined, name: name)
            self.endBackgroundTime(id)
        }
    }

    private func endBackgroundTime(_ id: UUID) {
        if let task = backgroundTime.removeValue(forKey: id), task != .invalid {
            UIApplication.shared.endBackgroundTask(task)
        }
    }

    /// Appends parts 1...n onto part 0, in order, checkpointing after each part so an
    /// interrupted join can carry on later. Runs off the main thread.
    private nonisolated func joinParts(_ id: UUID, segments: [Segment], startAt: Int) async -> URL? {
        let first = Self.partURL(id, 0)
        do {
            let out = try FileHandle(forWritingTo: first)
            defer { try? out.close() }
            // Part 0 holds parts 0...startAt; drop anything a previous join half-wrote.
            try out.truncate(atOffset: UInt64(segments[startAt].end + 1))
            _ = try out.seekToEnd()
            var k = startAt + 1
            while k < segments.count {
                let part = Self.partURL(id, k)
                let input = try FileHandle(forReadingFrom: part)
                while let chunk = try input.read(upToCount: 8 << 20), !chunk.isEmpty {
                    try out.write(contentsOf: chunk)
                }
                try input.close()
                try out.synchronize()
                try? FileManager.default.removeItem(at: part)
                await self.recordJoined(id, through: k)
                k += 1
            }
            return first
        } catch {
            return nil
        }
    }

    private func recordJoined(_ id: UUID, through k: Int) {
        mutate(id) { $0.mergedThrough = k }
    }

    private func joinFinished(_ id: UUID, joined: URL?, name: String) {
        guard items.contains(where: { $0.id == id }) else {
            try? FileManager.default.removeItem(at: Self.partsDir(id))   // deleted meanwhile
            return
        }
        guard let joined else {
            // Keep the parts: a retry joins them again (e.g. after freeing up space).
            mutate(id) {
                $0.state = .failed
                $0.status = nil
                $0.error = "Couldn't join the downloaded parts. Check there's enough free space, then tap retry."
            }
            startNext()
            return
        }
        let dest = Self.uniqueURL(for: name)
        do {
            try FileManager.default.moveItem(at: joined, to: dest)
            try? FileManager.default.removeItem(at: Self.partsDir(id))
            finished(id, savedName: dest.lastPathComponent, size: Self.fileSize(dest))
        } catch {
            mutate(id) { $0.state = .failed; $0.status = nil; $0.error = error.localizedDescription }
            startNext()
        }
    }

    // MARK: Launch

    private func reconcile() {
        Task {
            // Give iOS a moment to deliver events for transfers that finished while the app was closed.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            var live = Set<UUID>()
            for lane in lanes {
                for task in await lane.allTasks {
                    if let d = Self.parseDesc(task.taskDescription) { live.insert(d.id) }
                }
            }
            var toResolve: [UUID] = []
            var toJoin: [UUID] = []
            for i in items.indices {
                let it = items[i]
                if it.state == .downloading {
                    if let segs = it.segments, !segs.isEmpty, segs.allSatisfy({ $0.done }) {
                        toJoin.append(it.id)
                    } else if !live.contains(it.id) {
                        items[i].state = .queued
                    }
                }
                if it.state == .resolving { toResolve.append(it.id) }
            }
            save()
            for id in toResolve { Task { await self.runResolve(id) } }
            for id in toJoin { merge(id) }
            startNext()
        }
    }

    fileprivate func mutate(_ id: UUID, persist: Bool = true, _ body: (inout DownloadItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        body(&items[i])
        if persist { save() }
    }

    fileprivate func finishEvents(for identifier: String?) {
        guard let identifier, let handler = backgroundCompletionHandlers.removeValue(forKey: identifier) else { return }
        Task {
            await LiveActivityController.shared.refresh(force: true)
            handler()
        }
    }

    fileprivate func advance() { startNext() }

    // MARK: Transfer updates (called from the URLSession delegate)

    fileprivate func noteProgress(_ id: UUID, part: Int?, written: Int64, expected: Int64) {
        if let part { liveBytes[id, default: [:]][part] = written }
        let now = ProcessInfo.processInfo.systemUptime
        if let last = samples[id], now - last.time < 0.5 { return }   // at most two screen updates a second
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].state == .downloading else { return }
        if part != nil {
            flushProgress(at: i)
        } else {
            items[i].bytesReceived = written
            if expected > 0 { items[i].bytesTotal = expected }
        }
        let total = items[i].bytesReceived
        if let last = samples[id] {
            let instant = max(0, Double(total - last.bytes) / (now - last.time))
            speeds[id] = speeds[id].map { $0 * 0.6 + instant * 0.4 } ?? instant
        }
        samples[id] = (time: now, bytes: total)
    }

    /// Copies per-part progress into the item and updates its total.
    private func flushProgress(at i: Int) {
        guard var segs = items[i].segments else { return }
        for (k, bytes) in liveBytes[items[i].id] ?? [:] where segs.indices.contains(k) && !segs[k].done {
            segs[k].received = min(bytes, segs[k].length)
        }
        items[i].segments = segs
        items[i].bytesReceived = segs.reduce(Int64(0)) { $0 + ($1.done ? $1.length : $1.received) }
    }

    private func flushProgress(_ id: UUID) {
        if let i = items.firstIndex(where: { $0.id == id }) { flushProgress(at: i) }
    }

    fileprivate func clearTransfer(_ id: UUID) {
        samples[id] = nil
        speeds[id] = nil
    }

    fileprivate func finished(_ id: UUID, savedName: String, size: Int64) {
        clearTransfer(id)
        liveBytes[id] = nil
        guard items.contains(where: { $0.id == id }) else {
            // Deleted while it was finishing: don't leave the file behind.
            try? FileManager.default.removeItem(at: Self.downloadsDir.appendingPathComponent(savedName))
            return
        }
        mutate(id) {
            $0.state = .completed
            $0.fileName = savedName
            $0.savedName = savedName
            $0.bytesReceived = size
            $0.bytesTotal = size
            $0.completedAt = Date()
            $0.error = nil
            $0.status = nil
            $0.segments = nil
            $0.mergedThrough = nil
        }
        startNext()
    }

    fileprivate func downloadFailed(_ id: UUID, message: String) {
        clearTransfer(id)
        mutate(id) {
            $0.state = .failed
            $0.error = message
            $0.resumeData = nil
            // Links found by a plugin can expire, so look the page up again on retry.
            // (TorBox items always start from a fresh TorBox link anyway.)
            if $0.torboxFileId == nil, let source = $0.sourceURL, source != $0.url {
                $0.needsResolve = true
            }
        }
        startNext()
    }

    fileprivate func gotWebPage(_ id: UUID) {
        clearTransfer(id)
        let hint: String
        if TorBox.shared.isActive {
            hint = "TorBox doesn't list this site as supported."
        } else if TorBox.shared.hasKey {
            hint = "TorBox is switched off in ⋯ › TorBox."
        } else {
            hint = "For file hosters like this one, add your TorBox API key in ⋯ › TorBox, then tap retry."
        }
        mutate(id) {
            $0.state = .failed
            $0.resumeData = nil
            $0.error = "Got a web page instead of a file. " + hint
            if $0.torboxFileId == nil {
                if let source = $0.sourceURL { $0.url = source }
                $0.headers = nil
                $0.needsResolve = true   // retry checks TorBox/plugins again
            }
        }
        startNext()
    }

    // MARK: Persistence

    private func save() {
        if let d = try? JSONEncoder().encode(items) { try? d.write(to: storeURL, options: .atomic) }
    }

    private func load() {
        if let d = try? Data(contentsOf: storeURL),
           let x = try? JSONDecoder().decode([DownloadItem].self, from: d) { items = x }
    }

    // MARK: Files

    /// Task description: "<id>\n<file name>" plus "\n<part>\n<part length>" for parts.
    nonisolated static func describe(_ id: UUID, name: String?, part: Int?, length: Int64?) -> String {
        var s = id.uuidString + "\n" + (name ?? "")
        if let part { s += "\n\(part)\n\(length ?? 0)" }
        return s
    }

    nonisolated static func parseDesc(_ s: String?) -> (id: UUID, name: String?, part: Int?, length: Int64?)? {
        guard let s else { return nil }
        let lines = s.components(separatedBy: "\n")
        guard let first = lines.first, let id = UUID(uuidString: first) else { return nil }
        let name = lines.count > 1 && !lines[1].isEmpty ? lines[1] : nil
        let part = lines.count > 2 ? Int(lines[2]) : nil
        let length = lines.count > 3 ? Int64(lines[3]) : nil
        return (id: id, name: name, part: part, length: length)
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

    nonisolated static func partURL(_ id: UUID, _ k: Int) -> URL {
        partsDir(id).appendingPathComponent("\(k).part")
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

    nonisolated static func uniqueURL(for name: String) -> URL {
        let base = downloadsDir
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

// MARK: - URLSession delegate (runs off the main actor)

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        guard downloadTask.state == .running, let d = Self.parseDesc(downloadTask.taskDescription) else { return }
        let id = d.id
        if let part = d.part, let length = d.length, length > 0,
           totalBytesExpectedToWrite > 0, totalBytesExpectedToWrite != length {
            // Not the byte range we asked for: stop it before it wastes data.
            downloadTask.cancel()
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            Task { @MainActor in self.partMismatch(id, part: part, rangesIgnored: status == 200) }
            return
        }
        Task { @MainActor in
            self.noteProgress(id, part: d.part, written: totalBytesWritten, expected: totalBytesExpectedToWrite)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
        // A resumed part must still add up to exactly its byte range; otherwise start it over.
        guard let d = Self.parseDesc(downloadTask.taskDescription), let part = d.part,
              let length = d.length, length > 0, expectedTotalBytes != length else { return }
        downloadTask.cancel()
        let id = d.id
        Task { @MainActor in self.partMismatch(id, part: part, rangesIgnored: false) }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        guard let d = Self.parseDesc(downloadTask.taskDescription) else { return }
        let id = d.id
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let mime = downloadTask.response?.mimeType?.lowercased() ?? ""

        if let part = d.part {
            // Keep the part (the temp file is deleted when this method returns).
            let dest = Self.partURL(id, part)
            var moved = false
            do {
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
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
            Task { @MainActor in self.downloadFailed(id, message: message) }
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

        // The temp file is deleted when this method returns, so move it now.
        let hint = (d.name?.isEmpty == false) ? d.name : nil
        let name = Self.cleanName(hint ?? downloadTask.response?.suggestedFilename ?? "download")
        let dest = Self.uniqueURL(for: name)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            let size = Self.fileSize(dest)
            let finalName = dest.lastPathComponent
            Task { @MainActor in self.finished(id, savedName: finalName, size: size) }
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
        guard let error, let d = Self.parseDesc(task.taskDescription) else { return }
        let ns = error as NSError
        if ns.code == NSURLErrorCancelled { return } // pause/delete handle their own state
        let id = d.id
        let data = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let msg = error.localizedDescription
        if let part = d.part {
            Task { @MainActor in self.partFailed(id, part: part, message: msg, resumeData: data) }
            return
        }
        Task { @MainActor in
            self.clearTransfer(id)
            self.mutate(id) {
                guard $0.state == .downloading else { return }
                $0.state = .failed
                $0.error = msg
                $0.resumeData = data
            }
            self.advance()
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let identifier = session.configuration.identifier
        Task { @MainActor in self.finishEvents(for: identifier) }
    }
}
