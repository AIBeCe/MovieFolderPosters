import Foundation
@testable import MovieFolderCommon
import Network
import Persistence
import Synchronization
import Testing
/// Network history stores only terminal typed evidence under currentConfiguration shared privacy choices.
struct MovieFolderNetworkHistoryTests {
  /// Disabled recording does not start a recording revision; toggling or privacy changes invalidate in-flight work.
  @Test func networkRecordingRevisionRespectsPrivacyAndRetainsExistingEntries() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let configurationRepository = ConfigurationRepository(store: try PersistenceStore(
    directory: directory.appendingPathComponent("Settings")))
    let root = MonitoredDirectory(id: UUID(), path: "/Movies", transferBookmark: Data([1]),
      authorizationVersion: UUID())
    try configurationRepository.update { $0.directories = [root] }
    let networkHistoryService = MovieFolderNetworkHistoryService(directory: directory.appendingPathComponent("History"),
      configurationRepository: configurationRepository)
    #expect(await networkHistoryService.prepareNetworkHistoryRecording(collectionID: root.id) == .none)
    try await networkHistoryService.setNetworkHistoryRecordingEnabled(true)
    let expectedNetworkHistoryConfigurationRevision = try #require(
      await networkHistoryService.prepareNetworkHistoryRecording(collectionID: root.id))
    await networkHistoryService.recordCompletedNetworkRequest(
      purpose: .movieSearch, result: .response(statusCode: 200), completedAt: Date(),
      expectedNetworkHistoryConfigurationRevision: expectedNetworkHistoryConfigurationRevision, collectionID: root.id)
    #expect(try await networkHistoryService.entries().count == 1)
    try configurationRepository.update { $0.directories[0].usesPrivateHistory = true }
    await networkHistoryService.recordCompletedNetworkRequest(
      purpose: .posterDownload, result: .transportFailure, completedAt: Date(),
      expectedNetworkHistoryConfigurationRevision: expectedNetworkHistoryConfigurationRevision, collectionID: root.id)
    #expect(await networkHistoryService.prepareNetworkHistoryRecording(collectionID: root.id) == .none)
    #expect(try await networkHistoryService.entries().count == 1)
    #expect(!(await networkHistoryService.hasObservedWriteFailure))
    try await networkHistoryService.setNetworkHistoryRecordingEnabled(false)
    #expect(try await networkHistoryService.entries().first?.event.collectionID == root.id)
    try await networkHistoryService.clear()
    #expect(try await networkHistoryService.entries().isEmpty)
  }
  /// A global attempt is invalidated by disable/re-enable, even if enabled again at completion.
  @Test func networkHistoryRevisionPreventsLateAppendAfterDisableAndReenable() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let configurationRepository = ConfigurationRepository(store: try PersistenceStore(
    directory: directory.appendingPathComponent("Settings")))
    let networkHistoryService = MovieFolderNetworkHistoryService(directory: directory.appendingPathComponent("History"),
      configurationRepository: configurationRepository)
    try await networkHistoryService.setNetworkHistoryRecordingEnabled(true)
    let expectedNetworkHistoryConfigurationRevision = try #require(
      await networkHistoryService.prepareNetworkHistoryRecording(collectionID: .none))
    try await networkHistoryService.setNetworkHistoryRecordingEnabled(false)
    try await networkHistoryService.setNetworkHistoryRecordingEnabled(true)
    await networkHistoryService.recordCompletedNetworkRequest(
      purpose: .credentialValidation, result: .cancelled, completedAt: Date(),
      expectedNetworkHistoryConfigurationRevision: expectedNetworkHistoryConfigurationRevision, collectionID: .none)
    #expect(try await networkHistoryService.entries().isEmpty)
    #expect(!(await networkHistoryService.hasObservedWriteFailure))
  }
}
/// Collection removal and unreadable settings intentionally omit optional history.
@Test func removedRootsAndUnreadableSettingsSkipNetworkHistory() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let settingsStore = try PersistenceStore(directory: directory.appendingPathComponent("Settings"))
  let configurationRepository = ConfigurationRepository(store: settingsStore)
  let root = MonitoredDirectory(id: UUID(), path: "/Movies", transferBookmark: Data([1]), authorizationVersion: UUID())
  try configurationRepository.update { $0.directories = [root]; $0.isNetworkHistoryRecordingEnabled = true }
  let networkHistoryService = MovieFolderNetworkHistoryService(directory: directory.appendingPathComponent("History"),
    configurationRepository: configurationRepository)
  let expectedNetworkHistoryConfigurationRevision = try #require(
    await networkHistoryService.prepareNetworkHistoryRecording(collectionID: root.id))
  try configurationRepository.update { $0.directories.removeAll() }
  await networkHistoryService.recordCompletedNetworkRequest(
    purpose: .posterDownload, result: .response(statusCode: 200), completedAt: Date(),
    expectedNetworkHistoryConfigurationRevision: expectedNetworkHistoryConfigurationRevision, collectionID: root.id)
  #expect(await networkHistoryService.prepareNetworkHistoryRecording(collectionID: root.id) == .none)
  let globalNetworkHistoryConfigurationRevision = try #require(
    await networkHistoryService.prepareNetworkHistoryRecording(collectionID: .none))
  do {
    let configurationPersistenceAccess = try #require(
      try settingsStore.acquireAccess(for: ConfigurationRepository.recordKey))
    #expect(await networkHistoryService.prepareNetworkHistoryRecording(collectionID: .none) == .none)
    await networkHistoryService.recordCompletedNetworkRequest(
      purpose: .movieSearch, result: .transportFailure, completedAt: Date(),
      expectedNetworkHistoryConfigurationRevision: globalNetworkHistoryConfigurationRevision, collectionID: .none)
    withExtendedLifetime(configurationPersistenceAccess) {}
  }
  #expect(try await networkHistoryService.entries().isEmpty)
  #expect(!(await networkHistoryService.hasObservedWriteFailure))
}
/// History contention is an actual optional storage failure and never leaves settings access held.
@Test func networkHistoryContentionPreservesExistingBytesAndReleasesSettings() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let configurationRepository = ConfigurationRepository(store: try PersistenceStore(
    directory: directory.appendingPathComponent("Settings")))
  let networkHistoryDirectory = directory.appendingPathComponent("History")
  let networkHistoryService = MovieFolderNetworkHistoryService(directory: networkHistoryDirectory,
    configurationRepository: configurationRepository)
  try await networkHistoryService.setNetworkHistoryRecordingEnabled(true)
  let expectedNetworkHistoryConfigurationRevision = try #require(
    await networkHistoryService.prepareNetworkHistoryRecording(collectionID: .none))
  await networkHistoryService.recordCompletedNetworkRequest(
    purpose: .credentialValidation, result: .response(statusCode: 401), completedAt: Date(),
    expectedNetworkHistoryConfigurationRevision: expectedNetworkHistoryConfigurationRevision, collectionID: .none)
  let historyPersistenceStore = try PersistenceStore(directory: networkHistoryDirectory)
  do {
    let historyPersistenceAccess = try #require(
      try historyPersistenceStore.acquireAccess(for: "Log.Activity.v1.movie-network"))
    let before = try historyPersistenceAccess.read()
    await networkHistoryService.recordCompletedNetworkRequest(
      purpose: .movieSearch, result: .transportFailure, completedAt: Date(),
      expectedNetworkHistoryConfigurationRevision: expectedNetworkHistoryConfigurationRevision, collectionID: .none)
    #expect(try historyPersistenceAccess.read() == before)
    #expect(try configurationRepository.read().isNetworkHistoryRecordingEnabled)
    withExtendedLifetime(historyPersistenceAccess) {}
  }
  #expect(await networkHistoryService.hasObservedWriteFailure)
  #expect(try await networkHistoryService.entries().count == 1)
  await networkHistoryService.recordCompletedNetworkRequest(
    purpose: .movieSearch, result: .cancelled, completedAt: Date(),
    expectedNetworkHistoryConfigurationRevision: expectedNetworkHistoryConfigurationRevision, collectionID: .none)
  #expect(try await networkHistoryService.entries().map(\.sequence) == [1, 2])
}
/// The closed representation has no slot for paths, request bodies, queries, or arbitrary error strings.
@Test func networkHistoryVocabularyRoundTrips() throws {
  for purpose: TMDbRequestCategory in [.credentialValidation, .movieSearch, .posterConfiguration, .posterDownload] {
    for result: TMDbRequestCompletionResult in [.response(statusCode: 200), .transportFailure, .cancelled, .responseTooLarge] {
      let event = MovieFolderNetworkHistoryEvent(purpose: purpose, result: result, collectionID: UUID())
      let encoded = try JSONEncoder().encode(event)
      #expect(try JSONDecoder().decode(MovieFolderNetworkHistoryEvent.self, from: encoded) == event)
      #expect(encoded.count < 2048)
      #expect(!event.text.isEmpty)
      #expect(!event.category.isEmpty)
      #expect(!event.severity.isEmpty)
    }
  }
}
/// Credential diagnostics use real HTTP even when movie processing selects Debug fixture transport.
@Test func fixtureMovieModeDoesNotSuppressRealCredentialHistory() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let configurationRepository = ConfigurationRepository(store: try PersistenceStore(
    directory: directory.appendingPathComponent("Settings")))
  try configurationRepository.update { $0.isNetworkHistoryRecordingEnabled = true; $0.usesStubTMDbResponses = true }
  let networkHistoryService = MovieFolderNetworkHistoryService(directory: directory.appendingPathComponent("History"),
    configurationRepository: configurationRepository)
  let expectedNetworkHistoryConfigurationRevision = try #require(
    await networkHistoryService.prepareNetworkHistoryRecording(collectionID: .none))
  await networkHistoryService.recordCompletedNetworkRequest(
    purpose: .credentialValidation, result: .response(statusCode: 200), completedAt: Date(),
    expectedNetworkHistoryConfigurationRevision: expectedNetworkHistoryConfigurationRevision, collectionID: .none)
  #expect(try await networkHistoryService.entries().first?.event.purpose == .credentialValidation)
}
/// Counts committed-history hints and verifies that callbacks can immediately read shared configuration.
private final class NetworkHistoryNotifierProbe: MovieFolderNetworkHistoryChangeNotifying {
  /// Shared settings repository used only to inspect notification ordering.
  private let configurationRepository: ConfigurationRepository
  /// Number of committed network history hints.
  private let historyChanges = Mutex(Int.zero)
  /// Whether a callback encountered a configuration access still held by the writer.
  private let configurationReadFailed = Mutex(false)
  /// Number of history invalidations received.
  var committedHistoryChanges: Int { historyChanges.withLock { $0 } }
  /// Whether a history callback failed to read configuration immediately.
  var didObserveConfigurationReadFailure: Bool { configurationReadFailed.withLock { $0 } }
  /// Retains the real repository so notification timing is exercised through cross-instance storage access.
  init(configurationRepository: ConfigurationRepository) { self.configurationRepository = configurationRepository }
  func movieFolderNetworkHistoryDidChange() {
    historyChanges.withLock { $0 += 1 }
    do { _ = try configurationRepository.read() } catch { configurationReadFailed.withLock { $0 = true } }
  }
  func movieFolderHistoryConfigurationDidChange() {}
}
/// Appended, intentionally omitted, and failed history handling have distinct public notification behavior.
@Test func networkAppendOutcomesNotifyOnlyDurableCommitsAfterReleasingConfiguration() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let configurationRepository = ConfigurationRepository(store: try PersistenceStore(
    directory: directory.appendingPathComponent("Settings")))
  let networkHistoryDirectory = directory.appendingPathComponent("History")
  let notifier = NetworkHistoryNotifierProbe(configurationRepository: configurationRepository)
  let networkHistoryService = MovieFolderNetworkHistoryService(directory: networkHistoryDirectory,
    configurationRepository: configurationRepository, notifier: notifier)
  try await networkHistoryService.setNetworkHistoryRecordingEnabled(true)
  let expectedNetworkHistoryConfigurationRevision = try #require(
    await networkHistoryService.prepareNetworkHistoryRecording(collectionID: .none))
  await networkHistoryService.recordCompletedNetworkRequest(purpose: .movieSearch,
    result: .response(statusCode: 200), completedAt: Date(),
    expectedNetworkHistoryConfigurationRevision: expectedNetworkHistoryConfigurationRevision, collectionID: .none)
  #expect(notifier.committedHistoryChanges == 1)
  #expect(!notifier.didObserveConfigurationReadFailure)
  try await networkHistoryService.setNetworkHistoryRecordingEnabled(false)
  await networkHistoryService.recordCompletedNetworkRequest(purpose: .movieSearch,
    result: .response(statusCode: 200), completedAt: Date(),
    expectedNetworkHistoryConfigurationRevision: expectedNetworkHistoryConfigurationRevision, collectionID: .none)
  #expect(notifier.committedHistoryChanges == 1)
  #expect(!(await networkHistoryService.hasObservedWriteFailure))
  try await networkHistoryService.setNetworkHistoryRecordingEnabled(true)
  let currentNetworkHistoryConfigurationRevision = try #require(
    await networkHistoryService.prepareNetworkHistoryRecording(collectionID: .none))
  let historyPersistenceStore = try PersistenceStore(directory: networkHistoryDirectory)
  do {
    let historyPersistenceAccess = try #require(
      try historyPersistenceStore.acquireAccess(for: "Log.Activity.v1.movie-network"))
    await networkHistoryService.recordCompletedNetworkRequest(purpose: .movieSearch,
      result: .transportFailure, completedAt: Date(),
      expectedNetworkHistoryConfigurationRevision: currentNetworkHistoryConfigurationRevision, collectionID: .none)
    withExtendedLifetime(historyPersistenceAccess) {}
  }
  #expect(notifier.committedHistoryChanges == 1)
  #expect(await networkHistoryService.hasObservedWriteFailure)
  #expect(try await networkHistoryService.entries().count == 1)
}
