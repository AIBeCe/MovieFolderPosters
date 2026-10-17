import Foundation
import LocalAuthentication
import Security

/// Stores a shared credential without exposing Keychain implementation details.
nonisolated protocol CredentialStoring: Sendable {
  /// Reads the shared token without allowing interactive authentication prompts.
  /// - Returns: The requested text when available.
  /// - Throws: Invalid credential input or a Keychain status wrapped in ConfigurationError.credentialStorage.
  func read() throws -> String?
  /// Validates and stores the shared token using device-local Keychain accessibility.
  ///
  /// - Parameter value: The TMDb read access token to validate and store.
  /// - Throws: Invalid credential input or a Keychain status wrapped in ConfigurationError.credentialStorage.
  func save(_ value: String) throws
  /// Removes the shared token, accepting an already absent credential.
  /// - Throws: Invalid credential input or a Keychain status wrapped in ConfigurationError.credentialStorage.
  func remove() throws
}

/// Stores the TMDb token in the shared data-protection Keychain without prompting.
nonisolated struct KeychainCredentialStore: CredentialStoring {
  /// The noninteractive shared Keychain lookup attributes.
  private var query: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "dag.fikios.MovieFolderPosters.TMDb",
      kSecAttrAccount as String: "read-access-token",
      kSecAttrAccessGroup as String: SharedEnvironment.groupIdentifier,
      kSecUseDataProtectionKeychain as String: true
    ]
  }

  /// Reads the shared token without allowing interactive authentication prompts.
  /// - Returns: The requested text when available.
  /// - Throws: Invalid credential input or a Keychain status wrapped in ConfigurationError.credentialStorage.
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
      let value = String(data: data, encoding: .utf8)
    else {
      throw ConfigurationError.credentialStorage(status)
    }

    return value
  }

  /// Validates and stores the shared token using device-local Keychain accessibility.
  ///
  /// - Parameter value: The TMDb read access token to validate and store.
  /// - Throws: Invalid credential input or a Keychain status wrapped in ConfigurationError.credentialStorage.
  func save(_ value: String) throws {
    guard !value.isEmpty, value.count <= 4096,
      value.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 })
    else {
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

  /// Removes the shared token, accepting an already absent credential.
  /// - Throws: Invalid credential input or a Keychain status wrapped in ConfigurationError.credentialStorage.
  func remove() throws {
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw ConfigurationError.credentialStorage(status)
    }
  }
}
