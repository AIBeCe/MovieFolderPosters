import FileSystem
import Foundation
import MovieFolderCommon
import Persistence
import Testing

@testable import MovieFolderPosters

/// Verifies authorization replacement and configuration recovery against real private stores.
struct DirectoryConfigurationServiceCoverageTests {
  /// Restoring access retains collection identity while replacing the authorization generation and path.
  @Test func reauthorizationReplacesGrantAndKeepsCollectionIdentity() async throws {
    let fixture = try DirectoryServiceCoverageFixture()
    defer { fixture.cleanup() }
    let original = try fixture.makeDirectory("Original")
    let replacement = try fixture.makeDirectory("Replacement")
    try await fixture.service.addDirectory(original)
    let before = try #require(try fixture.repository.read().directories.first)
    try await fixture.service.reauthorizeDirectory(before.id, replacement)
    let after = try #require(try fixture.repository.read().directories.first)
    #expect(after.id == before.id)
    #expect(after.authorizationVersion != before.authorizationVersion)
    #expect(after.path == replacement.standardizedFileURL.path)
    #expect(after.identity == (try FileSystemService().persistentDirectoryIdentity(at: replacement)))
    let summary = try await fixture.service.configurationSummary()
    #expect(summary.directories.count == 1)
    #expect(summary.directories.first?.path == replacement.standardizedFileURL.path)
    #expect(summary.directories.first?.availability == .available)
  }

  /// Invalid restoration targets leave every committed collection unchanged.
  @Test(arguments: ["unknown", "duplicate", "nested"])
  func rejectsInvalidRestorationWithoutChangingConfiguration(_ scenario: String) async throws {
    let fixture = try DirectoryServiceCoverageFixture()
    defer { fixture.cleanup() }
    let first = try fixture.makeDirectory("First")
    let second = try fixture.makeDirectory("Second")
    let nested = second.appendingPathComponent("Nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try await fixture.service.addDirectory(first)
    try await fixture.service.addDirectory(second)
    let before = try fixture.repository.read()
    let identifier = try #require(before.directories.first?.id)
    do {
      switch scenario {
      case "unknown": try await fixture.service.reauthorizeDirectory(UUID(), first)
      case "duplicate": try await fixture.service.reauthorizeDirectory(identifier, second)
      default: try await fixture.service.reauthorizeDirectory(identifier, nested)
      }
      Issue.record("Invalid restoration must fail")
    } catch ConfigurationError.directoryNotFound {
      #expect(scenario == "unknown")
    } catch ConfigurationError.duplicateDirectory {
      #expect(scenario == "duplicate")
    } catch ConfigurationError.overlappingDirectory {
      #expect(scenario == "nested")
    }
    #expect(try fixture.repository.read().directories == before.directories)
  }

  /// Selecting an already configured root cannot create duplicate processing scopes.
  @Test func addingDuplicatePreservesOneCollection() async throws {
    let fixture = try DirectoryServiceCoverageFixture()
    defer { fixture.cleanup() }
    let directory = try fixture.makeDirectory("Movies")
    try await fixture.service.addDirectory(directory)
    do {
      try await fixture.service.addDirectory(directory)
      Issue.record("The same root must not be registered twice")
    } catch ConfigurationError.duplicateDirectory {}
    #expect(try fixture.repository.read().directories.count == 1)
  }

  #if DEBUG
  /// Explicit development-fixture changes invalidate the prior processing context on every committed choice.
  @Test func developmentFixtureOptInChangesProcessingRevision() async throws {
    let fixture = try DirectoryServiceCoverageFixture()
    defer { fixture.cleanup() }
    let before = try fixture.repository.read()
    try await fixture.service.setStubTMDbResponsesEnabled(true)
    let enabled = try fixture.repository.read()
    #expect(enabled.usesStubTMDbResponses)
    #expect(enabled.credentialRevision != before.credentialRevision)
    try await fixture.service.setStubTMDbResponsesEnabled(false)
    let disabled = try fixture.repository.read()
    #expect(!disabled.usesStubTMDbResponses)
    #expect(disabled.credentialRevision != enabled.credentialRevision)
  }
  #endif

  /// Bookmark failures retain their distinct user recovery states instead of claiming available access.
  @Test(arguments: [CoverageAuthorization.Mode.denied, .changed, .invalid])
  func failedAuthorizationProducesRecoverableAvailability(_ mode: CoverageAuthorization.Mode) async throws {
    let fixture = try DirectoryServiceCoverageFixture(mode: mode)
    defer { fixture.cleanup() }
    let directory = try fixture.makeDirectory("Movies")
    try await fixture.service.addDirectory(directory)
    let summary = try await fixture.service.configurationSummary()
    switch mode {
    case .denied: #expect(summary.directories.first?.availability == .reauthorizationRequired)
    case .changed: #expect(summary.directories.first?.availability == .identityChanged)
    case .invalid: #expect(summary.directories.first?.availability == .unavailable)
    case .accessible: Issue.record("Unexpected fixture mode")
    }
  }
}

/// Owns real configuration and authorization storage without accessing application state.
private struct DirectoryServiceCoverageFixture {
  /// Parent of all test-owned files and directories.
  let root: URL
  /// Real configuration used to check commit behavior.
  let repository: ConfigurationRepository
  /// Host service retaining isolated dependencies.
  let service: DirectoryConfigurationService

  /// Composes the service with real storage and an explicit external bookmark boundary.
  init(mode: CoverageAuthorization.Mode = .accessible) throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    repository = ConfigurationRepository(
      store: try PersistenceStore(directory: root.appendingPathComponent("Settings")))
    service = DirectoryConfigurationService(repository: repository,
      authorizations: try PersistenceStore(directory: root.appendingPathComponent("Authorization")),
      credentials: CoverageCredentials(), notifier: CoverageConfigurationNotifier(),
      authorization: CoverageAuthorization(mode: mode), activity: ActivityServiceFake())
  }

  /// Creates one real movie root for a user selection.
  func makeDirectory(_ name: String) throws -> URL {
    let directory = root.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    return directory
  }

  /// Removes the fixture's own files after the service operation has finished.
  func cleanup() { try? FileManager.default.removeItem(at: root) }
}

/// Replaces only the unavailable security-bookmark creation agent and explicit authorization failures.
struct CoverageAuthorization: DirectoryAuthorizationProviding {
  /// Distinct authorization outcomes whose recovery paths the service must preserve.
  enum Mode: Sendable { case accessible, denied, changed, invalid }
  /// Requested external authorization outcome.
  let mode: Mode

  func acquireAccess(bookmark: Data, expectedIdentity: String?) throws -> DirectoryAccessLease {
    switch mode {
    case .accessible:
      try FileSystemService().acquireDirectoryAccess(bookmark: bookmark, securityScoped: false,
        expectedIdentity: expectedIdentity)
    case .denied: throw DirectoryAccessError.accessDenied
    case .changed: throw DirectoryAccessError.identityChanged
    case .invalid: throw CocoaError(.fileReadUnknown)
    }
  }
  func makeBookmark(for directory: URL) throws -> Data { try FileSystemService().makeTransferBookmark(for: directory) }
}

/// Keeps test configuration changes in process without notifying a user's running app copies.
private struct CoverageConfigurationNotifier: ConfigurationChangeNotifying {
  func configurationDidChange() {}
}

/// Supplies no credential without consulting Keychain.
private struct CoverageCredentials: CredentialStoring {
  func read() throws -> String? { .none }
  func save(_ value: String) throws {}
  func remove() throws {}
}
