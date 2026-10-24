import SafariServices
import Foundation

/// The extension's native side. The popup hands links to the app through the jdlite://
/// URL scheme; this only answers one question a web page can't: what a link on another
/// site leads to (a file, or a web page). The popup asks with
/// browser.runtime.sendNativeMessage({type: "check", urls: [...]}).
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any]
        guard let message, message["type"] as? String == "check",
              let urls = message["urls"] as? [String], !urls.isEmpty else {
            context.completeRequest(returningItems: [], completionHandler: nil)
            return
        }
        let list = Array(urls.prefix(40))
        Task {
            let results = await LinkChecker.check(list)
            let reply = NSExtensionItem()
            reply.userInfo = [SFExtensionMessageKey: ["results": results.map { $0.dictionary }]]
            context.completeRequest(returningItems: [reply], completionHandler: nil)
        }
    }
}

/// What a server says about a link, from its reply headers.
struct LinkCheck: Sendable {
    var url: String
    var status = 0
    var finalURL = ""
    var type = ""
    var disposition = ""
    var length = ""
    var range = ""
    var error: String?

    var dictionary: [String: Any] {
        var d: [String: Any] = ["url": url, "status": status, "finalURL": finalURL, "type": type,
                                "disposition": disposition, "length": length, "range": range]
        if let error { d["error"] = error }
        return d
    }
}

enum LinkChecker {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 12
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }()

    static func check(_ urls: [String]) async -> [LinkCheck] {
        await withTaskGroup(of: LinkCheck.self) { group in
            for raw in urls {
                group.addTask { await LinkChecker.checkOne(raw) }
            }
            var out: [LinkCheck] = []
            for await result in group { out.append(result) }
            return out
        }
    }

    /// Reads just the reply headers (the file itself is never downloaded).
    static func checkOne(_ raw: String) async -> LinkCheck {
        var result = LinkCheck(url: raw)
        guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            result.error = "Not a web link."
            return result
        }
        do {
            var head = URLRequest(url: url)
            head.httpMethod = "HEAD"
            head.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            var response = try await session.data(for: head).1
            if let http = response as? HTTPURLResponse, [403, 405, 501].contains(http.statusCode) {
                // Some servers refuse HEAD: ask for the first byte instead.
                var get = URLRequest(url: url)
                get.setValue("bytes=0-0", forHTTPHeaderField: "Range")
                get.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                let (stream, reply) = try await session.bytes(for: get)
                stream.task.cancel()
                response = reply
            }
            let http = response as? HTTPURLResponse
            result.status = http?.statusCode ?? 200
            result.finalURL = response.url?.absoluteString ?? raw
            result.type = http?.value(forHTTPHeaderField: "Content-Type") ?? response.mimeType ?? ""
            result.disposition = http?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
            result.length = http?.value(forHTTPHeaderField: "Content-Length") ?? ""
            result.range = http?.value(forHTTPHeaderField: "Content-Range") ?? ""
        } catch {
            result.error = error.localizedDescription
        }
        return result
    }
}
