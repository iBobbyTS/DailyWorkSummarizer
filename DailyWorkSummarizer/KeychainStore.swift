import Foundation
import Security

final class KeychainStore {
    private let service: String

    init(service: String) {
        self.service = service
    }

    func string(for account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func set(_ value: String, for account: String) {
        let encoded = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        if value.isEmpty {
            SecItemDelete(query as CFDictionary)
            return
        }

        let attributes: [String: Any] = [
            kSecValueData as String: encoded,
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insertQuery = query
            insertQuery[kSecValueData as String] = encoded
            SecItemAdd(insertQuery as CFDictionary, nil)
        }
    }
}
