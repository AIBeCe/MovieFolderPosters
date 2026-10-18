import Foundation
import LocalAuthentication
import Security

/// Stores a shared credential without exposing Keychain implementation details.
nonisolated public protocol CredentialStoring: Sendable {
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
nonisolated public struct KeychainCredentialStore: CredentialStoring {
  /// The signed targets' shared Keychain access group.
  private let accessGroup: String

  /// The platform operations used for this store.
  private let backend: any KeychainCredentialBackend

  /// Creates the noninteractive credential store for the signed targets' shared access group.
  /// - Parameter accessGroup: The Keychain group authorized by both targets' entitlements.
  public init(accessGroup: String) {
    self.init(accessGroup: accessGroup, backend: SystemKeychainCredentialBackend())
  }

  /// Uses an explicit platform backend while retaining production query and validation behavior.
  init(accessGroup: String, backend: any KeychainCredentialBackend) {
    self.accessGroup = accessGroup
    self.backend = backend
  }

  /// The noninteractive shared Keychain lookup attributes.
  private var query: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "dag.fikios.MovieFolderPosters.TMDb",
      kSecAttrAccount as String: "read-access-token",
      kSecAttrAccessGroup as String: accessGroup,
      kSecUseDataProtectionKeychain as String: true
    ]
  }

  /// Reads the shared token without allowing interactive authentication prompts.
  /// - Returns: The requested text when available.
  /// - Throws: Invalid credential input or a Keychain status wrapped in ConfigurationError.credentialStorage.
  public func read() throws -> String? {
    var attributes = query
    attributes[kSecReturnData as String] = true
    attributes[kSecMatchLimit as String] = kSecMatchLimitOne
    let context = LAContext()
    context.interactionNotAllowed = true
    attributes[kSecUseAuthenticationContext as String] = context
    let (status, result) = backend.copyMatching(attributes)
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
  public func save(_ value: String) throws {
    guard !value.isEmpty, value.count <= 4096,
      value.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 })
    else {
      throw ConfigurationError.invalidCredential
    }
    let data = Data(value.utf8)
    let update = [kSecValueData as String: data]
    var status = backend.update(query, attributes: update)
    if status == errSecItemNotFound {
      var attributes = query
      attributes[kSecValueData as String] = data
      attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      status = backend.add(attributes)
    }
    guard status == errSecSuccess else { throw ConfigurationError.credentialStorage(status) }
  }

  /// Removes the shared token, accepting an already absent credential.
  /// - Throws: Invalid credential input or a Keychain status wrapped in ConfigurationError.credentialStorage.
  public func remove() throws {
    let status = backend.delete(query)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw ConfigurationError.credentialStorage(status)
    }
  }
}

/// The external Security framework boundary, isolated from token handling decisions.
nonisolated protocol KeychainCredentialBackend: Sendable {
  /// Performs a noninteractive lookup using the supplied complete query.
  func copyMatching(_ query: [String: Any]) -> (OSStatus, CFTypeRef?)
  /// Updates an existing credential.
  func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
  /// Inserts a credential with explicit accessibility attributes.
  func add(_ attributes: [String: Any]) -> OSStatus
  /// Removes a matching credential.
  func delete(_ query: [String: Any]) -> OSStatus
}

/// Executes the unchanged Security framework operations in signed production processes.
nonisolated private struct SystemKeychainCredentialBackend: KeychainCredentialBackend {
  func copyMatching(_ query: [String: Any]) -> (OSStatus, CFTypeRef?) {
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)

    return (status, result)
  }

  func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
    SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
  }

  func add(_ attributes: [String: Any]) -> OSStatus { SecItemAdd(attributes as CFDictionary, nil) }
  func delete(_ query: [String: Any]) -> OSStatus { SecItemDelete(query as CFDictionary) }
}
