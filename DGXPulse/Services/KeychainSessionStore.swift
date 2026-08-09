import Foundation
import Security

actor KeychainSessionStore: AuthSessionStoring {
    private let usernameDefaultsKey: String
    private let service: String
    private let account: String

    init(
        usernameDefaultsKey: String = AppPreferenceKey.username,
        service: String = "DGXPulse.Dashboard",
        account: String = "dashboard-token"
    ) {
        self.usernameDefaultsKey = usernameDefaultsKey
        self.service = service
        self.account = account
    }

    func loadUsername() async -> String? {
        let value = UserDefaults.standard.string(forKey: usernameDefaultsKey)
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    func loadToken() async -> String? {
        var query = baseQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func save(username: String, token: String) async throws {
        UserDefaults.standard.set(username, forKey: usernameDefaultsKey)
        guard let data = token.data(using: .utf8) else {
            throw ConnectionFailure.server("Unable to encode session token.")
        }

        let deleteQuery = baseQuery
        SecItemDelete(deleteQuery as CFDictionary)

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ConnectionFailure.server("Could not save session to Keychain (OSStatus \(status)).")
        }
    }

    func clear() async {
        UserDefaults.standard.removeObject(forKey: usernameDefaultsKey)
        SecItemDelete(baseQuery as CFDictionary)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
