import Foundation
import JavaScriptCore

struct PluginInfo: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var version: String
    var hosts: [String]
    var pattern: String?
    var accounts: Bool
    var file: String
}

struct ResolvedLink: Decodable {
    var url: URL
    var fileName: String?
    var headers: [String: String]?
}

enum PluginError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

// MARK: - Cookies (per resolve call, so logins never leak between plugins)

final class CookieJar {
    private var cookies: [HTTPCookie] = []
    private let lock = NSLock()

    func header(for url: URL) -> String? {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        let host = url.host?.lowercased() ?? ""
        let path = url.path.isEmpty ? "/" : url.path
        let matching = cookies.filter { c in
            if let e = c.expiresDate, e < now { return false }
            if c.isSecure && url.scheme != "https" { return false }
            let d = c.domain.lowercased()
            let dom = d.hasPrefix(".") ? String(d.dropFirst()) : d
            guard host == dom || host.hasSuffix("." + dom) else { return false }
            return c.path == "/" || path.hasPrefix(c.path)
        }
        return matching.isEmpty ? nil : HTTPCookie.requestHeaderFields(with: matching)["Cookie"]
    }

    func store(_ resp: HTTPURLResponse, for url: URL) {
        var fields: [String: String] = [:]
        for (k, v) in resp.allHeaderFields { if let k = k as? String, let v = v as? String { fields[k] = v } }
        let new = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        lock.lock(); defer { lock.unlock() }
        for c in new {
            cookies.removeAll { $0.name == c.name && $0.domain == c.domain && $0.path == c.path }
            cookies.append(c)
        }
    }
}

// MARK: - HTTP for plugins (manual redirects so Set-Cookie on every hop is kept)

final class PluginHTTP: NSObject, URLSessionTaskDelegate {
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    private struct Opts: Decodable {
        var method: String?
        var url: String
        var headers: [String: String]?
        var body: String?
        var follow: Bool?
    }

    private let session: URLSession
    private var jars: [String: CookieJar] = [:]
    private let lock = NSLock()

    override init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        cfg.httpCookieStorage = nil
        cfg.urlCache = nil
        cfg.timeoutIntervalForRequest = 30
        session = URLSession(configuration: cfg)
        super.init()
    }

    func makeJar(_ id: String) { lock.lock(); jars[id] = CookieJar(); lock.unlock() }
    func dropJar(_ id: String) { lock.lock(); jars[id] = nil; lock.unlock() }

    private func jar(_ id: String) -> CookieJar {
        lock.lock(); defer { lock.unlock() }
        if let j = jars[id] { return j }
        let j = CookieJar(); jars[id] = j; return j
    }

    func cookieHeader(callId: String, url: String) -> String {
        guard let u = URL(string: url) else { return "" }
        return jar(callId).header(for: u) ?? ""
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // we follow redirects ourselves
    }

    func perform(callId: String, optsJSON: String) async throws -> String {
        let o = try JSONDecoder().decode(Opts.self, from: Data(optsJSON.utf8))
        guard var url = URL(string: o.url), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw PluginError.message("Invalid URL: \(o.url)")
        }
        var method = (o.method ?? "GET").uppercased()
        var body = o.body.map { Data($0.utf8) }
        let jar = self.jar(callId)
        var hops = 0

        while true {
            var req = URLRequest(url: url)
            req.httpMethod = method
            req.httpBody = body
            req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            for (k, v) in o.headers ?? [:] { req.setValue(v, forHTTPHeaderField: k) }
            if let c = jar.header(for: url) {
                let existing = req.value(forHTTPHeaderField: "Cookie")
                req.setValue(existing.map { $0 + "; " + c } ?? c, forHTTPHeaderField: "Cookie")
            }

            let (data, resp) = try await session.data(for: req, delegate: self)
            guard let http = resp as? HTTPURLResponse else { throw PluginError.message("Not an HTTP response") }
            jar.store(http, for: url)
            let status = http.statusCode

            if o.follow != false, [301, 302, 303, 307, 308].contains(status), hops < 10,
               let loc = http.value(forHTTPHeaderField: "Location"),
               let next = URL(string: loc, relativeTo: url)?.absoluteURL {
                if status == 303 || ((status == 301 || status == 302) && method == "POST") { method = "GET"; body = nil }
                url = next
                hops += 1
                continue
            }

            var headers: [String: String] = [:]
            for (k, v) in http.allHeaderFields { if let k = k as? String, let v = v as? String { headers[k.lowercased()] = v } }
            let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
            let out: [String: Any] = ["status": status, "headers": headers, "body": text, "url": url.absoluteString]
            return String(data: try JSONSerialization.data(withJSONObject: out), encoding: .utf8) ?? "{}"
        }
    }
}

// MARK: - JavaScriptCore host (everything JS happens on one serial queue)

private final class OnceBox { var done = false }

final class JSRuntime {
    private let queue = DispatchQueue(label: "jdlite.js")
    private var context: JSContext?
    private let http = PluginHTTP()
    var onLog: ((String) -> Void)?

    func load(_ sources: [(file: String, code: String)]) async -> (infos: [PluginInfo], errors: [String]) {
        await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: self.loadSync(sources)) }
        }
    }

    private func loadSync(_ sources: [(file: String, code: String)]) -> (infos: [PluginInfo], errors: [String]) {
        var errors: [String] = []
        var current = "prelude"
        let ctx = JSContext()!
        ctx.exceptionHandler = { _, exc in errors.append("\(current): \(exc?.toString() ?? "unknown error")") }

        let httpFn: @convention(block) (String, String, JSValue) -> Void = { [weak self] callId, optsJSON, cb in
            guard let self else { return }
            Task {
                do {
                    let out = try await self.http.perform(callId: callId, optsJSON: optsJSON)
                    self.queue.async { _ = cb.call(withArguments: [NSNull(), out]) }
                } catch {
                    let msg = error.localizedDescription
                    self.queue.async { _ = cb.call(withArguments: [msg, NSNull()]) }
                }
            }
        }
        let cookieFn: @convention(block) (String, String) -> String = { [weak self] callId, url in
            self?.http.cookieHeader(callId: callId, url: url) ?? ""
        }
        let logFn: @convention(block) (String, String) -> Void = { [weak self] id, msg in
            self?.onLog?("[\(id)] \(msg)")
        }
        let sleepFn: @convention(block) (Double, JSValue) -> Void = { [weak self] ms, cb in
            guard let self else { return }
            self.queue.asyncAfter(deadline: .now() + ms / 1000) { _ = cb.call(withArguments: []) }
        }
        ctx.setObject(unsafeBitCast(httpFn, to: AnyObject.self), forKeyedSubscript: "__http" as NSString)
        ctx.setObject(unsafeBitCast(cookieFn, to: AnyObject.self), forKeyedSubscript: "__cookieHeader" as NSString)
        ctx.setObject(unsafeBitCast(logFn, to: AnyObject.self), forKeyedSubscript: "__log" as NSString)
        ctx.setObject(unsafeBitCast(sleepFn, to: AnyObject.self), forKeyedSubscript: "__sleep" as NSString)

        ctx.evaluateScript(Self.prelude, withSourceURL: URL(string: "jdlite://prelude"))
        for s in sources {
            current = s.file
            ctx.setObject(s.file, forKeyedSubscript: "__currentFile" as NSString)
            ctx.evaluateScript(s.code, withSourceURL: URL(string: "plugin://\(s.file)"))
        }

        var infos: [PluginInfo] = []
        if let json = ctx.objectForKeyedSubscript("__meta")?.call(withArguments: [])?.toString(),
           let decoded = try? JSONDecoder().decode([PluginInfo].self, from: Data(json.utf8)) {
            infos = decoded
        }
        context = ctx
        return (infos, errors)
    }

    func resolve(pluginId: String, url: String, accountJSON: String?) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                guard let ctx = self.context, let fn = ctx.objectForKeyedSubscript("__resolve") else {
                    cont.resume(throwing: PluginError.message("Plugin runtime isn't ready"))
                    return
                }
                let callId = UUID().uuidString
                self.http.makeJar(callId)
                let box = OnceBox()

                let cb: @convention(block) (String?, String?) -> Void = { err, res in
                    if box.done { return }
                    box.done = true
                    self.http.dropJar(callId)
                    if let err { cont.resume(throwing: PluginError.message(err)) }
                    else { cont.resume(returning: res ?? "null") }
                }
                self.queue.asyncAfter(deadline: .now() + 60) {
                    if box.done { return }
                    box.done = true
                    self.http.dropJar(callId)
                    cont.resume(throwing: PluginError.message("Plugin timed out after 60 s"))
                }
                let acct: Any = accountJSON.map { $0 as Any } ?? NSNull()
                _ = fn.call(withArguments: [pluginId, callId, url, acct,
                                            unsafeBitCast(cb, to: AnyObject.self)])
            }
        }
    }

    // MARK: JS side of the plugin API

    static let prelude = #"""
var __plugins = {};
var __currentFile = "";

function registerPlugin(p) {
  if (!p || !p.id || typeof p.resolve !== "function") {
    throw new Error("registerPlugin needs an id and a resolve function");
  }
  p.__file = __currentFile;
  __plugins[p.id] = p;
}

function __meta() {
  return JSON.stringify(Object.keys(__plugins).map(function (k) {
    var p = __plugins[k];
    return {
      id: String(p.id), name: String(p.name || p.id), version: String(p.version || ""),
      hosts: (p.hosts || []).map(String), pattern: p.pattern ? String(p.pattern) : null,
      accounts: !!p.accounts, file: p.__file
    };
  }));
}

function __decodeHTML(s) {
  return String(s).replace(/&quot;/g, '"').replace(/&#0?39;/g, "'")
    .replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&");
}

function __absURL(rel, base) {
  rel = String(rel);
  if (/^[a-z][a-z0-9+.-]*:/i.test(rel)) return rel;
  var m = String(base).match(/^([a-z][a-z0-9+.-]*:)\/\/([^\/?#]*)([^?#]*)/i);
  if (!m) return rel;
  if (rel.indexOf("//") === 0) return m[1] + rel;
  if (rel.charAt(0) === "/") return m[1] + "//" + m[2] + rel;
  if (rel.charAt(0) === "?") return m[1] + "//" + m[2] + m[3] + rel;
  if (rel.charAt(0) === "#") return m[1] + "//" + m[2] + m[3];
  var dir = m[3].replace(/[^\/]*$/, "") || "/";
  var parts = (dir + rel).split("/"), out = [];
  for (var i = 0; i < parts.length; i++) {
    if (parts[i] === "..") { if (out.length > 1) out.pop(); }
    else if (parts[i] !== ".") out.push(parts[i]);
  }
  return m[1] + "//" + m[2] + out.join("/");
}

function __makeHttp(callId) {
  function request(opts) {
    return new Promise(function (resolve, reject) {
      __http(callId, JSON.stringify({
        method: opts.method || "GET",
        url: opts.url,
        headers: opts.headers || {},
        body: opts.body == null ? null : String(opts.body),
        follow: opts.follow !== false
      }), function (err, r) {
        if (err) reject(new Error(err)); else resolve(JSON.parse(r));
      });
    });
  }
  function form(o) {
    return Object.keys(o).map(function (k) {
      return encodeURIComponent(k) + "=" + encodeURIComponent(o[k]);
    }).join("&");
  }
  return {
    request: request,
    get: function (url, opts) { return request(Object.assign({}, opts, { url: url, method: "GET" })); },
    post: function (url, body, opts) {
      var headers = Object.assign({}, opts && opts.headers);
      if (body && typeof body === "object") {
        body = form(body);
        if (!headers["Content-Type"]) headers["Content-Type"] = "application/x-www-form-urlencoded";
      }
      return request(Object.assign({}, opts, { url: url, method: "POST", body: body, headers: headers }));
    },
    postJSON: function (url, obj, opts) {
      var headers = Object.assign({ "Content-Type": "application/json" }, opts && opts.headers);
      return request(Object.assign({}, opts, { url: url, method: "POST", body: JSON.stringify(obj), headers: headers }));
    },
    cookieHeader: function (url) { return __cookieHeader(callId, url); }
  };
}

function __resolve(id, callId, url, accountJSON, cb) {
  var p = __plugins[id];
  if (!p) { cb("Plugin not found: " + id, null); return; }
  var ctx = {
    http: __makeHttp(callId),
    account: accountJSON ? JSON.parse(accountJSON) : null,
    log: function () {
      var parts = Array.prototype.slice.call(arguments).map(function (x) {
        return typeof x === "string" ? x : JSON.stringify(x);
      });
      __log(id, parts.join(" "));
    },
    sleep: function (ms) { return new Promise(function (r) { __sleep(ms, r); }); },
    absURL: __absURL,
    decodeHTML: __decodeHTML
  };
  var pr;
  try { pr = Promise.resolve(p.resolve(url, ctx)); }
  catch (e) { cb(String((e && e.message) || e), null); return; }
  pr.then(
    function (r) { cb(null, JSON.stringify(r === undefined ? null : r)); },
    function (e) { cb(String((e && e.message) || e), null); }
  );
}
"""#
}
