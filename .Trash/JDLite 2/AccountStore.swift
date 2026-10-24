import Foundation
import Security
import Combine

struct Account: Identifiable, Codable, Equatable {
    var id = UUID()
    var host = ""
    var label = ""
    var username = ""
    var password = ""   // password or API token
    var cookies = ""    // optional "name=value; name2=value2"
    var created = Date()
}

@MainActor
final class AccountStore: ObservableObject {
    static let shared = AccountStore()
    @Published private(set) var accounts: [Account] = []
    private let service = "jdlite.accounts"

    init() { accounts = loadAll() }

    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.contains("://"), let h = URL(string: s)?.host { s = h }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        if s.hasPrefix("www.") { s = String(s.dropFirst(4)) }
        return s
    }

    func save(_ account: Account) {
        var a = account
        a.host = Self.normalize(a.host)
        guard let data = try? JSONEncoder().encode(a) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: a.id.uuidString
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
        accounts = loadAll()
    }

    func delete(_ id: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString
        ]
        SecItemDelete(query as CFDictionary)
        accounts = loadAll()
    }

    /// Only plugins that declare `accounts: true` ever receive credentials.
    func account(for url: URL, plugin: PluginInfo) -> Account? {
        guard plugin.accounts else { return nil }
        let host = url.host?.lowercased() ?? ""
        let hosts = plugin.hosts.map { $0.lowercased() }
        return accounts.first { a in
            !a.host.isEmpty && (host == a.host || host.hasSuffix("." + a.host) || hosts.contains(a.host))
        }
    }

    private func loadAll() -> [Account] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let arr = out as? [Data] else { return [] }
        return arr.compactMap { try? JSONDecoder().decode(Account.self, from: $0) }.sorted { $0.created < $1.created }
    }
}
