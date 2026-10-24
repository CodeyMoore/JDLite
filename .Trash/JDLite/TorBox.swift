import Foundation
import Security
import Combine

struct TorBoxFile {
    var id: Int
    var name: String
}

struct TorBoxWebDownload {
    var ready: Bool
    var failure: String?
    var progress: Double?
    var state: String
    var files: [TorBoxFile]

    var statusText: String {
        if let p = progress, p > 0 {
            let pct = Int((p <= 1 ? p * 100 : p).rounded())
            return "TorBox is fetching it… \(min(pct, 100))%"
        }
        return state.isEmpty ? "Waiting for TorBox…" : "TorBox: \(state)"
    }
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

    // MARK: Web downloads

    /// Adds a link to TorBox and returns its web download ID.
    func create(link: URL) async throws -> Int {
        // TorBox rate-limits this endpoint, so space requests out.
        let now = Date()
        let slot = max(now, nextCreateAt)
        nextCreateAt = slot.addingTimeInterval(1.5)
        let wait = slot.timeIntervalSince(now)
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }

        let data = try await call("POST", "webdl/createwebdownload", form: ["link": link.absoluteString])
        let object = data as? [String: Any]
        guard let id = Self.int(object?["webdownload_id"]) ?? Self.int(object?["id"]) else {
            throw TorBoxError.api("TorBox didn't return a download ID.")
        }
        return id
    }

    func webDownload(id: Int) async throws -> TorBoxWebDownload {
        let data = try await call("GET", "webdl/mylist", query: [
            URLQueryItem(name: "id", value: String(id)),
            URLQueryItem(name: "bypass_cache", value: "true")
        ])
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
            let name = short.isEmpty ? (full as NSString).lastPathComponent : short
            return TorBoxFile(id: fileId, name: name.isEmpty ? "file-\(fileId)" : name)
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
                                 files: files)
    }

    /// A permanent TorBox link that redirects to a fresh download URL each time,
    /// so queued, paused and retried downloads never use an expired link.
    func permalink(webId: Int, fileId: Int) -> URL? {
        guard let key else { return nil }
        var comps = URLComponents(string: Self.base + "webdl/requestdl")
        comps?.queryItems = [
            URLQueryItem(name: "token", value: key),
            URLQueryItem(name: "web_id", value: String(webId)),
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
        if let form {
            let boundary = "JDLite-\(UUID().uuidString)"
            req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            var body = Data()
            for (name, value) in form {
                body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
            }
            body.append(Data("--\(boundary)--\r\n".utf8))
            req.httpBody = body
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
