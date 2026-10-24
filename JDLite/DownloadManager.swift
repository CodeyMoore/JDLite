import Foundation
import Combine

enum DownloadState: String, Codable { case queued, resolving, downloading, paused, completed, failed }

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
    var status: String?              // progress note while resolving
    var sourceURL: URL?              // the link as it was added
    var torboxId: Int?               // TorBox web download ID
    var torboxFileId: Int?           // file inside that TorBox download
    var cloudProgress: Double?       // how far TorBox has fetched the file (0...1)
    var savedName: String?           // file name in Downloads once finished
    var addedAt: Date?
    var completedAt: Date?

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
    @Published var maxConcurrent = 3
    var backgroundCompletionHandler: (() -> Void)?

    private var session: URLSession!
    private var torboxPoller: Task<Void, Never>?
    private var samples: [UUID: (time: TimeInterval, bytes: Int64)] = [:]
    private let storeURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("downloads.json")
    }()

    override init() {
        super.init()
        let cfg = URLSessionConfiguration.background(
            withIdentifier: "\(Bundle.main.bundleIdentifier ?? "jdlite").downloads")
        cfg.sessionSendsLaunchEvents = true
        cfg.isDiscretionary = false
        cfg.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        load()
        reconcile()
    }

    // MARK: Public API

    func add(urls: [URL]) {
        var ids: [UUID] = []
        for url in urls where !items.contains(where: { ($0.sourceURL ?? $0.url) == url && $0.state != .completed }) {
            var name = url.lastPathComponent
            if name.isEmpty || name == "/" { name = url.host ?? "download" }
            var item = DownloadItem(url: url, fileName: name.replacingOccurrences(of: "/", with: "_"))
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
            mutate(id) { $0.state = .queued; $0.error = nil }
            startNext()
        }
    }

    func pause(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        switch item.state {
        case .queued, .resolving:
            mutate(id) { $0.state = .paused; $0.status = nil }
        case .downloading:
            let key = id.uuidString
            session.getTasksWithCompletionHandler { _, _, downloads in
                guard let t = downloads.first(where: { $0.taskDescription?.hasPrefix(key) == true }) else { return }
                t.cancel(byProducingResumeData: { data in
                    Task { @MainActor in
                        self.clearTransfer(id)
                        self.mutate(id) { $0.resumeData = data; $0.state = .paused }
                        self.startNext()
                    }
                })
            }
        default:
            break
        }
    }

    /// Removes downloads from the list and deletes their files: the finished file,
    /// or whatever was downloaded so far.
    func delete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        session.getTasksWithCompletionHandler { _, _, downloads in
            for task in downloads {
                if let d = Self.parseDesc(task.taskDescription), ids.contains(d.id) { task.cancel() }
            }
        }
        let remaining = items.filter { !ids.contains($0.id) }
        let stillUsed = Set(remaining.compactMap { $0.savedFileName })
        for item in items where ids.contains(item.id) {
            clearTransfer(item.id)
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
            $0.fileName = first.fileName ?? first.url.lastPathComponent
            $0.preferredName = first.fileName
            $0.headers = first.headers
            $0.sourceURL = origin
            $0.state = .queued
            $0.needsResolve = nil
            $0.status = nil
            $0.error = nil
        }
        for link in links.dropFirst() {
            var extra = DownloadItem(url: link.url, fileName: link.fileName ?? link.url.lastPathComponent)
            extra.headers = link.headers
            extra.preferredName = link.fileName
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
            $0.fileName = first.name
            $0.preferredName = first.name
            $0.sourceURL = origin
            if let size = first.size, size > 0 { $0.bytesTotal = size }
            $0.cloudProgress = nil
            $0.state = .queued
            $0.needsResolve = nil
            $0.status = nil
            $0.error = nil
        }
        for file in files.dropFirst() {
            var extra = DownloadItem(url: origin, fileName: file.name)
            extra.preferredName = file.name
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

    @discardableResult
    private func begin(at i: Int) -> Bool {
        let item = items[i]
        let task: URLSessionDownloadTask
        if let data = item.resumeData {
            task = session.downloadTask(withResumeData: data)
        } else {
            var target = item.url
            if let webId = item.torboxId, let fileId = item.torboxFileId {
                guard let link = TorBox.shared.permalink(webId: webId, fileId: fileId) else {
                    items[i].state = .failed
                    items[i].error = TorBoxError.noKey.errorDescription
                    save()
                    return false
                }
                target = link
            }
            var req = URLRequest(url: target)
            for (k, v) in item.headers ?? [:] { req.setValue(v, forHTTPHeaderField: k) }
            task = session.downloadTask(with: req)
        }
        var desc = item.id.uuidString
        if let n = item.preferredName, !n.isEmpty { desc += "\n" + n }
        task.taskDescription = desc
        clearTransfer(item.id)
        task.resume()
        items[i].state = .downloading
        items[i].resumeData = nil
        items[i].error = nil
        items[i].status = nil
        save()
        return true
    }

    private func reconcile() {
        session.getTasksWithCompletionHandler { _, _, downloads in
            let live = Set(downloads.compactMap { Self.parseDesc($0.taskDescription)?.id })
            Task { @MainActor in
                var toResolve: [UUID] = []
                for i in self.items.indices {
                    let it = self.items[i]
                    if it.state == .downloading && !live.contains(it.id) { self.items[i].state = .queued }
                    if it.state == .resolving { toResolve.append(it.id) }
                }
                self.save()
                for id in toResolve { Task { await self.runResolve(id) } }
                self.startNext()
            }
        }
    }

    fileprivate func mutate(_ id: UUID, persist: Bool = true, _ body: (inout DownloadItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        body(&items[i])
        if persist { save() }
    }

    fileprivate func finishEvents() {
        backgroundCompletionHandler?()
        backgroundCompletionHandler = nil
    }

    fileprivate func advance() { startNext() }

    // MARK: Transfer updates (called from the URLSession delegate)

    fileprivate func progressed(_ id: UUID, written: Int64, expected: Int64) {
        let now = ProcessInfo.processInfo.systemUptime
        if let last = samples[id] {
            let dt = now - last.time
            if dt < 0.5 { return }   // at most two screen updates a second per download
            let instant = max(0, Double(written - last.bytes) / dt)
            speeds[id] = speeds[id].map { $0 * 0.6 + instant * 0.4 } ?? instant
        }
        samples[id] = (time: now, bytes: written)
        mutate(id, persist: false) {
            $0.bytesReceived = written
            if expected > 0 { $0.bytesTotal = expected }
        }
    }

    fileprivate func clearTransfer(_ id: UUID) {
        samples[id] = nil
        speeds[id] = nil
    }

    fileprivate func finished(_ id: UUID, savedName: String, size: Int64) {
        clearTransfer(id)
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

    nonisolated static func parseDesc(_ s: String?) -> (id: UUID, name: String?)? {
        guard let s else { return nil }
        let parts = s.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first, let id = UUID(uuidString: String(first)) else { return nil }
        return (id, parts.count > 1 ? String(parts[1]) : nil)
    }

    nonisolated static var downloadsDir: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
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
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
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
        guard let d = Self.parseDesc(downloadTask.taskDescription) else { return }
        let id = d.id
        Task { @MainActor in
            self.progressed(id, written: totalBytesWritten, expected: totalBytesExpectedToWrite)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        guard let d = Self.parseDesc(downloadTask.taskDescription) else { return }
        let id = d.id

        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let code = http.statusCode
            let detail = Self.smallJSON(at: location).flatMap { Self.message(in: $0) }
            let message = detail.map { "HTTP \(code): \($0)" } ?? "HTTP \(code)"
            Task { @MainActor in self.downloadFailed(id, message: message) }
            return
        }

        // A web page instead of a file (e.g. a file hoster's download page): don't save it.
        let mime = downloadTask.response?.mimeType?.lowercased() ?? ""
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
        let name = (hint ?? downloadTask.response?.suggestedFilename ?? "download")
            .replacingOccurrences(of: "/", with: "_")
        let dest = Self.uniqueURL(for: name)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
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
        let id = d.id
        let ns = error as NSError
        if ns.code == NSURLErrorCancelled { return } // pause/delete handle their own state
        let data = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let msg = error.localizedDescription
        Task { @MainActor in
            self.clearTransfer(id)
            self.mutate(id) { $0.state = .failed; $0.error = msg; $0.resumeData = data }
            self.advance()
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in self.finishEvents() }
    }
}
