import AppKit
import FileSystem
import Foundation
@testable import MovieFolderCommon
import Network
import Persistence
import Synchronization
import Testing

@testable import MovieFolderPosters

/// Covers persistence, folder-access, overlap, and credential behavior in the host service.
struct DirectoryConfigurationServiceTests {
  /// Normal loading of old settings shows the recovery action without a separate discarded startup read.
  @Test @MainActor func configurationLoadExplainsRequiredMigration() async throws {
    let fixture = try ConfigurationServiceFixture()
    defer { fixture.cleanup() }
    var object = try #require(JSONSerialization.jsonObject(with:
      JSONEncoder().encode(DirectoryConfiguration())) as? [String: Any])
    object["version"] = 3
    let source = try PersistenceStore(directory: fixture.root.appendingPathComponent("Shared"))
    do {
      let persistenceAccess = try #require(try source.acquireAccess(for: ConfigurationRepository.recordKey))
      try persistenceAccess.write(JSONSerialization.data(withJSONObject: object))
    }
    let activity = MovieFolderActivityServiceFake()
    let model = ConfigurationViewModel(service: fixture.service, activity: activity)
    await model.load()

    #expect(model.errorMessage?.contains("Migrate Saved Data") == true)
    #expect(model.errorMessage?.contains("older data format") == true)
    #expect(try await activity.entries().contains { $0.event.text.contains("Migrate Saved Data") })
    #expect(!model.isBusy)
  }

  /// The normal setup and edit drafts report their committed historical collection names exactly once.
  @Test @MainActor func setupAndEditDraftsRecordCommittedContext() async throws {
    let activity = MovieFolderActivityServiceFake()
    let fixture = try ConfigurationServiceFixture(activity: activity)
    defer { fixture.cleanup() }
    let folder = fixture.root.appendingPathComponent("ActualSetupFolder")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let setup = CollectionSetupViewModel(service: fixture.service,
      applicationConfiguration: MovieMatchingConfiguration())
    await setup.prepare(folder)
    setup.displayName = "Historical collection name"
    #expect(await setup.commit())
    let directory = try #require(try fixture.repository.read().directories.first)
    let added = try await activity.entries().map(\.event)
    #expect(added.count == 1)
    #expect(added.first?.action == .collectionAdded)
    #expect(added.first?.status == .succeeded)
    #expect(added.first?.target?.collectionName == "Historical collection name")
    #expect(added.first?.collectionID == directory.id)
    let edit = CollectionEditViewModel(identifier: directory.id, service: fixture.service)
    await edit.load()
    edit.displayName = "Committed edited name"
    edit.setPaused(true)
    #expect(await edit.save())
    let recorded = try await activity.entries().map(\.event)
    #expect(recorded.count == 2)
    #expect(recorded.last?.status == .succeeded)
    #expect(recorded.last?.action == .collectionConfigurationSaved)
    #expect(recorded.last?.target?.collectionName == "Committed edited name")
    #expect(recorded.first?.target?.collectionName == "Historical collection name")
    #expect(try fixture.repository.read().directories.first?.processingConfiguration.isPaused == true)
  }

  /// Unprivating a draft cannot expose names captured while its original saved configuration was private.
  @Test(arguments: [(true, false), (false, true)]) @MainActor
  func editHistoryPreservesOriginalPrivateChoiceAndCommittedSuccessOnWriteFailure(
    _ previouslyUsedPrivateHistory: Bool, _ usesPrivateHistory: Bool
  ) async throws {
    let activity = MovieFolderActivityServiceFake()
    let fixture = try ConfigurationServiceFixture(activity: activity)
    defer { fixture.cleanup() }
    let directory = MonitoredDirectory(id: UUID(), path: fixture.root.path, transferBookmark: Data([1]),
      authorizationVersion: UUID(), displayName: "Original collection",
      usesPrivateHistory: previouslyUsedPrivateHistory)
    try fixture.repository.update { $0.directories = [directory] }
    let edit = CollectionEditViewModel(identifier: directory.id, service: fixture.service)
    await edit.load()
    edit.usesPrivateHistory = usesPrivateHistory
    edit.displayName = "Committed after save"
    #expect(await edit.save())
    let event = try #require(try await activity.entries().last?.event)
    #expect(event.target == .none)
    #expect(event.collectionID == .none)
    #expect(event.activityGroupID == .none)
    #expect(try fixture.repository.read().directories.first?.usesPrivateHistory == usesPrivateHistory)
    await activity.setFailures(write: true)
    let nextEdit = CollectionEditViewModel(identifier: directory.id, service: fixture.service)
    await nextEdit.load()
    nextEdit.displayName = "Saved despite optional history failure"
    #expect(await nextEdit.save())
    #expect(try fixture.repository.read().directories.first?.displayName == "Saved despite optional history failure")
  }

  /// Privacy-only edits rotate optional history without invalidating processing or authorization evidence.
}

/// Distinguishes processing invalidations from presentation-only changes.
final class CollectionSetupNotificationProbe: ConfigurationChangeNotifying, Sendable {
  /// Processing and presentation invalidation counts, in that order.
  private let counts = Mutex((configuration: Int.zero, presentation: Int.zero))
  /// How often Finder work would be invalidated.
  var configurationCount: Int { counts.withLock { $0.configuration } }
  /// How often friendly-name presentation was invalidated.
  var presentationCount: Int { counts.withLock { $0.presentation } }
  func configurationDidChange() { counts.withLock { $0.configuration += 1 } }
  func collectionPresentationDidChange() { counts.withLock { $0.presentation += 1 } }
}

/// Creates isolated persistence stores and service collaborators for each test.
@MainActor final class CollectionEditActionProbe: CollectionEditViewControllerDelegate {
  /// Number of explicit Save actions forwarded by the native controller.
  var saveCount = Int.zero
  /// Number of explicit Cancel actions forwarded by the native controller.
  var cancelCount = Int.zero
  func collectionEditViewControllerDidRequestSave(_ controller: CollectionEditViewController) { saveCount += 1 }
  func collectionEditViewControllerDidRequestCancel(_ controller: CollectionEditViewController) { cancelCount += 1 }
}

struct ConfigurationServiceFixture {
  /// Temporary root containing the fixture's stores.
  let root: URL
  /// Repository holding directory configuration.
  let repository: ConfigurationRepository
  /// Store holding security bookmark records.
  let authorizations: PersistenceStore
  /// In-memory credential provider used by the test service.
  let credentials = ConfigurationCredentialProbe()
  /// Service configured with the fixture's dependencies.
  let service: DirectoryConfigurationService

  /// Creates an isolated service fixture with the requested authorization behavior.
  init(
    authorization: any DirectoryAuthorizationProviding = TestDirectoryAuthorization(mode: .implicit),
    activity: (any MovieFolderActivityServicing)? = .none
  ) throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    repository = ConfigurationRepository(
      store: try PersistenceStore(
        directory:
          root
          .appendingPathComponent("Shared")))
    authorizations = try PersistenceStore(directory: root.appendingPathComponent("Private"))
    service = DirectoryConfigurationService(
      repository: repository,
      authorizations: authorizations,
      credentials: credentials, notifier: SilentConfigurationNotifier(),
      authorization: authorization, activity: activity ?? MovieFolderActivityServiceFake(),
      credentialTransport: CredentialTestTransport(),
      recovery: ProcessingRecoveryService(
        store: try PersistenceStore(directory: root.appendingPathComponent("Recovery"))))
  }

  /// Removes all persistence records created by this fixture.
  func cleanup() { try? FileManager.default.removeItem(at: root) }
}

/// Thread-safe in-memory credential store for service tests.
final class ConfigurationCredentialProbe: CredentialStoring {
  /// Stores the token while supporting the service's Sendable contract.
  private let value = Mutex<String?>(.none)
  /// Returns the currently saved test token.
  func read() -> String? { value.withLock { $0 } }
  /// Replaces the currently saved test token.
  func save(_ value: String) { self.value.withLock { $0 = value } }
  /// Clears the saved test token.
  func remove() { value.withLock { $0 = .none } }
}

/// No-op notifier for tests that do not inspect notifications.
struct SilentConfigurationNotifier: ConfigurationChangeNotifying {
  /// Ignores configuration-change notifications.
  func configurationDidChange() {}
}

/// Controls bookmark resolution behavior for authorization edge-case tests.
struct TestDirectoryAuthorization: DirectoryAuthorizationProviding {
  /// Bookmark resolution outcome simulated by the fake.
  enum Mode { case scoped, implicit, stale, invalid }
  /// Current outcome to use when resolving a bookmark.
  var mode: Mode = .scoped

  /// Resolves a bookmark according to the selected test mode.
  func acquireAccess(bookmark: Data, expectedIdentity: String?) throws -> AuthorizedDirectoryAccess {
    switch mode {
    case .stale: throw DirectoryAccessError.staleBookmark
    case .invalid: throw DirectoryAccessError.invalidDirectory
    case .scoped, .implicit:
      return try FileSystemService().acquireDirectoryAccess(
        bookmark: bookmark,
        securityScoped: mode == .scoped, expectedIdentity: expectedIdentity)
    }
  }
  /// Creates a transfer bookmark for the selected test directory.
  func makeBookmark(for directory: URL) throws -> Data { try FileSystemService().makeTransferBookmark(for: directory) }
}

/// Records configuration notifications and reads the committed appearance.
final class ConfigurationNotifierProbe: ConfigurationChangeNotifying, Sendable {
  /// Repository read after a notification to verify commit ordering.
  private let repository: ConfigurationRepository
  /// Last persisted appearance observed after notification.
  private let appearance = Mutex<PosterAppearance?>(.none)

  /// Creates the probe with the repository whose committed state it observes.
  init(repository: ConfigurationRepository) { self.repository = repository }
  /// Reads the saved appearance after a service notification.
  func configurationDidChange() {
    let saved = try? repository.read().posterAppearance
    appearance.withLock { $0 = saved }
  }
  /// The last appearance observed by the notification callback.
  var observedAppearance: PosterAppearance? { appearance.withLock { $0 } }
}

/// Forces the post-change summary to fail at the credential boundary.
struct FailingSummaryCredentials: CredentialStoring {
  /// Rejects summary credential lookup independently of configuration change.
  func read() throws -> String? { throw CocoaError(.fileReadUnknown) }
  /// No credential writes are needed by these removal tests.
  func save(_ value: String) {}
  /// No credential removals are needed by these removal tests.
  func remove() {}
}

/// Represents unavailable outcome storage after configuration has committed.
struct FailingProcessingCleanup: CollectionProcessingCleaning {
  /// Rejects cleanup so removal's independent failure handling is observable.
  func pruneToConfiguredRoots() throws -> Set<String> { throw CocoaError(.fileWriteUnknown) }
}

/// Observes directory access lifetime without retaining the authorization it measures.
final class InclusionAuthorizationLifetimeProbe: DirectoryAuthorizationProviding {
  /// A weak reference retains neither the directory access nor its security scope.
  struct WeakDirectoryAccess: Sendable {
    /// Latest authorized access, cleared automatically when its owner releases it.
    weak var directoryAccess: AuthorizedDirectoryAccess?
  }
  /// Serializes observation independently of the service actor.
  private let latestDirectoryAccess = Mutex(WeakDirectoryAccess())
  /// Whether an authorization returned by this probe is still held by its caller.
  var hasActiveDirectoryAccess: Bool { latestDirectoryAccess.withLock { $0.directoryAccess != nil } }

  func acquireAccess(bookmark: Data, expectedIdentity: String?) throws -> AuthorizedDirectoryAccess {
    let directoryAccess = try FileSystemService().acquireDirectoryAccess(
      bookmark: bookmark, securityScoped: false, expectedIdentity: expectedIdentity)
    latestDirectoryAccess.withLock { $0.directoryAccess = directoryAccess }

    return directoryAccess
  }

  func makeBookmark(for directory: URL) throws -> Data {
    try FileSystemService().makeTransferBookmark(for: directory)
  }
}

/// Reacquires real shared grants at the postcommit history boundary instead of relying on scheduling races.
actor InclusionCommittedHistoryProbe: MovieFolderActivityServicing {
  /// Committed collection repository, which must already be released by the mutating service.
  private let repository: ConfigurationRepository
  /// Shared authorization records whose prior lease must have drained.
  private let authorizations: PersistenceStore
  /// Configured root represented by the explicit inclusion action.
  private let directory: MonitoredDirectory
  /// Validated child whose committed exclusion must precede history.
  private let childIdentity: String
  /// Weak directory-access lifetime observer.
  private let authorization: InclusionAuthorizationLifetimeProbe
  /// Whether the history callback observed the actual committed exclusion.
  private(set) var observedCommittedExclusion = false
  /// Whether the history callback could reacquire the bookmark's exclusive record access.
  private(set) var observedReleasedBookmarkAccess = false
  /// Whether the prior directory access had drained before optional history.
  private(set) var observedReleasedDirectoryAccess = false
  /// Whether the history callback could read settings through a newly acquired configuration access.
  private(set) var observedReleasedConfigurationAccess = false
  /// Actual events crossing this optional history boundary.
  private(set) var recordedEvents: [MovieFolderActivityLogEvent] = []

  /// Retains the independent stores and observers needed to verify the history boundary.
  init(
    repository: ConfigurationRepository, authorizations: PersistenceStore, directory: MonitoredDirectory,
    childIdentity: String, authorization: InclusionAuthorizationLifetimeProbe
  ) {
    self.repository = repository
    self.authorizations = authorizations
    self.directory = directory
    self.childIdentity = childIdentity
    self.authorization = authorization
  }

  func record(_ event: MovieFolderActivityLogEvent) -> Bool {
    recordedEvents.append(event)
    observedReleasedDirectoryAccess = !authorization.hasActiveDirectoryAccess
    do {
      let key = "host-\(directory.id)-\(directory.authorizationVersion)"
      let bookmarkAccess = try authorizations.acquireAccess(for: key)
      observedReleasedBookmarkAccess = bookmarkAccess != nil
      let configuration = try repository.read()
      observedReleasedConfigurationAccess = true
      observedCommittedExclusion = configuration.directories.first { $0.id == directory.id }?
        .processingConfiguration.excludesFolder(identity: childIdentity) == true
      withExtendedLifetime(bookmarkAccess) {}
    } catch { return false }

    return true
  }

  func entries() -> [MovieFolderActivityLogEntry] { [] }
  func clear() {}
}
