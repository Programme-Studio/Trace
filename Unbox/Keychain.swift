import Foundation
import Security

enum Keychain {
    static let service = "uk.co.researchunit.unbox"

    @discardableResult
    static func set(_ value: String, account: String, service: String = service) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)

        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    /// `service` is a parameter so the rename migration can read the token the
    /// app stored under its old bundle id.
    static func get(account: String, service: String = service) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string
    }

    static func delete(account: String, service: String = service) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
