import Foundation

/// What a connection learned from the server's first reply to a new download.
struct TurboReply: Sendable {
    var total: Int64?            // the file's size, when the server says
    var acceptsRanges: Bool      // the file can be fetched in parts
    var finalURL: URL?           // where the file really is, after redirects
    var suggestedName: String?
    var namedByServer: Bool      // the server gave the file name (Content-Disposition)
    var isJSON: Bool
}

/// How one stretch of work (a "job") on a connection ended.
enum TurboOutcome: Sendable {
    case finished                          // every byte of the job is saved
    case incomplete                        // the server stopped early; carry on from where it got to
    case failed(String, retryable: Bool)
    case http(Int, String?)                // the server answered with an error status
    case webPage                           // a web page came back instead of the file
    case rangesIgnored                     // the server sent the whole file instead of the part
}

/// Creates an empty file if there isn't one yet. Never truncates an existing file, so
/// several connections can call it for the same file at the same time.
func ensureFileExists(_ url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let fd = open(url.path, O_WRONLY | O_CREAT, 0o644)
    if fd >= 0 { close(fd) }
}

/// One in-app connection. It downloads byte ranges of a file straight into the download's
/// data file at the right place, so nothing needs joining afterwards.
///
/// Each connection has its own URLSession. Sessions don't share network connections, so
/// the connections really run side by side, even to HTTP/2 servers (which would otherwise
/// squeeze every request into one connection).
final class TurboWorker: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// Marks a job whose end isn't known yet (a new download before the server replies).
    static let unknownEnd = Int64.max - 1

    let downloadID: UUID
    private let fileURL: URL
    private let lock = NSLock()

    // Everything below is guarded by `lock`.
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var handle: FileHandle?
    private var part: Int64?                 // start of the part being fetched (nil when idle)
    private var from: Int64 = 0              // first byte asked for
    private var position: Int64 = 0          // next byte to save
    private var end: Int64 = 0               // last byte wanted (inclusive)
    private var responseLast: Int64 = .max   // last byte the current reply will send
    private var synced: Int64 = 0            // bytes before this are safely on disk
    private var lastSync: TimeInterval = 0
    private var status = 0
    private var errorBody = Data()
    private var wantsReply = false
    private var reported = true              // the current job's outcome has been sent
    private var stopped = false

    init(downloadID: UUID, fileURL: URL) {
        self.downloadID = downloadID
        self.fileURL = fileURL
        super.init()
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 7 * 24 * 60 * 60
        config.httpMaximumConnectionsPerHost = 1
        config.waitsForConnectivity = false
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }

    // MARK: Controls (called by DownloadManager)

    /// Starts fetching bytes `from...end` of the part that begins at `part`.
    func start(part: Int64, from: Int64, end: Int64, request: URLRequest, reportReply: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, let session else { return }
        if handle == nil {
            ensureFileExists(fileURL)
            handle = try? FileHandle(forWritingTo: fileURL)
        }
        self.part = part
        self.from = from
        self.position = from
        self.end = end
        synced = from
        responseLast = .max
        status = 0
        errorBody = Data()
        wantsReply = reportReply
        reported = false
        lastSync = ProcessInfo.processInfo.systemUptime
        guard let handle, (try? handle.seek(toOffset: UInt64(from))) != nil else {
            finish(.failed("Couldn't open the file to save the download into.", retryable: false))
            return
        }
        var req = request
        req.setValue(end == Self.unknownEnd ? "bytes=\(from)-" : "bytes=\(from)-\(end)", forHTTPHeaderField: "Range")
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let newTask = session.dataTask(with: req)
        task = newTask
        newTask.resume()
    }

    /// The part this connection is fetching, if any.
    var currentPart: Int64? {
        lock.lock()
        defer { lock.unlock() }
        return reported ? nil : part
    }

    /// Bytes still to come for the current job (nil when idle or the size isn't known).
    var bytesLeft: Int64? {
        lock.lock()
        defer { lock.unlock() }
        guard !reported, !stopped, part != nil, end != Self.unknownEnd else { return nil }
        return end - position + 1
    }

    /// How far the current job has got: bytes written, and bytes safely on disk.
    var snapshot: (part: Int64, written: Int64, synced: Int64)? {
        lock.lock()
        defer { lock.unlock() }
        guard !reported, let part else { return nil }
        return (part: part, written: position, synced: synced)
    }

    /// Hands the second half of what's left of the current job to another connection.
    /// Returns the part this connection is on and the range it gave away.
    func giveAwayHalf(minimum: Int64) -> (part: Int64, start: Int64, end: Int64)? {
        lock.lock()
        defer { lock.unlock() }
        guard !reported, !stopped, let part, end != Self.unknownEnd else { return nil }
        let left = end - position + 1
        guard left >= minimum * 2 else { return nil }
        let cut = position + left / 2
        let oldEnd = end
        end = cut - 1
        return (part: part, start: cut, end: oldEnd)
    }

    /// Ends the current job early, after byte `newEnd`. Fails if it's already past that point.
    func shrink(toEnd newEnd: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !reported, !stopped, part != nil, position <= newEnd, newEnd < end else { return false }
        end = newEnd
        return true
    }

    /// Stops for good, keeping everything received. Returns the part it was on and how far it got.
    @discardableResult
    func stop() -> (part: Int64, position: Int64)? {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return nil }
        stopped = true
        var result: (part: Int64, position: Int64)?
        if !reported, let part { result = (part: part, position: position) }
        if let handle {
            try? handle.synchronize()
            try? handle.close()
        }
        handle = nil
        synced = position
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        part = nil
        reported = true
        return result
    }

    // MARK: URLSession delegate (runs on this connection's own queue)

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        guard dataTask === task, !reported, !stopped else {
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        let http = response as? HTTPURLResponse
        let code = http?.statusCode ?? 200
        status = code
        if code >= 400 {
            lock.unlock()
            completionHandler(.allow)   // keep the (small) body for the error message
            return
        }
        let mime = (response.mimeType ?? "").lowercased()
        if mime == "text/html" || mime == "application/xhtml+xml" {
            finish(.webPage)
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        var reply: TurboReply?
        if code == 206, let range = Self.contentRange(http) {
            guard range.first == from else {
                finish(.failed("The server sent the wrong part of the file.", retryable: true))
                lock.unlock()
                completionHandler(.cancel)
                return
            }
            responseLast = range.last
            if end == Self.unknownEnd { end = (range.total ?? range.last + 1) - 1 }
            if wantsReply {
                reply = TurboReply(total: range.total, acceptsRanges: true, finalURL: response.url,
                                   suggestedName: response.suggestedFilename,
                                   namedByServer: Self.namesFile(http), isJSON: mime.contains("json"))
            }
        } else if (200..<300).contains(code) {
            guard from == 0 else {
                finish(.rangesIgnored)
                lock.unlock()
                completionHandler(.cancel)
                return
            }
            let length = response.expectedContentLength
            if length >= 0 { responseLast = length - 1 }
            if end == Self.unknownEnd, length >= 0 { end = length - 1 }
            if wantsReply {
                let ranges = (http?.value(forHTTPHeaderField: "Accept-Ranges") ?? "").lowercased().contains("bytes")
                reply = TurboReply(total: length >= 0 ? length : nil, acceptsRanges: ranges && length > 0,
                                   finalURL: response.url, suggestedName: response.suggestedFilename,
                                   namedByServer: Self.namesFile(http), isJSON: mime.contains("json"))
            }
        } else {
            finish(.failed("The server answered with HTTP \(code).", retryable: true))
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        wantsReply = false
        lock.unlock()
        if let reply {
            Task { @MainActor in DownloadManager.shared.turboReply(self, reply) }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard dataTask === task, !reported, !stopped else { return }
        if status >= 400 {
            if errorBody.count < 65_536 { errorBody.append(data.prefix(65_536 - errorBody.count)) }
            return
        }
        guard let handle else { return }
        let wanted = end - position + 1
        guard wanted > 0 else {
            finish(.finished)
            return
        }
        let chunk = Int64(data.count) > wanted ? data.prefix(Int(wanted)) : data
        do {
            try handle.write(contentsOf: chunk)
        } catch {
            finish(.failed("Couldn't save the download. Check there's enough free space, then tap retry.",
                           retryable: false))
            return
        }
        position += Int64(chunk.count)
        if position > end {
            finish(.finished)
        } else {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastSync >= 2 {
                try? handle.synchronize()
                synced = position
                lastSync = now
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        guard task === self.task else { return }
        self.task = nil
        guard !reported, !stopped else { return }
        if status >= 400 {
            finish(.http(status, Self.message(in: errorBody)))
        } else if let error {
            finish(.failed(error.localizedDescription, retryable: Self.isRetryable(error)))
        } else if end == Self.unknownEnd {
            end = position - 1   // the whole file, of a size the server didn't say, has arrived
            finish(.finished)
        } else {
            finish(position > end ? .finished : .incomplete)
        }
    }

    // MARK: Helpers

    /// Ends the current job and tells the download manager. Call with `lock` held.
    private func finish(_ outcome: TurboOutcome) {
        guard !reported, let part else { return }
        reported = true
        if let handle { try? handle.synchronize() }
        synced = position
        // Stop the transfer unless the reply is complete anyway; finished replies leave the
        // connection open for this connection's next request.
        var replyComplete = false
        if case .finished = outcome, position > responseLast { replyComplete = true }
        if !replyComplete, let current = task {
            current.cancel()
            task = nil
        }
        self.part = nil
        let reachedPosition = position
        let reachedEnd = end
        Task { @MainActor in
            DownloadManager.shared.turboDone(self, part: part, outcome: outcome,
                                             position: reachedPosition, end: reachedEnd)
        }
    }

    /// Parses "Content-Range: bytes 0-1023/4096".
    static func contentRange(_ http: HTTPURLResponse?) -> (first: Int64, last: Int64, total: Int64?)? {
        guard let value = http?.value(forHTTPHeaderField: "Content-Range") else { return nil }
        let pieces = value.split(separator: " ", maxSplits: 1)
        guard pieces.count == 2, pieces[0].lowercased() == "bytes" else { return nil }
        let rangeAndTotal = pieces[1].split(separator: "/", maxSplits: 1)
        guard rangeAndTotal.count == 2 else { return nil }
        let bounds = rangeAndTotal[0].split(separator: "-", maxSplits: 1)
        guard bounds.count == 2,
              let first = Int64(bounds[0].trimmingCharacters(in: .whitespaces)),
              let last = Int64(bounds[1].trimmingCharacters(in: .whitespaces)),
              last >= first else { return nil }
        let total = Int64(rangeAndTotal[1].trimmingCharacters(in: .whitespaces))
        return (first: first, last: last, total: total)
    }

    /// True when the reply names the file (Content-Disposition: attachment; filename=...).
    static func namesFile(_ http: HTTPURLResponse?) -> Bool {
        (http?.value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased().contains("filename")
    }

    /// The message in a small JSON error reply, if there is one.
    static func message(in body: Data) -> String? {
        guard !body.isEmpty,
              let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return nil }
        let text = (json["detail"] as? String) ?? (json["error"] as? String) ?? (json["message"] as? String) ?? ""
        return text.isEmpty ? nil : text
    }

    /// Network hiccups are worth retrying; bad links and certificate problems aren't.
    static func isRetryable(_ error: Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return false }
        switch ns.code {
        case NSURLErrorBadURL, NSURLErrorUnsupportedURL, NSURLErrorUserAuthenticationRequired,
             NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateNotYetValid, NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorClientCertificateRejected, NSURLErrorClientCertificateRequired,
             NSURLErrorAppTransportSecurityRequiresSecureConnection, NSURLErrorFileDoesNotExist:
            return false
        default:
            return true
        }
    }
}
