import Foundation
import Security
import Combine

/// One file in a TorBox or Offcloud download or torrent.
struct TorBoxFile: Codable, Hashable, Sendable {
    var id: Int
    var name: String          // the file's own name
    var size: Int64?
    var path: String?         // where it is in the torrent, e.g. "Show S01/Subs/English.srt"
    var link: URL? = nil      // Offcloud: the file's own download link
}

/// What TorBox fetches: a link from a file host, or a torrent (magnet link or .torrent file).
enum TorBoxKind: String, Codable, Hashable, Sendable {
    case web, torrent

    /// The API's folder for this kind: webdl/... or torrents/...
    var path: String { self == .web ? "webdl" : "torrents" }
    /// The ID parameter its download links use.
    var idParam: String { self == .web ? "web_id" : "torrent_id" }
}

/// A file sent in a multipart form (a .torrent upload).
struct FormFile {
    var field: String
    var name: String
    var type: String
    var data: Data
}

struct TorBoxWebDownload {
    var ready: Bool
    var failure: String?
    var progress: Double?
    var state: String
    var files: [TorBoxFile]
    var name = ""             // the torrent's (or download's) name on TorBox

    /// How far TorBox has fetched the file, 0...1 (nil until it reports progress).
    var fraction: Double? {
        guard let p = progress, p > 0 else { return nil }
        return min(p <= 1 ? p : p / 100, 1)
    }

    var statusText: String {
        if let p = progress, p > 0 {
            let pct = Int((p <= 1 ? p * 100 : p).rounded())
            return "TorBox is fetching it… \(min(pct, 100))%"
        }
        let lower = state.lowercased()
        if lower.isEmpty { return "Waiting for TorBox…" }
        if lower == "metadl" { return "TorBox is getting the torrent's details…" }
        if lower.contains("stalled") { return "TorBox: no seeds yet, still trying…" }
        if lower.contains("queued") { return "TorBox: queued…" }
        return "TorBox: \(state)"
    }
}

/// A download or torrent in your TorBox account (the TorBox Cloud screen).
struct TorBoxCloudItem: Identifiable, Hashable, Sendable {
    var kind: TorBoxKind
    var torboxID: Int
    var name: String
    var size: Int64?
    var addedAt: Date?
    var infoHash: String?         // torrents: their info hash
    var ready: Bool               // TorBox has every file
    var failure: String?
    var statusText: String
    var fraction: Double?
    var files: [TorBoxFile]

    var id: String { kind.rawValue + "-" + String(torboxID) }
}

enum TorBoxError: LocalizedError {
    case noKey
    case api(String)
    case gone

    var errorDescription: String? {
        switch self {
        case .noKey: return "No TorBox API key. Add it in ⋯ › TorBox."
        case .api(let message): return message
        case .gone: return "TorBox no longer has this download."
        }
    }
}

/// TorBox (torbox.app) used as a multi-hoster, like a TorBox account in JDownloader:
/// links from sites TorBox supports are sent to TorBox, which fetches them to its
/// servers, and the files are then downloaded from TorBox.
@MainActor
final class TorBox: ObservableObject {
    static let shared = TorBox()

    private static let base = "https://api.torbox.app/v1/api/"
    private static let keyAccount = "torbox.apikey"
    private static let enabledKey = "torbox.enabled"

    @Published private(set) var hasKey = false
    @Published private(set) var accountSummary: String?
    @Published private(set) var supportedSiteCount: Int?
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey) }
    }

    private var key: String?
    private var domains: Set<String> = []
    private var domainsLoadedAt: Date?
    private var hostersTask: Task<Void, Never>?
    private var nextCreateAt = Date.distantPast

    init() {
        _enabled = Published(wrappedValue: UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true)
        key = Keychain.read(Self.keyAccount)
        hasKey = key != nil
    }

    /// True when links from supported sites should go through TorBox.
    var isActive: Bool { enabled && key != nil }

    // MARK: API key

    /// Checks the key with TorBox and stores it only if it works.
    func saveKey(_ raw: String) async throws {
        let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { throw TorBoxError.noKey }
        let data = try await call("GET", "user/me", key: candidate)
        guard let profile = data as? [String: Any] else {
            throw TorBoxError.api("TorBox didn't return account details.")
        }
        Keychain.save(candidate, account: Self.keyAccount)
        key = candidate
        hasKey = true
        accountSummary = Self.summary(profile)
        domainsLoadedAt = nil
        await refreshHosters()
    }

    func removeKey() {
        Keychain.delete(Self.keyAccount)
        key = nil
        hasKey = false
        accountSummary = nil
    }

    func refreshAccount() async {
        guard key != nil else { accountSummary = nil; return }
        do {
            if let profile = try await call("GET", "user/me") as? [String: Any] {
                accountSummary = Self.summary(profile)
            }
        } catch {
            accountSummary = "Couldn't check the account: \(error.localizedDescription)"
        }
    }

    // MARK: Supported sites

    func supports(_ url: URL) async -> Bool {
        guard isActive, let host = url.host else { return false }
        if domains.isEmpty || Date().timeIntervalSince(domainsLoadedAt ?? .distantPast) > 6 * 3600 {
            await refreshHosters()
        }
        let h = Self.normalize(host)
        return domains.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    func refreshHosters() async {
        if let running = hostersTask {
            await running.value
            return
        }
        let task = Task { await self.loadHosters() }
        hostersTask = task
        await task.value
        hostersTask = nil
    }

    private func loadHosters() async {
        let raw: Any?
        do { raw = try await call("GET", "webdl/hosters", auth: key != nil) } catch { return }
        guard let list = raw as? [[String: Any]] else { return }
        var found = Set<String>()
        for hoster in list {
            for d in (hoster["domains"] as? [String]) ?? [] {
                let n = Self.normalize(d)
                if !n.isEmpty { found.insert(n) }
            }
            if let u = hoster["url"] as? String, let host = URL(string: u)?.host {
                found.insert(Self.normalize(host))
            }
        }
        guard !found.isEmpty else { return }
        domains = found
        domainsLoadedAt = Date()
        supportedSiteCount = list.count
    }

    // MARK: Adding links and torrents

    /// TorBox rate-limits adding downloads, so requests are spaced out.
    private func waitForAddSlot() async {
        let now = Date()
        let slot = max(now, nextCreateAt)
        nextCreateAt = slot.addingTimeInterval(1.5)
        let wait = slot.timeIntervalSince(now)
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
    }

    /// Adds a file-host link to TorBox and returns its web download ID.
    func create(link: URL) async throws -> Int {
        await waitForAddSlot()
        let data = try await call("POST", "webdl/createwebdownload", form: ["link": link.absoluteString])
        let object = data as? [String: Any]
        guard let id = Self.int(object?["webdownload_id"]) ?? Self.int(object?["id"]) else {
            throw TorBoxError.api("TorBox didn't return a download ID.")
        }
        return id
    }

    /// Adds a magnet link to TorBox and returns its torrent ID.
    func createTorrent(magnet: String) async throws -> Int {
        await waitForAddSlot()
        let data = try await call("POST", "torrents/createtorrent", form: ["magnet": magnet])
        return try Self.torrentID(in: data)
    }

    /// Uploads a .torrent file to TorBox and returns its torrent ID.
    func createTorrent(file: Data, name: String) async throws -> Int {
        await waitForAddSlot()
        let upload = FormFile(field: "file", name: name.hasSuffix(".torrent") ? name : name + ".torrent",
                              type: "application/x-bittorrent", data: file)
        let data = try await call("POST", "torrents/createtorrent", form: [:], files: [upload])
        return try Self.torrentID(in: data)
    }

    private static func torrentID(in data: Any?) throws -> Int {
        let object = data as? [String: Any]
        guard let id = int(object?["torrent_id"]) ?? int(object?["id"]) else {
            throw TorBoxError.api("TorBox didn't return a torrent ID.")
        }
        return id
    }

    // MARK: Status

    func status(_ kind: TorBoxKind, id: Int) async throws -> TorBoxWebDownload {
        let data = try await call("GET", kind.path + "/mylist", query: [
            URLQueryItem(name: "id", value: String(id)),
            URLQueryItem(name: "bypass_cache", value: "true")
        ])
        return try Self.parseWebDownload(data, id: id)
    }

    /// The status of every download of one kind on the account, by ID: one request for many.
    func statusList(_ kind: TorBoxKind) async throws -> [Int: TorBoxWebDownload] {
        let data = try await call("GET", kind.path + "/mylist", query: [URLQueryItem(name: "bypass_cache", value: "true")])
        var out: [Int: TorBoxWebDownload] = [:]
        for entry in (data as? [[String: Any]]) ?? [] {
            guard let id = Self.int(entry["id"]), let dl = try? Self.parseWebDownload(entry, id: id) else { continue }
            out[id] = dl
        }
        return out
    }

    /// The same status request as a plain URLRequest, for background checks while the app sleeps.
    func statusRequest(_ kind: TorBoxKind, id: Int) -> URLRequest? {
        guard let key else { return nil }
        var comps = URLComponents(string: Self.base + kind.path + "/mylist")
        comps?.queryItems = [
            URLQueryItem(name: "id", value: String(id)),
            URLQueryItem(name: "bypass_cache", value: "true")
        ]
        guard let url = comps?.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    /// Reads a whole status reply (as delivered to a background check).
    static func parseStatus(_ body: Data, id: Int) throws -> TorBoxWebDownload {
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            throw TorBoxError.api("Unexpected reply from TorBox.")
        }
        if (json["success"] as? Bool) == false {
            let detail = (json["detail"] as? String) ?? (json["error"] as? String) ?? "TorBox returned an error."
            throw TorBoxError.api(detail)
        }
        let payload = json["data"]
        return try parseWebDownload(payload is NSNull ? nil : payload, id: id)
    }

    private static func parseWebDownload(_ data: Any?, id: Int) throws -> TorBoxWebDownload {
        var object = data as? [String: Any]
        if object == nil, let list = data as? [[String: Any]] {
            object = list.first { Self.int($0["id"]) == id }
        }
        guard let o = object else { throw TorBoxError.gone }

        let state = (o["download_state"] as? String) ?? ""
        let present = o["download_present"] as? Bool
        let finished = (o["download_finished"] as? Bool) ?? false
        let rawFiles = (o["files"] as? [[String: Any]]) ?? []
        let files = rawFiles.compactMap { (f: [String: Any]) -> TorBoxFile? in
            guard let fileId = Self.int(f["id"]) else { return nil }
            let short = (f["short_name"] as? String) ?? ""
            let full = (f["name"] as? String) ?? ""
            var name = short.isEmpty ? (full as NSString).lastPathComponent : short
            if name.isEmpty { name = "file-\(fileId)" }
            return TorBoxFile(id: fileId, name: name, size: Self.int64(f["size"]),
                              path: full.isEmpty ? name : full)
        }

        var failure: String?
        let lower = state.lowercased()
        if lower.contains("error") || lower.contains("fail") {
            let message = (o["error"] as? String) ?? ""
            failure = message.isEmpty ? state : message
        }
        return TorBoxWebDownload(ready: !files.isEmpty && (present ?? finished),
                                 failure: failure,
                                 progress: Self.double(o["progress"]),
                                 state: state,
                                 files: files,
                                 name: (o["name"] as? String) ?? "")
    }

    // MARK: Your TorBox account

    /// Everything of one kind in your TorBox account, newest first.
    func cloud(_ kind: TorBoxKind) async throws -> [TorBoxCloudItem] {
        let data = try await call("GET", kind.path + "/mylist", query: [URLQueryItem(name: "bypass_cache", value: "true")])
        let list = ((data as? [[String: Any]]) ?? []).compactMap { Self.cloudItem($0, kind: kind) }
        return list.sorted { ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast) }
    }

    private static func cloudItem(_ o: [String: Any], kind: TorBoxKind) -> TorBoxCloudItem? {
        guard let id = int(o["id"]), let dl = try? parseWebDownload(o, id: id) else { return nil }
        let added = (o["created_at"] as? String).flatMap { Self.parseDate($0) }
        let hash = (o["hash"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return TorBoxCloudItem(kind: kind, torboxID: id,
                               name: dl.name.isEmpty ? "TorBox download \(id)" : dl.name,
                               size: int64(o["size"]), addedAt: added, infoHash: hash,
                               ready: dl.ready, failure: dl.failure, statusText: dl.statusText,
                               fraction: dl.fraction, files: dl.files)
    }

    /// Deletes a download or torrent from your TorBox account.
    func remove(_ kind: TorBoxKind, id: Int) async throws {
        if kind == .torrent {
            _ = try await call("POST", "torrents/controltorrent",
                               jsonBody: ["torrent_id": id, "operation": "delete", "all": false])
        } else {
            _ = try await call("POST", "webdl/controlwebdownload",
                               jsonBody: ["webdl_id": id, "operation": "delete", "all": false])
        }
    }

    /// A permanent TorBox link that redirects to a fresh download URL each time,
    /// so queued, paused and retried downloads never use an expired link.
    func permalink(_ kind: TorBoxKind, id: Int, fileId: Int) -> URL? {
        guard let key else { return nil }
        var comps = URLComponents(string: Self.base + kind.path + "/requestdl")
        comps?.queryItems = [
            URLQueryItem(name: "token", value: key),
            URLQueryItem(name: kind.idParam, value: String(id)),
            URLQueryItem(name: "file_id", value: String(fileId)),
            URLQueryItem(name: "zip_link", value: "false"),
            URLQueryItem(name: "redirect", value: "true")
        ]
        return comps?.url
    }

    // MARK: HTTP

    private func call(_ method: String, _ path: String,
                      query: [URLQueryItem] = [],
                      form: [String: String]? = nil,
                      files: [FormFile] = [],
                      jsonBody: [String: Any]? = nil,
                      key overrideKey: String? = nil,
                      auth: Bool = true) async throws -> Any? {
        var comps = URLComponents(string: Self.base + path)
        if !query.isEmpty { comps?.queryItems = query }
        guard let url = comps?.url else { throw TorBoxError.api("Bad TorBox URL.") }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if auth {
            guard let k = overrideKey ?? key else { throw TorBoxError.noKey }
            req.setValue("Bearer \(k)", forHTTPHeaderField: "Authorization")
        }
        if form != nil || !files.isEmpty {
            let boundary = "JDLite-\(UUID().uuidString)"
            req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            var body = Data()
            for (name, value) in form ?? [:] {
                body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
            }
            for file in files {
                let safeName = file.name.replacingOccurrences(of: "\"", with: "'")
                body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(file.field)\"; filename=\"\(safeName)\"\r\nContent-Type: \(file.type)\r\n\r\n".utf8))
                body.append(file.data)
                body.append(Data("\r\n".utf8))
            }
            body.append(Data("--\(boundary)--\r\n".utf8))
            req.httpBody = body
        } else if let jsonBody {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        }

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if status >= 400 || (json?["success"] as? Bool) == false {
            let detail = (json?["detail"] as? String) ?? ""
            let code = (json?["error"] as? String) ?? ""
            throw TorBoxError.api(!detail.isEmpty ? detail : (!code.isEmpty ? code : "HTTP \(status)"))
        }
        guard let json else { throw TorBoxError.api("Unexpected reply from TorBox (HTTP \(status)).") }
        let payload = json["data"]
        return payload is NSNull ? nil : payload
    }

    // MARK: Helpers

    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        if s.hasPrefix("*.") { s = String(s.dropFirst(2)) }
        if s.hasPrefix("www.") { s = String(s.dropFirst(4)) }
        return s
    }

    private static func summary(_ profile: [String: Any]) -> String {
        var parts: [String] = []
        if let email = profile["email"] as? String, !email.isEmpty { parts.append(email) }
        if let raw = profile["premium_expires_at"] as? String, let date = parseDate(raw) {
            parts.append(date > Date()
                ? "Premium until \(date.formatted(date: .abbreviated, time: .omitted))"
                : "No active plan")
        }
        return parts.isEmpty ? "Connected" : parts.joined(separator: " · ")
    }

    private static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    private static func int(_ v: Any?) -> Int? {
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) }
        return nil
    }

    private static func int64(_ v: Any?) -> Int64? {
        if let n = v as? NSNumber { return n.int64Value }
        if let s = v as? String { return Int64(s) }
        return nil
    }

    private static func double(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }
}

// MARK: - Keychain

enum Keychain {
    private static let service = "jdlite"
    private static let fallbackPrefix = "keychain-fallback."

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
           let data = out as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty {
            return value
        }
        // Some re-signing setups break the Keychain; fall back to app storage.
        return UserDefaults.standard.string(forKey: fallbackPrefix + account)
    }

    static func save(_ value: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let data = Data(value.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status == errSecSuccess {
            UserDefaults.standard.removeObject(forKey: fallbackPrefix + account)
        } else {
            UserDefaults.standard.set(value, forKey: fallbackPrefix + account)
        }
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: fallbackPrefix + account)
    }
}
