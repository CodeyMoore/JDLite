import Foundation
import Combine
import CryptoKit

/// The premium services links and torrents can go through.
enum PremiumService: String, Codable, CaseIterable {
    case torbox, offcloud

    var name: String { self == .torbox ? "TorBox" : "Offcloud" }
}

enum OffcloudError: LocalizedError {
    case noKey
    case badKey
    case notAvailable(String)   // what Offcloud says the plan is missing
    case busy
    case notFound
    case gone
    case api(String)

    var errorDescription: String? {
        switch self {
        case .noKey: return "No Offcloud API key. Add it in ⋯ › Offcloud."
        case .badKey: return "Offcloud didn't accept the API key. Check it in ⋯ › Offcloud."
        case .notAvailable(let what):
            switch what.lowercased() {
            case "premium": return "This needs an Offcloud premium plan."
            case "links": return "Your Offcloud plan has no links left."
            case "proxy": return "This needs Offcloud's proxy add-on."
            case "cloud": return "This needs Offcloud's cloud add-on."
            case "video": return "This needs Offcloud's video add-on."
            default: return "Your Offcloud plan doesn't cover this (\(what))."
            }
        case .busy: return "Offcloud is busy (too many requests). Try again in a minute."
        case .notFound: return "Offcloud doesn't know that request."
        case .gone: return "Offcloud no longer has this download."
        case .api(let message): return message
        }
    }

    /// Worth trying Offcloud's cloud when an instant link didn't work.
    var triesCloud: Bool {
        switch self {
        case .api, .notFound: return true
        default: return false
        }
    }
}

/// How far Offcloud has got with fetching something to its cloud.
struct OffcloudStatus: Sendable {
    var state: String           // created, queued, downloading, downloaded, error, canceled
    var fileName = ""
    var server: String?
    var isDirectory: Bool?
    var link: URL?              // a single file's link, when Offcloud gives one
    var received: Int64?        // bytes Offcloud has so far
    var size: Int64?
    var percent: Double?
    var message: String?

    var ready: Bool { ["downloaded", "completed", "finished"].contains(state) }

    var failure: String? {
        guard ["error", "failed", "canceled", "cancelled", "dead", "expired"].contains(state) else { return nil }
        if let message, !message.isEmpty { return message }
        return state == "error" || state == "failed" ? "couldn't fetch it." : "the download was \(state)."
    }

    /// How far Offcloud has fetched it, 0...1 (nil until it says).
    var fraction: Double? {
        if let percent, percent > 0 { return min(percent <= 1 ? percent : percent / 100, 1) }
        if let received, let size, size > 0, received > 0 { return min(Double(received) / Double(size), 1) }
        return nil
    }

    var statusText: String {
        if let fraction { return "Offcloud is fetching it… \(Int((fraction * 100).rounded()))%" }
        switch state {
        case "", "created", "queued": return "Offcloud: queued…"
        case "downloading": return "Offcloud is fetching it…"
        default: return "Offcloud: \(state)"
        }
    }

    /// A single file's link: given by Offcloud, or made from its server and the file's name.
    func singleLink(_ requestId: String) -> URL? {
        if let link { return link }
        guard let server, !server.isEmpty, !fileName.isEmpty,
              let name = fileName.addingPercentEncoding(withAllowedCharacters: Self.pathSafe) else { return nil }
        return URL(string: "https://\(server).offcloud.com/cloud/download/\(requestId)/\(name)")
    }

    /// Characters a file name can keep in a link's path (anything else is escaped).
    static let pathSafe: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "/")
        return set
    }()
}

/// Offcloud (offcloud.com) used like TorBox: links from sites it supports are unlocked through
/// your account, and torrents are fetched to your Offcloud cloud, then downloaded from there.
///
/// Offcloud's API works with your API key. The email and password are kept too: with no key,
/// JDLite signs in with them to fetch it (if Offcloud still allows that).
@MainActor
final class Offcloud: ObservableObject {
    static let shared = Offcloud()

    private static let base = "https://offcloud.com/"
    private static let keyAccount = "offcloud.apikey"
    private static let emailAccount = "offcloud.email"
    private static let passwordAccount = "offcloud.password"
    private static let enabledKey = "offcloud.enabled"
    private static let formSafe = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    @Published private(set) var hasKey = false
    @Published private(set) var email: String?
    @Published private(set) var hasPassword = false
    @Published private(set) var accountSummary: String?
    @Published private(set) var supportedSiteCount: Int?
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey) }
    }

    private var key: String?
    private var domains: Set<String> = []
    private var cloudOnlySites: Set<String> = []
    private var sitesCheckedAt: Date?
    private var sitesTask: Task<Void, Never>?
    private var nextCallAt = Date.distantPast

    init() {
        _enabled = Published(wrappedValue: UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true)
        key = Keychain.read(Self.keyAccount)
        email = Keychain.read(Self.emailAccount)
        hasKey = key != nil
        hasPassword = Keychain.read(Self.passwordAccount) != nil
    }

    /// True when links and torrents may go through Offcloud.
    var isActive: Bool { enabled && key != nil }

    // MARK: Account

    /// Checks the account with Offcloud and stores it only if it works. With no API key typed
    /// in, it keeps the saved key, or (with none saved) signs in with the email and password
    /// to fetch it.
    func saveAccount(email rawEmail: String, password: String, key rawKey: String) async throws {
        let mail = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidate = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.isEmpty {
            if let saved = key {
                candidate = saved   // just the email or password changed
            } else if !mail.isEmpty && !password.isEmpty {
                candidate = try await fetchKey(email: mail, password: password)
            } else {
                throw OffcloudError.api("Enter your API key, or your email and password.")
            }
        }
        let info = try await checkKey(candidate)
        Keychain.save(candidate, account: Self.keyAccount)
        key = candidate
        hasKey = true
        if mail.isEmpty {
            Keychain.delete(Self.emailAccount)
            email = nil
        } else {
            Keychain.save(mail, account: Self.emailAccount)
            email = mail
        }
        if !password.isEmpty {
            Keychain.save(password, account: Self.passwordAccount)
            hasPassword = true
        }
        accountSummary = Self.summary(info, email: email)
        sitesCheckedAt = nil
        await refreshSites()
    }

    func removeAccount() {
        Keychain.delete(Self.keyAccount)
        Keychain.delete(Self.emailAccount)
        Keychain.delete(Self.passwordAccount)
        key = nil
        email = nil
        hasKey = false
        hasPassword = false
        accountSummary = nil
        domains = []
        cloudOnlySites = []
        sitesCheckedAt = nil
        supportedSiteCount = nil
    }

    func refreshAccount() async {
        guard let current = key else {
            accountSummary = nil
            return
        }
        do {
            let info = try await checkKey(current)
            accountSummary = Self.summary(info, email: email)
        } catch {
            accountSummary = "Couldn't check the account: " + error.localizedDescription
        }
    }

    /// Asks Offcloud about the account behind a key; fails if the key doesn't work.
    private func checkKey(_ candidate: String) async throws -> Any? {
        do {
            return try await call("GET", "api/account/info", key: candidate)
        } catch OffcloudError.notFound {
            // An older version of the API: the cloud history also needs a working key.
            _ = try await call("GET", "api/cloud/history", key: candidate)
            return nil
        }
    }

    /// Signs in with the email and password and asks Offcloud for the account's API key.
    private func fetchKey(email: String, password: String) async throws -> String {
        let session = URLSession(configuration: .ephemeral)   // keeps the sign-in cookie to itself
        defer { session.finishTasksAndInvalidate() }
        var signedIn = false
        var problem = "Offcloud didn't accept the sign-in. Paste your API key instead."
        for path in ["api/login/classic", "api/login"] {
            guard let url = URL(string: Self.base + path) else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 30
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Self.formBody(["username": email, "password": password])
            let (data, response) = try await session.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if status == 404 {
                problem = "Offcloud no longer lets apps sign in with a password. Copy your API key from offcloud.com › Account and paste it in."
                continue
            }
            if let message = json?["error"] as? String, !message.isEmpty {
                throw OffcloudError.api("Offcloud: " + message)
            }
            if (200..<300).contains(status), json?["userId"] != nil || json?["email"] != nil {
                signedIn = true
                break
            }
            problem = "Couldn't sign in to Offcloud (HTTP \(status)). Paste your API key instead."
        }
        guard signedIn else { throw OffcloudError.api(problem) }
        guard let keyURL = URL(string: Self.base + "api/key") else { throw OffcloudError.api("Bad Offcloud URL.") }
        var req = URLRequest(url: keyURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, _) = try await session.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let apiKey = json?["apiKey"] as? String, !apiKey.isEmpty else {
            throw OffcloudError.api("Signed in, but Offcloud didn't hand over the API key. Copy it from offcloud.com › Account and paste it in.")
        }
        return apiKey
    }

    // MARK: Supported sites

    /// True if Offcloud lists the link's site as working.
    func supports(_ url: URL) async -> Bool {
        guard isActive, let host = url.host else { return false }
        // Look again after 6 hours, or after 30 minutes if the list couldn't be loaded.
        let maxAge: TimeInterval = domains.isEmpty ? 1800 : 6 * 3600
        if Date().timeIntervalSince(sitesCheckedAt ?? .distantPast) > maxAge {
            await refreshSites()
        }
        return Self.matches(TorBox.normalize(host), in: domains)
    }

    /// Sites Offcloud only fetches to its cloud (it has no instant link for them).
    func onlyThroughCloud(_ url: URL) -> Bool {
        guard let host = url.host else { return false }
        return Self.matches(TorBox.normalize(host), in: cloudOnlySites)
    }

    func refreshSites() async {
        if let running = sitesTask {
            await running.value
            return
        }
        let task = Task { await self.loadSites() }
        sitesTask = task
        await task.value
        sitesTask = nil
    }

    /// Offcloud has moved its list of sites around over the years, so this tries each place.
    private func loadSites() async {
        defer { sitesCheckedAt = Date() }
        let places: [(method: String, path: String)] = [("GET", "api/sites"), ("GET", "api/sites/chunks"), ("POST", "stats/sites")]
        for place in places {
            guard let data = try? await call(place.method, place.path) else { continue }
            let found = Self.parseSites(data)
            guard !found.domains.isEmpty else { continue }
            domains = found.domains
            cloudOnlySites = found.cloudOnly
            supportedSiteCount = found.count
            return
        }
    }

    /// Reads a list of sites in any of the shapes Offcloud has used: plain names, or entries
    /// with a host, domain(s) or name and a health status.
    static func parseSites(_ data: Any) -> (domains: Set<String>, cloudOnly: Set<String>, count: Int) {
        var list: [Any] = []
        if let array = data as? [Any] {
            list = array
        } else if let object = data as? [String: Any] {
            for field in ["fs", "data", "sites", "hosts", "list"] {
                if let array = object[field] as? [Any] {
                    list = array
                    break
                }
            }
        }
        var domains = Set<String>()
        var cloudOnly = Set<String>()
        var count = 0
        for entry in list {
            var names: [String] = []
            var health = ""
            if let name = entry as? String {
                names = [name]
            } else if let site = entry as? [String: Any] {
                health = ((site["isActive"] as? String) ?? (site["status"] as? String) ?? "").lowercased()
                for field in ["host", "domain", "hostname", "url", "displayName", "name"] {
                    if let name = site[field] as? String { names.append(name) }
                }
                if let more = site["domains"] as? [String] { names += more }
            }
            if health == "dead" || health == "awaiting demand" { continue }
            let hosts = Set(names.map { TorBox.normalize($0) }.filter { $0.contains(".") && !$0.contains(" ") })
            guard !hosts.isEmpty else { continue }
            count += 1
            domains.formUnion(hosts)
            if health == "cloud only" { cloudOnly.formUnion(hosts) }
        }
        return (domains, cloudOnly, count)
    }

    private static func matches(_ host: String, in set: Set<String>) -> Bool {
        set.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    // MARK: Getting files

    /// A direct link for a file on a site Offcloud supports.
    func instant(_ link: URL) async throws -> (url: URL, fileName: String?) {
        let data = try await call("POST", "api/instant", form: ["url": link.absoluteString])
        let o = (data as? [String: Any]) ?? [:]
        guard let raw = o["url"] as? String, let url = Self.link(raw) else {
            let message = (o["errorMessage"] as? String) ?? (o["message"] as? String) ?? ""
            throw OffcloudError.api(message.isEmpty ? "Offcloud didn't return a download link." : message)
        }
        let name = (o["fileName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (url, name)
    }

    /// Adds a magnet link (or a link from a site Offcloud supports) to your Offcloud cloud.
    /// Returns its request ID.
    func addToCloud(_ link: String) async throws -> String {
        let data = try await call("POST", "api/cloud", json: ["url": link])
        let o = (data as? [String: Any]) ?? [:]
        guard let id = Self.text(o["requestId"]) else {
            throw OffcloudError.api("Offcloud didn't return a request ID.")
        }
        return id
    }

    func cloudStatus(_ requestId: String) async throws -> OffcloudStatus {
        let data: Any
        do {
            data = try await call("POST", "api/cloud/status", json: ["requestId": requestId, "requestIds": [requestId]])
        } catch OffcloudError.notFound {
            throw OffcloudError.gone
        } catch OffcloudError.api(let message) where message.lowercased().contains("not found") {
            throw OffcloudError.gone
        }
        guard let o = Self.statusObject(data, id: requestId) else { throw OffcloudError.gone }
        return Self.parseStatus(o)
    }

    /// The status for one request, from any of the reply shapes: the status itself, wrapped
    /// in "status", or in a "requests" list.
    static func statusObject(_ data: Any, id: String) -> [String: Any]? {
        if let list = data as? [[String: Any]] {
            return list.first { Self.text($0["requestId"]) == id } ?? list.first
        }
        guard let o = data as? [String: Any] else { return nil }
        if let inner = o["status"] as? [String: Any] { return inner }
        if let list = o["requests"] as? [[String: Any]] {
            return list.first { Self.text($0["requestId"]) == id } ?? list.first
        }
        return o
    }

    static func parseStatus(_ o: [String: Any]) -> OffcloudStatus {
        var status = OffcloudStatus(state: ((o["status"] as? String) ?? "").lowercased())
        status.fileName = (o["fileName"] as? String) ?? (o["name"] as? String) ?? ""
        status.server = o["server"] as? String
        status.isDirectory = o["isDirectory"] as? Bool
        status.link = (o["url"] as? String).flatMap { Self.link($0) }
        status.received = Self.int64(o["amount"]) ?? Self.int64(o["downloaded"]) ?? Self.int64(o["downloadedBytes"])
        status.size = Self.int64(o["fileSize"]) ?? Self.int64(o["size"]) ?? Self.int64(o["totalSize"])
        status.percent = Self.double(o["percentage"]) ?? Self.double(o["percent"]) ?? Self.double(o["progress"])
        status.message = (o["errorMessage"] as? String) ?? (o["error"] as? String) ?? (o["message"] as? String)
        return status
    }

    /// The files of something Offcloud has finished fetching, each with its own link.
    func cloudFiles(_ requestId: String, status: OffcloudStatus) async throws -> [TorBoxFile] {
        if status.isDirectory == false, let single = status.singleLink(requestId) {
            return [Self.singleFile(status, link: single)]
        }
        do {
            let data = try await call("GET", "api/cloud/explore/" + requestId,
                                      query: [URLQueryItem(name: "format", value: "detailed")])
            let files = Self.parseExplore(data, requestId: requestId)
            if !files.isEmpty { return files }
        } catch let error as OffcloudError {
            switch error {
            case .badKey, .busy: throw error
            default: break   // not a folder (a single file), or an older API: use the status's link
            }
        }
        if let single = status.singleLink(requestId) { return [Self.singleFile(status, link: single)] }
        throw OffcloudError.api("Offcloud didn't list the files.")
    }

    private static func singleFile(_ status: OffcloudStatus, link: URL) -> TorBoxFile {
        let fromLink = link.lastPathComponent.removingPercentEncoding ?? link.lastPathComponent
        let name = status.fileName.isEmpty ? fromLink : status.fileName
        return TorBoxFile(id: 0, name: name, size: status.size, path: name, link: link)
    }

    /// Reads the files in an explore reply: entries with a link, path, name and size, or just
    /// a list of links (whose paths then come from the links themselves).
    static func parseExplore(_ data: Any, requestId: String) -> [TorBoxFile] {
        var entries: [Any] = []
        if let o = data as? [String: Any] {
            entries = (o["files"] as? [Any]) ?? (o["data"] as? [Any]) ?? []
        } else if let list = data as? [Any] {
            entries = list
        }
        var files: [TorBoxFile] = []
        for entry in entries {
            var raw: String?
            var path: String?
            var name: String?
            var size: Int64?
            if let s = entry as? String {
                raw = s
            } else if let f = entry as? [String: Any] {
                raw = (f["url"] as? String) ?? (f["link"] as? String)
                path = (f["path"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                name = (f["name"] as? String) ?? (f["fileName"] as? String)
                size = Self.int64(f["size"])
            }
            guard let raw, let fileLink = Self.link(raw) else { continue }
            let fullPath = path ?? Self.linkPath(fileLink, requestId: requestId) ?? name ?? fileLink.lastPathComponent
            var fileName = (fullPath as NSString).lastPathComponent
            if fileName.isEmpty || fileName == "/" { fileName = name ?? "" }
            if fileName.isEmpty || fileName == "/" { fileName = "file-\(files.count + 1)" }
            files.append(TorBoxFile(id: files.count, name: fileName, size: size, path: fullPath, link: fileLink))
        }
        return files
    }

    /// A file's place in its torrent, read from its link: everything after the request ID.
    static func linkPath(_ link: URL, requestId: String) -> String? {
        let parts = link.pathComponents
        guard let k = parts.firstIndex(of: requestId), k + 1 < parts.count else { return nil }
        return parts[(k + 1)...].joined(separator: "/")
    }

    // MARK: HTTP

    /// Spaces requests a little apart, since Offcloud limits how fast they can come.
    private func pace() async {
        let now = Date()
        let slot = max(now, nextCallAt)
        nextCallAt = slot.addingTimeInterval(0.35)
        let wait = slot.timeIntervalSince(now)
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
    }

    /// One API request. The key goes as a Bearer token and as ?key=, which newer and older
    /// versions of Offcloud's API each expect.
    private func call(_ method: String, _ path: String,
                      query: [URLQueryItem] = [],
                      json body: [String: Any]? = nil,
                      form: [String: String]? = nil,
                      key overrideKey: String? = nil) async throws -> Any {
        guard let k = overrideKey ?? key else { throw OffcloudError.noKey }
        var comps = URLComponents(string: Self.base + path)
        comps?.queryItems = query + [URLQueryItem(name: "key", value: k)]
        guard let url = comps?.url else { throw OffcloudError.api("Bad Offcloud URL.") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(k)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        } else if let form {
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Self.formBody(form)
        }
        await pace()
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        let object = parsed as? [String: Any]
        let problem = Self.errorText(object)
        if status == 401 || status == 403 || Self.isAuthError(problem) { throw OffcloudError.badKey }
        if status == 402 { throw OffcloudError.notAvailable((object?["not_available"] as? String) ?? "premium") }
        if status == 429 { throw OffcloudError.busy }
        if let what = object?["not_available"] as? String, !what.isEmpty { throw OffcloudError.notAvailable(what) }
        if status == 404 { throw OffcloudError.notFound }
        if let problem { throw OffcloudError.api(problem) }
        if status >= 400 { throw OffcloudError.api("Offcloud returned HTTP \(status).") }
        guard let parsed else { throw OffcloudError.api("Unexpected reply from Offcloud (HTTP \(status)).") }
        return parsed
    }

    private static func errorText(_ o: [String: Any]?) -> String? {
        guard let o else { return nil }
        if let error = o["error"] as? String, !error.isEmpty { return error }
        if (o["success"] as? Bool) == false || o["code"] != nil, let message = o["message"] as? String, !message.isEmpty {
            return message
        }
        return nil
    }

    private static func isAuthError(_ text: String?) -> Bool {
        guard let t = text?.uppercased() else { return false }
        return t.contains("NOAUTH") || t.contains("UNAUTHORIZED") || t.contains("INVALID API KEY") || t.contains("INVALID KEY")
    }

    private static func summary(_ info: Any?, email: String?) -> String {
        let o = (info as? [String: Any]) ?? [:]
        var parts: [String] = []
        if let mail = (o["email"] as? String) ?? email, !mail.isEmpty { parts.append(mail) }
        let premium = (o["is_premium"] as? Bool) ?? (o["isPremium"] as? Bool)
        let expiry = (o["expiration_date"] as? String) ?? (o["expirationDate"] as? String)
        if let expiry, let date = parseDay(expiry) {
            parts.append(date > Date()
                ? "Premium until \(date.formatted(date: .abbreviated, time: .omitted))"
                : "Plan expired")
        } else if let premium {
            parts.append(premium ? "Premium" : "Free account")
        }
        return parts.isEmpty ? "Connected" : parts.joined(separator: " · ")
    }

    private static func parseDay(_ s: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(identifier: "UTC")
        day.dateFormat = "yyyy-MM-dd"
        return day.date(from: String(s.prefix(10)))
    }

    private static func formBody(_ fields: [String: String]) -> Data {
        let pairs = fields.map { name, value in
            (name.addingPercentEncoding(withAllowedCharacters: formSafe) ?? name) + "="
                + (value.addingPercentEncoding(withAllowedCharacters: formSafe) ?? value)
        }
        return Data(pairs.joined(separator: "&").utf8)
    }

    /// A link from one of Offcloud's replies (escaped if it has spaces or the like).
    static func link(_ raw: String) -> URL? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.lowercased().hasPrefix("http") else { return nil }
        if let url = URL(string: s) { return url }
        return s.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap { URL(string: $0) }
    }

    static func text(_ v: Any?) -> String? {
        if let s = v as? String, !s.isEmpty { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    private static func int64(_ v: Any?) -> Int64? {
        if let n = v as? NSNumber { return n.int64Value }
        if let s = v as? String { return Int64(s) }
        return nil
    }

    private static func double(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s.replacingOccurrences(of: "%", with: "")) }
        return nil
    }
}

// MARK: - Magnet links from .torrent files

/// Makes a magnet link from a .torrent file (its info hash, name and trackers), for services
/// that take magnet links but not .torrent files.
enum TorrentMagnet {
    static func from(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        var reader = BencodeReader(bytes: bytes)
        guard let top = reader.read(), let info = top.value(for: "info"), info.isDictionary else { return nil }
        let digest = Insecure.SHA1.hash(data: Data(bytes[info.range]))
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        var link = "magnet:?xt=urn:btih:" + hash
        if let name = info.value(for: "name.utf-8")?.text ?? info.value(for: "name")?.text, !name.isEmpty {
            link += "&dn=" + encode(name)
        }
        var trackers: [String] = []
        if let main = top.value(for: "announce")?.text, !main.isEmpty { trackers.append(main) }
        for tier in top.value(for: "announce-list")?.items ?? [] {
            for tracker in tier.items {
                if let t = tracker.text, !t.isEmpty, !trackers.contains(t) { trackers.append(t) }
            }
        }
        for tracker in trackers.prefix(20) { link += "&tr=" + encode(tracker) }
        return link
    }

    private static let safe = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    private static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: safe) ?? s
    }
}

/// A bencoded value (the format of .torrent files) and where it sits in the file.
private struct BencodeValue {
    enum Kind {
        case number(Int64)
        case text([UInt8])
        case list([BencodeValue])
        case dictionary([(key: String, value: BencodeValue)])
    }

    let kind: Kind
    let range: Range<Int>

    var isDictionary: Bool {
        if case .dictionary = kind { return true }
        return false
    }

    func value(for key: String) -> BencodeValue? {
        guard case .dictionary(let entries) = kind else { return nil }
        return entries.first(where: { $0.key == key })?.value
    }

    var text: String? {
        guard case .text(let bytes) = kind else { return nil }
        return String(bytes: bytes, encoding: .utf8)
    }

    var items: [BencodeValue] {
        guard case .list(let values) = kind else { return [] }
        return values
    }
}

private struct BencodeReader {
    let bytes: [UInt8]
    var position = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func read(depth: Int = 0) -> BencodeValue? {
        guard depth < 50, position < bytes.count else { return nil }
        let start = position
        switch bytes[position] {
        case UInt8(ascii: "i"):
            position += 1
            guard let end = bytes[position...].firstIndex(of: UInt8(ascii: "e")) else { return nil }
            let number = Int64(String(decoding: bytes[position..<end], as: UTF8.self)) ?? 0
            position = end + 1
            return BencodeValue(kind: .number(number), range: start..<position)
        case UInt8(ascii: "l"):
            position += 1
            var values: [BencodeValue] = []
            while position < bytes.count, bytes[position] != UInt8(ascii: "e") {
                guard let value = read(depth: depth + 1) else { return nil }
                values.append(value)
            }
            guard position < bytes.count else { return nil }
            position += 1
            return BencodeValue(kind: .list(values), range: start..<position)
        case UInt8(ascii: "d"):
            position += 1
            var entries: [(key: String, value: BencodeValue)] = []
            while position < bytes.count, bytes[position] != UInt8(ascii: "e") {
                guard let key = read(depth: depth + 1), case .text(let keyBytes) = key.kind,
                      let value = read(depth: depth + 1) else { return nil }
                entries.append((key: String(decoding: keyBytes, as: UTF8.self), value: value))
            }
            guard position < bytes.count else { return nil }
            position += 1
            return BencodeValue(kind: .dictionary(entries), range: start..<position)
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            guard let colon = bytes[position...].firstIndex(of: UInt8(ascii: ":")),
                  let length = Int(String(decoding: bytes[position..<colon], as: UTF8.self)),
                  length >= 0, length <= bytes.count - (colon + 1) else { return nil }
            let text = Array(bytes[(colon + 1)..<(colon + 1 + length)])
            position = colon + 1 + length
            return BencodeValue(kind: .text(text), range: start..<position)
        default:
            return nil
        }
    }
}
