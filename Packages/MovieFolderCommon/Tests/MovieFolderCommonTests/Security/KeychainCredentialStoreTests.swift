import Foundation
import LocalAuthentication
import Security
import Synchronization
import Testing

@testable import MovieFolderCommon

/// Exercises token validation and Keychain result handling without accessing the user's Keychain.
struct KeychainCredentialStoreTests {
  /// Missing and malformed Keychain payloads must not become usable credentials.
  @Test func readsOnlySuccessfulUTF8Payloads() throws {
    let backend = CredentialBackendProbe()
    let store = KeychainCredentialStore(accessGroup: "test.group", backend: backend)
    backend.response.withLock { $0 = (errSecItemNotFound, .none) }
    #expect(try store.read() == .none)
    backend.response.withLock { $0 = (errSecSuccess, Data("test-token".utf8)) }
    #expect(try store.read() == "test-token")
    backend.response.withLock { $0 = (errSecSuccess, Data([0xff])) }
    #expect(throws: ConfigurationError.self) { try store.read() }
    backend.response.withLock { $0 = (errSecAuthFailed, .none) }
    #expect(throws: ConfigurationError.self) { try store.read() }
  }

  /// Invalid input cannot reach the external backend.
  @Test(arguments: ["", "white space", "line\nbreak", "é", String(repeating: "a", count: 4097)])
  func rejectsInvalidTokens(_ token: String) {
    let backend = CredentialBackendProbe()
    #expect(throws: ConfigurationError.self) {
      try KeychainCredentialStore(accessGroup: "test.group", backend: backend).save(token)
    }
    #expect(backend.calls.withLock { $0.isEmpty })
  }

  /// Creation is used only after a missing-item update, preserving device-local accessibility.
  @Test func savesThroughUpdateOrMissingItemCreation() throws {
    let backend = CredentialBackendProbe()
    let store = KeychainCredentialStore(accessGroup: "test.group", backend: backend)
    try store.save("existing-token")
    #expect(backend.calls.withLock { $0 } == ["update"])
    backend.updateStatus.withLock { $0 = errSecItemNotFound }
    try store.save("new-token")
    #expect(backend.calls.withLock { $0 } == ["update", "update", "add"])
    backend.addStatus.withLock { $0 = errSecNotAvailable }
    #expect(throws: ConfigurationError.self) { try store.save("new-token") }
    backend.updateStatus.withLock { $0 = errSecAuthFailed }
    #expect(throws: ConfigurationError.self) { try store.save("existing-token") }
  }

  /// Removal accepts absence while surfacing denied access.
  @Test func removalIsIdempotentButReportsFailures() throws {
    let backend = CredentialBackendProbe()
    let store = KeychainCredentialStore(accessGroup: "test.group", backend: backend)
    try store.remove()
    backend.deleteStatus.withLock { $0 = errSecItemNotFound }
    try store.remove()
    backend.deleteStatus.withLock { $0 = errSecAuthFailed }
    #expect(throws: ConfigurationError.self) { try store.remove() }
  }
}

/// Represents the OS boundary only; credential decisions remain in the real store.
private final class CredentialBackendProbe: KeychainCredentialBackend {
  /// Configured lookup result.
  let response = Mutex<(OSStatus, Data?)>((errSecSuccess, .none))
  /// Configured update status.
  let updateStatus = Mutex<OSStatus>(errSecSuccess)
  /// Configured insertion status.
  let addStatus = Mutex<OSStatus>(errSecSuccess)
  /// Configured deletion status.
  let deleteStatus = Mutex<OSStatus>(errSecSuccess)
  /// Change sequence for detecting accidental fallback after permission failures.
  let calls = Mutex<[String]>([])

  func copyMatching(_ query: [String: Any]) -> (OSStatus, CFTypeRef?) {
    #expect(query[kSecAttrAccessGroup as String] as? String == "test.group")
    #expect(query[kSecAttrService as String] as? String == "dag.fikios.MovieFolderPosters.TMDb")
    #expect(query[kSecAttrAccount as String] as? String == "read-access-token")
    #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
    #expect(query[kSecReturnData as String] as? Bool == true)
    #expect(query[kSecUseAuthenticationContext as String] is LAContext)

    return response.withLock { ($0.0, $0.1 as CFTypeRef?) }
  }

  func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
    #expect(attributes[kSecValueData as String] is Data)
    calls.withLock { $0.append("update") }

    return updateStatus.withLock { $0 }
  }

  func add(_ attributes: [String: Any]) -> OSStatus {
    let expectedAccessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
    #expect(attributes[kSecAttrAccessible as String] as? String == expectedAccessibility)
    #expect(attributes[kSecValueData as String] as? Data == Data("new-token".utf8))
    calls.withLock { $0.append("add") }

    return addStatus.withLock { $0 }
  }

  func delete(_ query: [String: Any]) -> OSStatus { deleteStatus.withLock { $0 } }
}
