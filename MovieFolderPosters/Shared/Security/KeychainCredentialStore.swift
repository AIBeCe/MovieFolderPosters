import Foundation
import Security
import LocalAuthentication

nonisolated protocol CredentialStoring: Sendable {
    func read() throws -> String?
    func save(_ value: String) throws
    func remove() throws
}

nonisolated struct KeychainCredentialStore: CredentialStoring {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "dag.fikios.MovieFolderPosters.TMDb",
         kSecAttrAccount as String: "read-access-token",
         kSecAttrAccessGroup as String: SharedEnvironment.groupIdentifier,
         kSecUseDataProtectionKeychain as String: true]
    }

    func read() throws -> String? {
        var attributes = query
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        attributes[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw ConfigurationError.credentialStorage(status)
        }
        return value
    }

    func save(_ value: String) throws {
        guard !value.isEmpty, value.count <= 4096,
              value.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }) else {
            throw ConfigurationError.invalidCredential
        }
        let data = Data(value.utf8)
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ConfigurationError.credentialStorage(status) }
    }

    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ConfigurationError.credentialStorage(status)
        }
    }
}
