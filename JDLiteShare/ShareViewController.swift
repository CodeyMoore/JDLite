import UIKit
import UniformTypeIdentifiers

/// "Share › JDLite": picks the links (web links and magnet links) and .torrent files out of
/// whatever was shared, then opens JDLite with them, just like the Safari extension does.
final class ShareViewController: UIViewController {
    private let card = UIView()
    private let icon = UIImageView(image: UIImage(systemName: "arrow.down.circle.fill"))
    private let label = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let doneButton = UIButton(type: .system)
    private var started = false

    /// Keeps the jdlite:// link a sane length (torrent files travel inside it).
    private static let maxLinkLength = 1_500_000

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.25)

        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 18
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)

        icon.tintColor = UIColor(red: 0.243, green: 0.420, blue: 0.949, alpha: 1)
        icon.contentMode = .scaleAspectFit
        label.text = "Sending to JDLite…"
        label.font = .preferredFont(forTextStyle: .body)
        label.numberOfLines = 0
        label.textAlignment = .center
        spinner.startAnimating()
        doneButton.setTitle("Done", for: .normal)
        doneButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        doneButton.isHidden = true
        doneButton.addTarget(self, action: #selector(finish), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [icon, label, spinner, doneButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        let preferredWidth = card.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.8)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            preferredWidth,
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            icon.widthAnchor.constraint(equalToConstant: 44),
            icon.heightAnchor.constraint(equalToConstant: 44),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20)
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        Task { await send() }
    }

    // MARK: Sending

    private func send() async {
        let shared = await collect()
        guard !shared.links.isEmpty || !shared.torrents.isEmpty else {
            show("No links or .torrent files found in what you shared.")
            return
        }
        guard let link = makeLink(shared) else {
            show("That's too much to send in one go. Try sharing fewer links or a smaller .torrent file.")
            return
        }
        if await openJDLite(link) {
            extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
            return
        }
        // Couldn't open the app: hand the links over through the clipboard instead.
        if !shared.links.isEmpty {
            UIPasteboard.general.string = shared.links.joined(separator: "\n")
            show("Couldn't open JDLite from here. The links are copied: open JDLite, tap + and then Paste.")
        } else {
            show("Couldn't open JDLite from here. Open the .torrent file from the Files app and choose JDLite.")
        }
    }

    private struct Shared {
        var links: [String] = []
        var torrents: [(name: String, data: Data)] = []
    }

    /// Reads the shared items: links, text with links in it, and .torrent files.
    private func collect() async -> Shared {
        var shared = Shared()
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        for provider in providers {
            if let torrent = await loadTorrent(provider) {
                shared.torrents.append(torrent)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                      let url = await loadItem(provider, type: UTType.url.identifier) as? URL {
                if url.isFileURL {
                    if let text = try? String(contentsOf: url, encoding: .utf8) { shared.links += Self.links(in: text) }
                } else {
                    shared.links.append(url.absoluteString)
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                let item = await loadItem(provider, type: UTType.plainText.identifier)
                if let text = item as? String {
                    shared.links += Self.links(in: text)
                } else if let data = item as? Data, let text = String(data: data, encoding: .utf8) {
                    shared.links += Self.links(in: text)
                } else if let url = item as? URL, let text = try? String(contentsOf: url, encoding: .utf8) {
                    shared.links += Self.links(in: text)
                }
            }
        }
        var seen = Set<String>()
        shared.links = shared.links.filter { seen.insert($0).inserted }
        return shared
    }

    private func loadItem(_ provider: NSItemProvider, type: String) async -> NSSecureCoding? {
        await withCheckedContinuation { (continuation: CheckedContinuation<NSSecureCoding?, Never>) in
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
                continuation.resume(returning: item)
            }
        }
    }

    /// A shared .torrent file, read into memory.
    private func loadTorrent(_ provider: NSItemProvider) async -> (name: String, data: Data)? {
        let torrentType = UTType(filenameExtension: "torrent")?.identifier ?? "org.bittorrent.torrent"
        let named = (provider.suggestedName ?? "").lowercased().hasSuffix(".torrent")
        guard provider.hasItemConformingToTypeIdentifier(torrentType) || named else { return nil }
        let type = provider.hasItemConformingToTypeIdentifier(torrentType) ? torrentType : UTType.data.identifier
        let data: Data? = await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                continuation.resume(returning: data)
            }
        }
        guard let data, !data.isEmpty else { return nil }
        let name = provider.suggestedName ?? "Torrent"
        return (name: name.lowercased().hasSuffix(".torrent") ? name : name + ".torrent", data: data)
    }

    /// Web links and magnet links in a piece of text.
    static func links(in text: String) -> [String] {
        guard let pattern = try? NSRegularExpression(pattern: "(?:https?://|magnet:\\?)[^\\s\"'<>]+",
                                                     options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: range).compactMap { match in
            guard let r = Range(match.range, in: text) else { return nil }
            var link = String(text[r])
            while let last = link.last, ".,;:!?)]}".contains(last) { link.removeLast() }
            return link.isEmpty ? nil : link
        }
    }

    /// jdlite://add?u=<link>&u=<link>&t=<.torrent as base64url>&tn=<its name>
    private func makeLink(_ shared: Shared) -> URL? {
        var parts = shared.links.prefix(200).map { "u=" + Self.encode($0) }
        for torrent in shared.torrents {
            let encoded = torrent.data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            parts.append("t=" + encoded)
            parts.append("tn=" + Self.encode(torrent.name))
        }
        let link = "jdlite://add?" + parts.joined(separator: "&")
        guard link.count <= Self.maxLinkLength else { return nil }
        return URL(string: link)
    }

    /// Percent-encodes everything except letters, digits and -._~ (so & = + # survive the trip).
    private static func encode(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// Opens JDLite with the link. iOS has no official way for a share extension to do this;
    /// this finds the application object through the responder chain and asks it, which
    /// works on current versions of iOS.
    private func openJDLite(_ url: URL) async -> Bool {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication, application.responds(to: selector) {
                typealias OpenURL = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
                let open = unsafeBitCast(application.method(for: selector), to: OpenURL.self)
                open(application, selector, url as NSURL, NSDictionary(), nil)
                return true
            }
            responder = current.next
        }
        // The documented way (only some kinds of extension are allowed to use it).
        guard let context = extensionContext else { return false }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            context.open(url) { opened in continuation.resume(returning: opened) }
        }
    }

    // MARK: Messages

    private func show(_ message: String) {
        label.text = message
        spinner.stopAnimating()
        spinner.isHidden = true
        doneButton.isHidden = false
    }

    @objc private func finish() {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
