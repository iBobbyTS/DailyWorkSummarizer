import Foundation
import Security

enum KeychainWriteOperation: String, Equatable {
    case add
    case update
    case delete
}

struct KeychainWriteResult: Equatable {
    let account: String
    let operation: KeychainWriteOperation
    let status: OSStatus
    let isSuccess: Bool

    var statusDescription: String {
        SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
    }

    static func success(account: String, operation: KeychainWriteOperation, status: OSStatus = errSecSuccess) -> KeychainWriteResult {
        KeychainWriteResult(account: account, operation: operation, status: status, isSuccess: true)
    }

    static func failure(account: String, operation: KeychainWriteOperation, status: OSStatus) -> KeychainWriteResult {
        KeychainWriteResult(account: account, operation: operation, status: status, isSuccess: false)
    }
}

struct KeychainWriteError: LocalizedError {
    let result: KeychainWriteResult

    var errorDescription: String? {
        "Keychain \(result.operation.rawValue) failed for \(result.account): \(result.statusDescription)"
    }
}

protocol KeychainStoring {
    func string(for account: String) -> String
    @discardableResult func set(_ value: String, for account: String) -> KeychainWriteResult
}

final class KeychainStore: KeychainStoring {
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

    @discardableResult
    func set(_ value: String, for account: String) -> KeychainWriteResult {
        let encoded = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            if status == errSecSuccess || status == errSecItemNotFound {
                return .success(account: account, operation: .delete, status: status)
            }
            return .failure(account: account, operation: .delete, status: status)
        }

        let attributes: [String: Any] = [
            kSecValueData as String: encoded,
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess {
            return .success(account: account, operation: .update, status: status)
        }

        if status == errSecItemNotFound {
            var insertQuery = query
            insertQuery[kSecValueData as String] = encoded
            let addStatus = SecItemAdd(insertQuery as CFDictionary, nil)
            if addStatus == errSecSuccess {
                return .success(account: account, operation: .add, status: addStatus)
            }
            return .failure(account: account, operation: .add, status: addStatus)
        }

        return .failure(account: account, operation: .update, status: status)
    }
}
