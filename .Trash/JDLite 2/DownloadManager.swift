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
    var needsResolve: Bool?          // true until plugins have had a look at the URL
    var preferredName: String?       // file name chosen by a plugin
    var progress: Double { bytesTotal > 0 ? Double(bytesReceived) / Double(bytesTotal) : 0 }
}

@MainActor
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var items: [DownloadItem] = []
    @Published var maxConcurrent = 3
    var backgroundCompletionHandler: (() -> Void)?

    private var session: URLSession!
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
        for url in urls where !items.contains(where: { $0.url == url && $0.state != .completed }) {
            var name = url.lastPathComponent
            if name.isEmpty || name == "/" { name = url.host ?? "download" }
            let item = DownloadItem(url: url,
                                    fileName: name.replacingOccurrences(of: "/", with: "_"),
                                    state: .resolving,
                                    needsResolve: true)
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
        guard let item = items.first(where: { $0.id == id }), item.state != .resolving else { return }
        if item.state == .queued { mutate(id) { $0.state = .paused }; return }
        let key = id.uuidString
        session.getTasksWithCompletionHandler { _, _, downloads in
            guard let t = downloads.first(where: { $0.taskDescription?.hasPrefix(key) == true }) else { return }
            t.cancel(byProducingResumeData: { data in
                Task { @MainActor in
                    self.mutate(id) { $0.resumeData = data; $0.state = .paused }
                    self.startNext()
                }
            })
        }
    }

    func remove(_ id: UUID) {
        let key = id.uuidString
        session.getTasksWithCompletionHandler { _, _, downloads in
            downloads.first(where: { $0.taskDescription?.hasPrefix(key) == true })?.cancel()
        }
        items.removeAll { $0.id == id }
        save()
        startNext()
    }

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

    // MARK: Plugin resolving

    private func runResolve(_ id: UUID) async {
        guard let item = items.first(where: { $0.id == id }) else { return }
        await PluginHost.shared.ensureLoaded()

        guard let plugin = PluginHost.shared.match(item.url) else {
            mutate(id) { $0.state = .queued; $0.needsResolve = nil }
            startNext()
            return
        }
        let account = AccountStore.shared.account(for: item.url, plugin: plugin)
        do {
            let links = try await PluginHost.shared.resolve(plugin: plugin, url: item.url, account: account)
            guard items.contains(where: { $0.id == id }) else { return } // removed while resolving
            let first = links[0]
            mutate(id) {
                $0.url = first.url
                $0.fileName = first.fileName ?? first.url.lastPathComponent
                $0.preferredName = first.fileName
                $0.headers = first.headers
                $0.state = .queued
                $0.needsResolve = nil
                $0.error = nil
            }
            for link in links.dropFirst() {
                items.append(DownloadItem(url: link.url,
                                          fileName: link.fileName ?? link.url.lastPathComponent,
                                          headers: link.headers,
                                          preferredName: link.fileName))
            }
            save()
            startNext()
        } catch {
            mutate(id) { $0.state = .failed; $0.error = error.localizedDescription }
        }
    }

    // MARK: Queue

    private func startNext() {
        var active = items.filter { $0.state == .downloading }.count
        for i in items.indices where active < maxConcurrent && items[i].state == .queued {
            begin(at: i)
            active += 1
        }
    }

    private func begin(at i: Int) {
        let item = items[i]
        let task: URLSessionDownloadTask
        if let data = item.resumeData {
            task = session.downloadTask(withResumeData: data)
        } else {
            var req = URLRequest(url: item.url)
            for (k, v) in item.headers ?? [:] { req.setValue(v, forHTTPHeaderField: k) }
            task = session.downloadTask(with: req)
        }
        var desc = item.id.uuidString
        if let n = item.preferredName, !n.isEmpty { desc += "\n" + n }
        task.taskDescription = desc
        task.resume()
        items[i].state = .downloading
        items[i].resumeData = nil
        items[i].error = nil
        save()
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
}

// MARK: - URLSession delegate (runs off the main actor)

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        guard let d = Self.parseDesc(downloadTask.taskDescription) else { return }
        let id = d.id
        Task { @MainActor in
            self.mutate(id, persist: false) {
                $0.bytesReceived = totalBytesWritten
                $0.bytesTotal = max(totalBytesExpectedToWrite, 0)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        guard let d = Self.parseDesc(downloadTask.taskDescription) else { return }
        let id = d.id

        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let code = http.statusCode
            Task { @MainActor in
                self.mutate(id) { $0.state = .failed; $0.error = "HTTP \(code)" }
                self.advance()
            }
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
            Task { @MainActor in
                self.mutate(id) {
                    $0.state = .completed
                    $0.fileName = finalName
                    $0.bytesReceived = size
                    $0.bytesTotal = size
                }
                self.advance()
            }
        } catch {
            let msg = error.localizedDescription
            Task { @MainActor in
                self.mutate(id) { $0.state = .failed; $0.error = msg }
                self.advance()
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let d = Self.parseDesc(task.taskDescription) else { return }
        let id = d.id
        let ns = error as NSError
        if ns.code == NSURLErrorCancelled { return } // pause/remove handle their own state
        let data = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let msg = error.localizedDescription
        Task { @MainActor in
            self.mutate(id) { $0.state = .failed; $0.error = msg; $0.resumeData = data }
            self.advance()
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in self.finishEvents() }
    }
}
