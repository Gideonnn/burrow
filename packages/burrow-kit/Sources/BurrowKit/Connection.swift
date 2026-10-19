import Foundation
import Security

public struct Connection: Equatable, Sendable {
    public var serverURL: URL
    public var token: String

    public init(serverURL: URL, token: String) {
        self.serverURL = serverURL
        self.token = token
    }
}

/// Keeps the server address in UserDefaults and the API key in the Keychain,
/// per app: each app logs in with its own device key.
public struct ConnectionStore: Sendable {
    let service: String
    let account = "api-key"
    let defaultsKey: String

    public init(service: String) {
        self.service = service
        self.defaultsKey = "\(service).serverURL"
    }

    public init(app: String) { self.init(service: "app.burrow.\(app)") }

    public func load() -> Connection? {
        guard let text = UserDefaults.standard.string(forKey: defaultsKey), let url = URL(string: text) else { return nil }
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let token = String(data: data, encoding: .utf8)
        else { return nil }
        return Connection(serverURL: url, token: token)
    }

    public func save(_ connection: Connection) throws {
        UserDefaults.standard.set(connection.serverURL.absoluteString, forKey: defaultsKey)
        SecItemDelete(baseQuery() as CFDictionary)
        var query = baseQuery()
        query[kSecValueData as String] = Data(connection.token.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    public func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}
