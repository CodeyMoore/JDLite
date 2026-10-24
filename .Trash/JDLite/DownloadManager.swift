import Foundation
import Combine

enum DownloadState: String, Codable { case queued, downloading, paused, completed, failed }

struct DownloadItem: Identifiable, Codable {
    var id = UUID()
    var url: URL
    var fileName: String
    var state: DownloadState = .queued
    var bytesReceived: Int64 = 0
    var bytesTotal: Int64 = 0
    var resumeData: Data?
    var error: String?
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
        for url in urls where !items.contains(where: { $0.url == url && $0.state != .completed }) {
            var name = url.lastPathComponent
            if name.isEmpty || name == "/" { name = url.host ?? "download" }
            items.append(DownloadItem(url: url, fileName: name.replacingOccurrences(of: "/", with: "_")))
        }
        save()
        startNext()
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
        mutate(id) { $0.state = .queued }
        startNext()
    }

    func pause(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        if item.state == .queued { mutate(id) { $0.state = .paused }; return }
        let key = id.uuidString
        session.getTasksWithCompletionHandler { _, _, downloads in
            guard let t = downloads.first(where: { $0.taskDescription == key }) else { return }
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
            downloads.first(where: { $0.taskDescription == key })?.cancel()
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
            task = session.downloadTask(with: item.url)
        }
        task.taskDescription = item.id.uuidString
        task.resume()
        items[i].state = .downloading
        items[i].resumeData = nil
        items[i].error = nil
        save()
    }

    private func reconcile() {
        session.getTasksWithCompletionHandler { _, _, downloads in
            let live = Set(downloads.compactMap { $0.taskDescription })
            Task { @MainActor in
                for i in self.items.indices
                where self.items[i].state == .downloading && !live.contains(self.items[i].id.uuidString) {
                    self.items[i].state = .queued
                }
                self.save()
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
        guard let s = downloadTask.taskDescription, let id = UUID(uuidString: s) else { return }
        Task { @MainActor in
            self.mutate(id, persist: false) {
                $0.bytesReceived = totalBytesWritten
                $0.bytesTotal = max(totalBytesExpectedToWrite, 0)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        guard let s = downloadTask.taskDescription, let id = UUID(uuidString: s) else { return }

        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let code = http.statusCode
            Task { @MainActor in
                self.mutate(id) { $0.state = .failed; $0.error = "HTTP \(code)" }
                self.advance()
            }
            return
        }

        // The temp file is deleted when this method returns, so move it now.
        let name = (downloadTask.response?.suggestedFilename ?? "download")
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
        guard let error, let s = task.taskDescription, let id = UUID(uuidString: s) else { return }
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
