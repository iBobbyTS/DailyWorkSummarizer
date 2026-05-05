import Foundation

protocol CredentialProviding: AnyObject, Sendable {
    func apiKey(for account: String) -> String
}

final class KeychainCredentialProvider: CredentialProviding {
    private let keychain: KeychainStore

    init(keychain: KeychainStore) {
        self.keychain = keychain
    }

    func apiKey(for account: String) -> String {
        keychain.string(for: account)
    }
}

final class NoOpCredentialProvider: CredentialProviding {
    func apiKey(for _: String) -> String { "" }
}
