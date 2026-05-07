import Foundation
import Security

nonisolated enum KeychainWriteOperation: String, Equatable {
    case add
    case update
    case delete
}

nonisolated struct KeychainWriteResult: Equatable {
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

nonisolated struct KeychainWriteError: LocalizedError {
    let result: KeychainWriteResult

    var errorDescription: String? {
        "Keychain \(result.operation.rawValue) failed for \(result.account): \(result.statusDescription)"
    }
}

nonisolated enum KeychainReadResult: Equatable {
    case success(account: String, value: String)
    case notFound(account: String)
    case failure(account: String, status: OSStatus)
    case malformedData(account: String)

    var value: String? {
        guard case .success(_, let value) = self else {
            return nil
        }
        return value
    }

    var failureDescription: String? {
        switch self {
        case .failure(_, let status):
            return SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        case .malformedData:
            return "Keychain item data is not valid UTF-8"
        case .success, .notFound:
            return nil
        }
    }
}

nonisolated struct KeychainReadError: LocalizedError {
    let result: KeychainReadResult

    var errorDescription: String? {
        switch result {
        case .failure(let account, _):
            return "Keychain read failed for \(account): \(result.failureDescription ?? "unknown error")"
        case .malformedData(let account):
            return "Keychain read failed for \(account): \(result.failureDescription ?? "unknown error")"
        case .success, .notFound:
            return nil
        }
    }
}

nonisolated protocol KeychainStoring {
    func readString(for account: String) -> KeychainReadResult
    func string(for account: String) -> String
    @discardableResult func set(_ value: String, for account: String) -> KeychainWriteResult
}

extension KeychainStoring {
    nonisolated func string(for account: String) -> String {
        readString(for: account).value ?? ""
    }
}

nonisolated final class KeychainStore: KeychainStoring {
    private let service: String

    init(service: String) {
        self.service = service
    }

    func readString(for account: String) -> KeychainReadResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return .notFound(account: account)
        }
        guard status == errSecSuccess else {
            return .failure(account: account, status: status)
        }
        guard let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return .malformedData(account: account)
        }
        return .success(account: account, value: value)
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

nonisolated final class InMemoryKeychainStore: KeychainStoring {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func readString(for account: String) -> KeychainReadResult {
        lock.lock()
        defer { lock.unlock() }
        guard let value = values[account] else {
            return .notFound(account: account)
        }
        return .success(account: account, value: value)
    }

    @discardableResult
    func set(_ value: String, for account: String) -> KeychainWriteResult {
        lock.lock()
        defer { lock.unlock() }
        if value.isEmpty {
            values.removeValue(forKey: account)
            return .success(account: account, operation: .delete)
        }
        let operation: KeychainWriteOperation = values[account] == nil ? .add : .update
        values[account] = value
        return .success(account: account, operation: operation)
    }
}
