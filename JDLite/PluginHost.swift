import Foundation
import Combine

@MainActor
final class PluginHost: ObservableObject {
    static let shared = PluginHost()

    @Published private(set) var plugins: [PluginInfo] = []
    @Published private(set) var loadErrors: [String] = []
    @Published private(set) var logs: [String] = []

    private let runtime = JSRuntime()
    private var loadTask: Task<Void, Never>?

    nonisolated static var pluginsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Plugins")
    }

    init() {
        runtime.onLog = { [weak self] line in
            Task { @MainActor in self?.appendLog(line) }
        }
        loadTask = Task { await self.reload() }
    }

    func ensureLoaded() async { await loadTask?.value }

    func reloadTapped() { loadTask = Task { await self.reload() } }

    func reload() async {
        installBundledPlugins()
        let result = await runtime.load(readSources())
        plugins = result.infos
        loadErrors = result.errors
    }

    func match(_ url: URL) -> PluginInfo? {
        guard let host = url.host?.lowercased() else { return nil }
        let full = url.absoluteString
        return plugins.first { p in
            let hostOK = p.hosts.contains { h in
                let h = h.lowercased()
                return host == h || host.hasSuffix("." + h)
            }
            guard hostOK else { return false }
            guard let pattern = p.pattern else { return true }
            return full.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    func resolve(plugin: PluginInfo, url: URL) async throws -> [ResolvedLink] {
        let json = try await runtime.resolve(pluginId: plugin.id, url: url.absoluteString)
        let data = Data(json.utf8)
        let dec = JSONDecoder()
        var links: [ResolvedLink]
        if let arr = try? dec.decode([ResolvedLink].self, from: data) { links = arr }
        else if let one = try? dec.decode(ResolvedLink.self, from: data) { links = [one] }
        else { throw PluginError.message("Plugin returned an invalid result (expected {url, fileName?, headers?})") }
        links = links.filter { ["http", "https"].contains($0.url.scheme?.lowercased() ?? "") }
        guard !links.isEmpty else { throw PluginError.message("Plugin returned no downloadable links") }
        return links
    }

    private func appendLog(_ line: String) {
        logs.append(line)
        if logs.count > 200 { logs.removeFirst(logs.count - 200) }
    }

    private func installBundledPlugins() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.pluginsDir, withIntermediateDirectories: true)
        // Not "Plugins": that name clashes with the app's "PlugIns" extension folder.
        guard let src = Bundle.main.url(forResource: "BuiltInPlugins", withExtension: nil),
              let files = try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil) else { return }
        // Built-in plugins are refreshed on every launch; to customise one,
        // copy it under a different file name.
        for f in files {
            let dest = Self.pluginsDir.appendingPathComponent(f.lastPathComponent)
            try? fm.removeItem(at: dest)
            try? fm.copyItem(at: f, to: dest)
        }
    }

    private func readSources() -> [(file: String, code: String)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.pluginsDir, includingPropertiesForKeys: nil)) ?? []
        var out: [(file: String, code: String)] = []
        for u in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where u.pathExtension.lowercased() == "js" {
            if let code = try? String(contentsOf: u, encoding: .utf8) {
                out.append((file: u.lastPathComponent, code: code))
            }
        }
        return out
    }
}
