import AppKit
import FileSystem
import Foundation
import MovieFolderCommon
import Persistence
import Testing
@testable import MovieFolderPosters

/// Verifies local utility admission using real disposable authorization and processing stores.
struct MovieFolderFinderActionServiceTests {
  /// Artwork failure and partial collection work preserve a verified movie identity.
  @Test func copiesVerifiedFailureAndRetainsSettingsFence() async throws {
    let fixture = try UtilityFixture()
    defer { fixture.cleanup() }
    try seed(fixture, title: "  Dune  ")
    let service = MovieFolderFinderActionService(environment: fixture)
    let request = try MovieFolderContextMenuRequest(rootID: fixture.request.rootID,
      target: .child(name: fixture.request.childName, identity: fixture.request.identity), action: .copyMovieTitle)
    do {
      let effect = try await service.prepareCopy(request)
      #expect(effect.text == "Dune")
      #expect(throws: ConfigurationError.self) { try fixture.repository.read() }
      #expect(effect.authorization.root.resolvingSymlinksInPath().path == fixture.movies.resolvingSymlinksInPath().path)
    }
    #expect(try fixture.repository.read().directories.count == 1)
  }

  /// Identifier copying does not depend on a saved title, while Title never falls back to parsed text.
  @Test func identifierWithoutTitleAndStaleEvidence() async throws {
    let fixture = try UtilityFixture()
    defer { fixture.cleanup() }
    try seed(fixture, title: " ")
    let service = MovieFolderFinderActionService(environment: fixture)
    let target = MovieFolderContextMenuRequest.Target.child(
      name: fixture.request.childName, identity: fixture.request.identity)
    let title = try MovieFolderContextMenuRequest(
      rootID: fixture.request.rootID, target: target, action: .copyMovieTitle)
    await #expect(throws: MovieFolderUtilityError.self) { try await service.prepareCopy(title) }
    let identifier = try MovieFolderContextMenuRequest(
      rootID: fixture.request.rootID, target: target, action: .copyMovieIdentifier)
    do {
      let effect = try await service.prepareCopy(identifier)
      #expect(effect.text == "7")
    }
    try fixture.repository.update { $0.credentialRevision = UUID() }
    await #expect(throws: MovieFolderUtilityError.self) { try await service.prepareCopy(identifier) }
    // Stale processing context still permits a complete, physically matching unresolved Reveal.
    let reveal = try await service.prepareReveal(rootID: fixture.request.rootID, selections: [target])
    #expect(reveal.urls.map(\.lastPathComponent) == [fixture.request.childName])
  }

  /// Any invalid member rejects the whole Reveal instead of silently filtering the selection.
  @Test func rejectsWholeRevealWhenOneIdentityDiffers() async throws {
    let fixture = try UtilityFixture()
    defer { fixture.cleanup() }
    try seed(fixture, title: "Dune")
    let service = MovieFolderFinderActionService(environment: fixture)
    await #expect(throws: MovieFolderUtilityError.self) {
      try await service.prepareReveal(rootID: fixture.request.rootID, selections: [
        .child(name: fixture.request.childName, identity: fixture.request.identity),
        .child(name: "Missing", identity: "invalid")])
    }
    #expect(try fixture.repository.read().directories.count == 1)
  }

  /// Saves a verified metadata identity with failed artwork, without making provider or icon calls.
  private func seed(_ fixture: UtilityFixture, title: String) throws {
    let configuration = try fixture.repository.read()
    let directory = try #require(configuration.directories.first)
    let context = CollectionProcessingContext(rootID: directory.id,
      rootIdentity: try #require(directory.identity), authorizationVersion: directory.authorizationVersion,
      credentialRevision: configuration.credentialRevision, usesStubTMDbResponses: configuration.usesStubTMDbResponses,
      appearance: configuration.posterAppearance,
      movieMatchingConfiguration: configuration.effectiveMovieMatchingConfiguration(for: directory),
      processingConfigurationRevision: directory.processingConfiguration.revision)
    var state = try fixture.processing.recordProcessingStart(context: context, action: .automatic)
    state.folders = [FolderProcessingRecord(name: fixture.request.childName, identity: fixture.request.identity,
      state: .failed, reason: .missingArtwork, movieID: 7, movieTitle: title,
      movieIdentitySource: .explicitSelection, assessedAt: Date())]
    state.currentRun?.state = .partial
    _ = try fixture.processing.commit(state, expectedRevision: state.revision)
  }
}

extension MovieFolderFinderActionServiceTests {
  /// Unverified provenance, replacement folders, and zero/oversized Reveal selections reject admission.
  @Test(arguments: ["provenance", "replacement", "empty", "oversized", "resolved"])
  func rejectsInvalidUtilityEvidence(_ scenario: String) async throws {
    let fixture = try UtilityFixture()
    defer { fixture.cleanup() }
    try seed(fixture, title: "Dune")
    let service = MovieFolderFinderActionService(environment: fixture)
    let target = MovieFolderContextMenuRequest.Target.child(
      name: fixture.request.childName, identity: fixture.request.identity)
    if scenario == "replacement" {
      try FileManager.default.moveItem(at: fixture.movies.appendingPathComponent(fixture.request.childName),
        to: fixture.movies.appendingPathComponent("Previous"))
      try FileManager.default.createDirectory(at: fixture.movies.appendingPathComponent(fixture.request.childName),
        withIntermediateDirectories: false)
    }
    if scenario == "provenance" || scenario == "resolved" {
      var state = try #require(try fixture.processing.read(rootID: fixture.request.rootID))
      if scenario == "provenance" { state.folders[0].movieIdentitySource = .none }
      if scenario == "resolved" { state.folders[0].state = .preserved }
      _ = try fixture.processing.commit(state, expectedRevision: state.revision)
    }
    if scenario == "provenance" || scenario == "replacement" {
      let request = try MovieFolderContextMenuRequest(rootID: fixture.request.rootID, target: target,
        action: .copyMovieIdentifier)
      await #expect(throws: (any Error).self) { try await service.prepareCopy(request) }
    } else {
      let selection = scenario == "empty" ? [] : Array(repeating: target, count: scenario == "oversized" ? 33 : 1)
      await #expect(throws: (any Error).self) {
        try await service.prepareReveal(rootID: fixture.request.rootID, selections: selection)
      }
    }
  }

  /// Closing or configuration invalidation prevents late effects from noncooperative preparation.
  @Test @MainActor func invalidationSuppressesPreparedClipboardEffect() async throws {
    let fixture = try UtilityFixture()
    defer { fixture.cleanup() }
    try seed(fixture, title: "Dune")
    let gate = UtilityPreparationGate()
    let utilities = SuspendedUtilityService(base: MovieFolderFinderActionService(environment: fixture), gate: gate)
    let platform = UtilityPlatformProbe(repository: fixture.repository)
    let request = try MovieFolderContextMenuRequest(rootID: fixture.request.rootID,
      target: .child(name: fixture.request.childName, identity: fixture.request.identity), action: .copyMovieTitle)
    let summaries = CollectionSummaryViewModel(service: EmptyCollectionSummaryService())
    let model = CollectionProcessingDetailsViewModel(request: request, summaries: summaries,
      utilities: utilities, platform: platform)
    model.copy(.copyMovieTitle)
    await gate.waitForPreparation()
    model.invalidate()
    await gate.finish()
    for _ in 0..<100 where model.isBusy { await Task.yield() }
    #expect(platform.copied.isEmpty)
  }

  /// Results Reveal performs one exact naturally ordered selection, while close/configuration cancels late effects.
  /// - Parameter completion: Whether admission completes normally or after its sheet invalidates the pending effect.
  @Test(arguments: ["success", "close", "configuration"]) @MainActor
  func resultsViewModelRevealsExactSelectionAndSuppressesLateEffects(_ completion: String) async throws {
    let fixture = try UtilityFixture()
    defer { fixture.cleanup() }
    try seed(fixture, title: "Dune")
    var state = try #require(try fixture.processing.read(rootID: fixture.request.rootID))
    let fileSystem = FileSystemService()
    state.folders = try ["Movie 10", "Movie 2", "Movie 1"].map { name in
      try FileManager.default.createDirectory(at: fixture.movies.appendingPathComponent(name),
        withIntermediateDirectories: false)

      return FolderProcessingRecord(name: name,
        identity: try fileSystem.readCurrentState(ofChild: name, in: fixture.movies).identity,
        state: .failed, reason: .connectivity)
    }
    _ = try fixture.processing.commit(state, expectedRevision: state.revision)
    let summaries = CollectionSummaryViewModel(service: CollectionSummaryService(
      configuration: fixture.repository, processingStore: fixture.processing,
      coordinationStore: try PersistenceStore(directory: fixture.container.appendingPathComponent("ProcessingLocks"))))
    summaries.reload()
    for _ in 0..<200 where summaries.summary(for: fixture.request.rootID) == .none {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(try #require(summaries.summary(for: fixture.request.rootID)).unresolvedFolders()?.count == 3)
    let platform = UtilityPlatformProbe(repository: fixture.repository)
    let base = MovieFolderFinderActionService(environment: fixture)
    let gate = UtilityPreparationGate()
    let utilities: any MovieFolderFinderActionServicing = completion == "success" ? base
      : SuspendedUtilityService(base: base, gate: gate)
    let model = CollectionResultsViewModel(rootID: fixture.request.rootID, summaries: summaries,
      retryService: UnavailableCollectionRetryService(), utilityService: utilities, utilityPlatform: platform)
    #expect(model.rows.map(\.name) == ["Movie 1", "Movie 2", "Movie 10"])
    model.selectRows(IndexSet([1, 2]))
    model.revealSelected()
    if completion != "success" {
      await gate.waitForPreparation()
      #expect(model.isBusy && !model.canFilter && !model.canChooseMovie && !model.canRetrySelected)
      model.selectRows(IndexSet(integer: .zero))
      #expect(model.selectedRows == IndexSet([1, 2]))
      if completion == "close" { model.cancelRetryTask() } else { model.configurationDidChange() }
      await gate.finish()
    }
    for _ in 0..<200 where model.isBusy { try await Task.sleep(for: .milliseconds(5)) }
    #expect(!model.isBusy)
    if completion == "success" {
      #expect(platform.revealed.map { $0.map(\.lastPathComponent) } == [["Movie 2", "Movie 10"]])
      #expect(platform.configurationWasFenced)
      #expect(model.statusMessage == "Selected folders revealed in Finder.")
    } else {
      #expect(platform.revealed.isEmpty)
    }
    #expect(platform.copied.isEmpty)
    #expect(try fixture.repository.read().directories.count == 1)
  }

  /// The actual platform invocation still owns settings access and reports clipboard failure independently.
  @Test @MainActor func platformCallRetainsFenceAndReportsClipboardFailure() async throws {
    let fixture = try UtilityFixture()
    defer { fixture.cleanup() }
    try seed(fixture, title: "Dune")
    let request = try MovieFolderContextMenuRequest(rootID: fixture.request.rootID,
      target: .child(name: fixture.request.childName, identity: fixture.request.identity), action: .copyMovieTitle)
    let platform = UtilityPlatformProbe(repository: fixture.repository)
    platform.acceptsCopy = false
    let effect = try await MovieFolderFinderActionService(environment: fixture).prepareCopy(request)
    #expect(throws: MovieFolderUtilityError.self) { try effect.perform(using: platform) }
    #expect(platform.configurationWasFenced)
    #expect(platform.copied == ["Dune"])
  }
}

/// Captures only test-owned text without touching the system clipboard or Finder.
@MainActor private final class UtilityPlatformProbe: MovieFolderUtilityPlatform {
  /// Repository checked synchronously inside the platform boundary.
  let repository: ConfigurationRepository
  /// Whether the simulated clipboard accepts its write.
  var acceptsCopy = true
  /// Captured explicit writes.
  var copied: [String] = []
  /// Complete Finder selections received at the immediate platform boundary.
  var revealed: [[URL]] = []
  /// Settings access must remain unavailable throughout the platform call.
  var configurationWasFenced = false
  init(repository: ConfigurationRepository) { self.repository = repository }
  func copy(_ text: String) -> Bool {
    configurationWasFenced = (try? repository.read()) == .none
    copied.append(text)

    return acceptsCopy
  }
  func reveal(_ urls: [URL]) {
    configurationWasFenced = (try? repository.read()) == .none
    revealed.append(urls)
  }
}

/// Holds prepared access until the test invalidates its presentation owner.
private actor UtilityPreparationGate {
  /// Noncooperative response released explicitly by the test.
  private var response: CheckedContinuation<Void, Never>?
  /// Preparation notification.
  private var waiter: CheckedContinuation<Void, Never>?
  /// Prevents lost readiness notifications.
  private var prepared = false
  func pause() async {
    prepared = true
    waiter?.resume()
    waiter = .none
    await withCheckedContinuation { response = $0 }
  }
  func waitForPreparation() async {
    if prepared { return }
    await withCheckedContinuation { waiter = $0 }
  }
  func finish() { response?.resume(); response = .none }
}

/// Suspends after real utility admission while retaining its effect and every underlying lease.
private struct SuspendedUtilityService: MovieFolderFinderActionServicing {
  /// Real test-owned authorization service.
  let base: MovieFolderFinderActionService
  /// Deterministic noncooperative suspension boundary.
  let gate: UtilityPreparationGate
  @concurrent func inspectionStatus(_ request: MovieFolderContextMenuRequest) async throws -> String {
    try await base.inspectionStatus(request)
  }
  @concurrent func prepareCopy(_ request: MovieFolderContextMenuRequest) async throws -> PreparedMovieFolderUtility {
    let effect = try await base.prepareCopy(request)
    await gate.pause()

    return effect
  }
  @concurrent func prepareReveal(rootID: UUID, selections: [MovieFolderContextMenuRequest.Target]) async throws
    -> PreparedMovieFolderUtility {
    let effect = try await base.prepareReveal(rootID: rootID, selections: selections)
    await gate.pause()

    return effect
  }
}

/// Real disposable utility authorization and saved outcome storage.
private struct UtilityFixture: MoviePosterActionEnvironment {
  /// Parent of every disposable file used by the test.
  let container: URL
  /// Configured movie root.
  let movies: URL
  /// Stored configuration used for authorization checks.
  let repository: ConfigurationRepository
  /// Private bookmark persistence.
  let authorizations: PersistenceStore
  /// Real processing outcome store.
  let processing: CollectionProcessingStore
  /// Request bound to the real child identity.
  let request: MoviePosterRequest

  /// Creates real stores and a child folder whose identity can authorize the request.
  init() throws {
    container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    movies = container.appendingPathComponent("Movies")
    try FileManager.default.createDirectory(
      at: movies.appendingPathComponent("Dune (2021)"), withIntermediateDirectories: true)
    repository = ConfigurationRepository(
      store: try PersistenceStore(directory: container.appendingPathComponent("Settings")))
    authorizations = try PersistenceStore(directory: container.appendingPathComponent("Authorization"))
    processing = CollectionProcessingStore(
      store: try PersistenceStore(directory: container.appendingPathComponent("Outcomes")), configuration: repository)
    let fileSystem = FileSystemService()
    let directory = MonitoredDirectory(
      id: UUID(), path: movies.standardizedFileURL.path,
      transferBookmark: try fileSystem.makeTransferBookmark(for: movies), authorizationVersion: UUID(),
      identity: try fileSystem.persistentDirectoryIdentity(at: movies))
    try repository.update { $0.directories = [directory] }
    request = MoviePosterRequest(rootID: directory.id, childName: "Dune (2021)",
      identity: try fileSystem.readCurrentState(ofChild: "Dune (2021)", in: movies).identity, action: .change)
  }

  func makeDirectoryBookmark(for directory: URL) throws -> Data {
    try directory.bookmarkData(options: [], includingResourceValuesForKeys: .none, relativeTo: .none)
  }
  func appGroupContainerURL() throws -> URL { container }
  func makeConfigurationRepository() throws -> ConfigurationRepository { repository }
  func makePrivateAuthorizationStore() throws -> PersistenceStore { authorizations }
  func makeCollectionProcessingStore() throws -> CollectionProcessingStore { processing }
  /// Removes all test-owned resources after leases and operations finish.
  func cleanup() { try? FileManager.default.removeItem(at: container) }
}
