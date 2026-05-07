import Foundation

protocol CredentialProviding: AnyObject, Sendable {
    func apiKey(for account: String) throws -> String
}

final class KeychainCredentialProvider: CredentialProviding {
    private let keychain: KeychainStoring

    init(keychain: KeychainStoring) {
        self.keychain = keychain
    }

    func apiKey(for account: String) throws -> String {
        switch keychain.readString(for: account) {
        case .success(_, let value):
            return value
        case .notFound:
            return ""
        case .failure(let account, let status):
            throw KeychainReadError(result: .failure(account: account, status: status))
        }
    }
}

final class NoOpCredentialProvider: CredentialProviding {
    func apiKey(for _: String) throws -> String { "" }
}
