import AppKit
import FileSystem
import Foundation
import Common
import Persistence
import Testing

@testable import MovieFolderPosters

/// Exercises authorization and real processing using only disposable stores and folders.
struct MoviePosterActionServiceTests {
  /// Applying from an older presentation rereads saved rejections before provider or icon work.
  @Test func applyingRejectedMovieRequiresUndoEvenFromStaleWindow() async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let provider = ActionProvider()
    let staleWindow = fixture.service(movieMetadataProvider: provider)
    #expect(try await staleWindow.movieRejections(for: fixture.request).movies.isEmpty)
    let movie = MovieMetadata(id: 7, title: "Dune", originalTitle: "Dune", releaseYear: 2021,
      posterPath: "/chosen.png")
    let rejection = try FolderMovieRejection(movieID: 7, title: "Dune", year: 2021)
    try await fixture.service().rejectMovie(rejection, for: fixture.request)

    await #expect(throws: MoviePosterActionServiceError.movieRejected) {
      try await staleWindow.applyPoster(movie, for: fixture.request)
    }
    #expect(await provider.downloads.isEmpty)
    #expect(await provider.searches.isEmpty)
    #expect(MoviePosterActionServiceError.movieRejected.localizedDescription
      == "Undo this movie's rejection before applying it.")
    try await fixture.service().removeMovieRejection(movieID: 7, for: fixture.request)
    #expect(try await staleWindow.applyPoster(movie, for: fixture.request) == 7)
    #expect(await provider.downloads == ["/chosen.png"])
  }

  /// An injected persisted change during download prevents assignment; authorized host edits remain excluded.
  /// The direct store write models changed saved evidence, without claiming another host action can bypass admission.
  @Test func rejectionDuringArtworkDownloadPreventsAssignment() async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let original = try FileSystemService().readCurrentFolderCandidate(
      ofChild: fixture.request.childName, in: fixture.movies)
    let provider = RejectionDownloadProvider()
    let service = fixture.service(movieMetadataProvider: provider)
    let movie = MovieMetadata(id: 7, title: "Dune", originalTitle: "Dune", releaseYear: 2021,
      posterPath: "/chosen.png")
    let operation = Task { try await service.applyPoster(movie, for: fixture.request) }
    await provider.waitForDownload()
    let rejection = try FolderMovieRejection(movieID: 7, title: "Dune", year: 2021)
    await #expect(throws: ConfigurationError.busy) {
      try await fixture.service().rejectMovie(rejection, for: fixture.request)
    }
    let identity = try FileSystemService().verifiedFolderIdentity(
      at: fixture.movies.appendingPathComponent(fixture.request.childName), expectedIdentity: fixture.request.identity)
    let store = try fixture.makeFolderMovieRejectionStore()
    #expect(try store.rejections(for: identity, in: fixture.request.rootID).movies.isEmpty)
    try store.rejectMovie(rejection, for: identity, in: fixture.request.rootID)
    await provider.finishDownload()
    await #expect(throws: MoviePosterActionServiceError.movieRejected) { try await operation.value }
    #expect(try await service.matchedMovieID(for: fixture.request) == .none)
    #expect(try FileSystemService().readCurrentFolderCandidate(
      ofChild: fixture.request.childName, in: fixture.movies) == original)
  }

  /// Rejection reads, saves, and undo survive reopening without token or provider access.
  @Test func movieRejectionsSurviveReopeningWithoutAToken() async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let provider = ActionProvider()
    let writer = fixture.service(token: .none, movieMetadataProvider: provider)
    let reader = fixture.service(token: .none, movieMetadataProvider: provider)
    let movie = try FolderMovieRejection(movieID: 7, title: "Dune", year: 2021)
    let original = try FileSystemService().readCurrentFolderCandidate(
      ofChild: fixture.request.childName, in: fixture.movies)

    try await writer.rejectMovie(movie, for: fixture.request)
    let saved = try await reader.movieRejections(for: fixture.request)
    #expect(saved.movies == [movie])
    try await reader.removeMovieRejection(movieID: movie.movieID, for: fixture.request)
    #expect(try await writer.movieRejections(for: fixture.request).movies.isEmpty)
    #expect(await provider.searches.isEmpty)
    #expect(await provider.downloads.isEmpty)
    #expect(try fixture.processing.read(rootID: fixture.request.rootID) == .none)
    #expect(try FileSystemService().readCurrentFolderCandidate(
      ofChild: fixture.request.childName, in: fixture.movies) == original)
  }

  /// Rejections follow a renamed folder while a replacement rejects stale reads and edits.
  @Test func movieRejectionsVerifyFolderIdentityAcrossRenameAndReplacement() async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let service = fixture.service()
    let request = fixture.request
    let movie = try FolderMovieRejection(movieID: 7, title: "Dune", year: 2021)
    try await service.rejectMovie(movie, for: request)
    let original = fixture.movies.appendingPathComponent(request.childName)
    let moved = fixture.movies.appendingPathComponent("Renamed")
    try FileManager.default.moveItem(at: original, to: moved)
    try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)

    await #expect(throws: MoviePosterActionServiceError.childChanged) {
      try await service.movieRejections(for: request)
    }
    await #expect(throws: MoviePosterActionServiceError.childChanged) {
      try await service.rejectMovie(movie, for: request)
    }
    await #expect(throws: MoviePosterActionServiceError.childChanged) {
      try await service.removeMovieRejection(movieID: movie.movieID, for: request)
    }
    let replacement = try FileSystemService().readCurrentFolderCandidate(ofChild: request.childName, in: fixture.movies)
    let replacementRequest = MoviePosterRequest(rootID: request.rootID, childName: replacement.name,
      identity: replacement.identity, action: .change)
    let movedRequest = MoviePosterRequest(rootID: request.rootID, childName: moved.lastPathComponent,
      identity: request.identity, action: .change)
    #expect(try await service.movieRejections(for: replacementRequest).movies.isEmpty)
    #expect(try await service.movieRejections(for: movedRequest).movies == [movie])
  }

  /// A collection revoked during bookmark acquisition cannot expose or edit its rejection record.
  @Test func movieRejectionsRejectRevokedAuthorizationWithoutChangingStorage() async throws {
    let fixture = try PosterActionFixture(onBookmarkCreation: { repository in
      try repository.update { $0.directories.removeAll() }
    })
    defer { fixture.cleanup() }
    let fileSystem = FileSystemService()
    let identity = try fileSystem.verifiedFolderIdentity(
      at: fixture.movies.appendingPathComponent(fixture.request.childName), expectedIdentity: fixture.request.identity)
    let store = try fixture.makeFolderMovieRejectionStore()
    let movie = try FolderMovieRejection(movieID: 7, title: "Dune", year: 2021)
    try store.rejectMovie(movie, for: identity, in: fixture.request.rootID)
    let saved = try store.rejections(for: identity, in: fixture.request.rootID)
    let service = fixture.service()

    await #expect(throws: MoviePosterActionServiceError.configurationChanged) {
      try await service.removeMovieRejection(movieID: movie.movieID, for: fixture.request)
    }
    await #expect(throws: MoviePosterActionServiceError.directoryNotConfigured) {
      try await service.movieRejections(for: fixture.request)
    }
    await #expect(throws: MoviePosterActionServiceError.directoryNotConfigured) {
      try await service.rejectMovie(movie, for: fixture.request)
    }
    #expect(try store.rejections(for: identity, in: fixture.request.rootID) == saved)
  }

  /// Rejections remain explicitly editable for paused collections and excluded folders.
  @Test func movieRejectionsCanBeEditedWhileProcessingIsPausedOrExcluded() async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let request = fixture.request
    try fixture.repository.update {
      _ = $0.directories[0].processingConfiguration.setPaused(true)
      _ = $0.directories[0].processingConfiguration.excludeFolder(
        identity: request.identity, lastKnownName: request.childName)
    }
    let service = fixture.service()
    let movie = try FolderMovieRejection(movieID: 7, title: "Dune", year: 2021)
    try await service.rejectMovie(movie, for: request)
    #expect(try await service.movieRejections(for: request).movies == [movie])
    try await service.removeMovieRejection(movieID: movie.movieID, for: request)
    #expect(try await service.movieRejections(for: request).movies.isEmpty)
    let directory = try #require(try fixture.repository.read().directories.first)
    #expect(directory.isPaused)
    #expect(directory.excludesFolder(identity: request.identity))
  }

  /// Other action kinds cannot read, save, or undo a rejection.
  @Test(arguments: [MoviePosterAction.refresh, .remove, .view])
  func movieRejectionsRequireChooseMovie(action: MoviePosterAction) async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let request = MoviePosterRequest(rootID: fixture.request.rootID, childName: fixture.request.childName,
      identity: fixture.request.identity, action: action)
    let service = fixture.service()
    let movie = try FolderMovieRejection(movieID: 7, title: "Dune", year: 2021)

    await #expect(throws: MoviePosterActionServiceError.invalidAction) {
      try await service.movieRejections(for: request)
    }
    await #expect(throws: MoviePosterActionServiceError.invalidAction) {
      try await service.rejectMovie(movie, for: request)
    }
    await #expect(throws: MoviePosterActionServiceError.invalidAction) {
      try await service.removeMovieRejection(movieID: movie.movieID, for: request)
    }
  }

  /// Contention and cancellation preserve saved rejections and their revision.
  @Test func movieRejectionsPreserveDecisionsOnContentionAndCancellation() async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let service = fixture.service()
    let request = fixture.request
    let movie = try FolderMovieRejection(movieID: 7, title: "Dune", year: 2021)
    try await service.rejectMovie(movie, for: request)
    let saved = try await service.movieRejections(for: request)
    do {
      let directory = fixture.container.appendingPathComponent("FolderMovieRejections")
      let persistence = try PersistenceStore(directory: directory)
      let access = try #require(try persistence.acquireAccess(for: "folder-movie-rejections:\(request.rootID)"))
      defer { withExtendedLifetime(access) {} }
      await #expect(throws: FolderMovieRejectionStore.StoreError.busy) {
        try await service.movieRejections(for: request)
      }
      await #expect(throws: FolderMovieRejectionStore.StoreError.busy) {
        try await service.removeMovieRejection(movieID: movie.movieID, for: request)
      }
    }
    let cancelled = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      try await service.removeMovieRejection(movieID: movie.movieID, for: request)
    }
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    #expect(try await service.movieRejections(for: request) == saved)
  }

  /// Unavailable rejection storage reports an error and preserves the existing namespace entry.
  @Test func movieRejectionsPropagateStorageFailure() async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let namespace = fixture.container.appendingPathComponent("FolderMovieRejections")
    let marker = Data("Existing file".utf8)
    try marker.write(to: namespace)
    let service = fixture.service()
    let movie = try FolderMovieRejection(movieID: 7, title: "Dune", year: 2021)

    await #expect(throws: (any Error).self) { try await service.movieRejections(for: fixture.request) }
    await #expect(throws: (any Error).self) { try await service.rejectMovie(movie, for: fixture.request) }
    await #expect(throws: (any Error).self) {
      try await service.removeMovieRejection(movieID: movie.movieID, for: fixture.request)
    }
    #expect(try Data(contentsOf: namespace) == marker)
    #expect(try fixture.processing.read(rootID: fixture.request.rootID) == .none)
  }

  /// Saving corrected fields makes the real host retry service reassess a conclusive result.
  @Test func savedCorrectionMakesConclusiveHostResultRetryable() async throws {
    let fixture = try PosterActionFixture(childName: "Wrong Movie (2021)")
    defer { fixture.cleanup() }
    let configuration = try fixture.repository.read()
    let root = try #require(configuration.directories.first)
    let context = CollectionProcessingContext(rootID: root.id, rootIdentity: try #require(root.identity),
      authorizationVersion: root.authorizationVersion, credentialRevision: configuration.credentialRevision,
      usesStubTMDbResponses: false, appearance: configuration.posterAppearance,
      processingConfigurationRevision: root.processingConfiguration.revision)
    var state = try fixture.processing.recordProcessingStart(context: context, action: .automatic)
    state.folders = [FolderProcessingRecord(name: fixture.request.childName, identity: fixture.request.identity,
      state: .failed, reason: .connectivity)]
    state.isInventoryComplete = true
    state.inspectedAt = Date()
    state.currentRun?.runState = .partial
    _ = try fixture.processing.commit(state, expectedRevision: state.revision)
    let provider = ActionProvider()
    let service = fixture.service(movieMetadataProvider: provider)
    _ = try await service.retryFolder(for: fixture.request)
    let negative = try fixture.processing.read(rootID: root.id)?.folders.first
    #expect(negative?.processingState == .notFound)

    try await service.setSearchCorrection(FolderSearchCorrection(title: "Dune", year: 2021), for: fixture.request)
    let result = try await service.retryFolder(for: fixture.request)

    guard case .attempted(let summary, _) = result else { Issue.record("Expected corrected retry."); return }

    #expect(summary.assigned == 1)
    let saved = try fixture.processing.read(rootID: root.id)?.folders.first
    #expect(saved?.movieIdentitySource == .savedSearchCorrection)
    #expect(saved?.isVerifiedDone == true)
    #expect(await provider.searches == ["Wrong Movie:none", "Dune:none"])
  }

  /// A local correction can be saved, reopened, and cleared without TMDb access.
  @Test func searchCorrectionSurvivesReopeningWithoutAToken() async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let provider = ActionProvider()
    let writer = fixture.service(token: .none, movieMetadataProvider: provider)
    let reader = fixture.service(token: .none, movieMetadataProvider: provider)
    let correction = try FolderSearchCorrection(title: "Corrected title", year: 2021)
    let fileSystem = FileSystemService()
    let childBefore = try fileSystem.readCurrentFolderCandidate(ofChild: fixture.request.childName, in: fixture.movies)

    try await writer.setSearchCorrection(correction, for: fixture.request)
    #expect(try await reader.searchCorrection(for: fixture.request) == correction)

    try await reader.setSearchCorrection(.none, for: fixture.request)
    #expect(try await writer.searchCorrection(for: fixture.request) == .none)
    #expect(await provider.searches.isEmpty)
    #expect(await provider.downloads.isEmpty)
    #expect(try fixture.processing.read(rootID: fixture.request.rootID) == .none)
    #expect(try fileSystem.readCurrentFolderCandidate(
      ofChild: fixture.request.childName, in: fixture.movies).hasCustomIcon == childBefore.hasCustomIcon)
  }

  /// A replacement folder receives no correction and stale requests cannot change the original record.
  @Test func searchCorrectionRejectsAReplacedChild() async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let service = fixture.service()
    let request = fixture.request
    let original = fixture.movies.appendingPathComponent(request.childName)
    let moved = fixture.movies.appendingPathComponent("Renamed")
    let correction = try FolderSearchCorrection(title: "Corrected title", year: .none)
    try await service.setSearchCorrection(correction, for: request)
    try FileManager.default.moveItem(at: original, to: moved)
    try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)

    await #expect(throws: MoviePosterActionServiceError.childChanged) {
      try await service.searchCorrection(for: request)
    }
    await #expect(throws: MoviePosterActionServiceError.childChanged) {
      try await service.setSearchCorrection(correction, for: request)
    }
    await #expect(throws: MoviePosterActionServiceError.childChanged) {
      try await service.setSearchCorrection(.none, for: request)
    }
    let replacement = try FileSystemService().readCurrentFolderCandidate(ofChild: request.childName, in: fixture.movies)
    let replacementRequest = MoviePosterRequest(rootID: request.rootID, childName: replacement.name,
      identity: replacement.identity, action: .change)
    let movedRequest = MoviePosterRequest(rootID: request.rootID, childName: moved.lastPathComponent,
      identity: request.identity, action: .change)
    #expect(try await service.searchCorrection(for: replacementRequest) == .none)
    #expect(try await service.searchCorrection(for: movedRequest) == correction)
  }

  /// A collection removed during bookmark acquisition cannot receive a correction.
  @Test func searchCorrectionRejectsRevokedCollectionDuringAuthorization() async throws {
    let fixture = try PosterActionFixture(onBookmarkCreation: { repository in
      try repository.update { $0.directories.removeAll() }
    })
    defer { fixture.cleanup() }
    let service = fixture.service()
    let correction = try FolderSearchCorrection(title: "Corrected title", year: .none)

    await #expect(throws: MoviePosterActionServiceError.configurationChanged) {
      try await service.setSearchCorrection(correction, for: fixture.request)
    }
    await #expect(throws: MoviePosterActionServiceError.directoryNotConfigured) {
      try await service.searchCorrection(for: fixture.request)
    }
    let child = fixture.movies.appendingPathComponent(fixture.request.childName)
    let identity = try FileSystemService().verifiedFolderIdentity(at: child, expectedIdentity: fixture.request.identity)
    #expect(try fixture.makeFolderSearchCorrectionStore().correction(
      for: identity, in: fixture.request.rootID) == .none)
  }

  /// Pausing and excluding affect processing while leaving explicit local correction edits available.
  @Test func searchCorrectionCanBeEditedForAPausedAndExcludedFolder() async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let request = fixture.request
    try fixture.repository.update {
      _ = $0.directories[0].processingConfiguration.setPaused(true)
      _ = $0.directories[0].processingConfiguration.excludeFolder(
        identity: request.identity, lastKnownName: request.childName)
    }
    let service = fixture.service()
    let correction = try FolderSearchCorrection(title: "Corrected title", year: .none)

    try await service.setSearchCorrection(correction, for: request)
    #expect(try await service.searchCorrection(for: request) == correction)
    try await service.setSearchCorrection(.none, for: request)
    #expect(try await service.searchCorrection(for: request) == .none)
    let directory = try #require(try fixture.repository.read().directories.first)
    #expect(directory.isPaused)
    #expect(directory.excludesFolder(identity: request.identity))
  }

  /// Neither a busy store nor a cancelled action changes the previous correction.
  @Test func searchCorrectionPreservesTheRecordOnContentionAndCancellation() async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let service = fixture.service()
    let request = fixture.request
    let correction = try FolderSearchCorrection(title: "Corrected title", year: .none)
    try await service.setSearchCorrection(correction, for: request)

    do {
      let directory = fixture.container.appendingPathComponent("FolderSearchCorrections")
      let persistence = try PersistenceStore(directory: directory)
      let access = try #require(try persistence.acquireAccess(
        for: "folder-search-corrections:\(request.rootID.uuidString)"))
      defer { withExtendedLifetime(access) {} }
      await #expect(throws: FolderSearchCorrectionStore.StoreError.busy) {
        try await service.setSearchCorrection(.none, for: request)
      }
    }

    let cancelled = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      try await service.setSearchCorrection(.none, for: request)
    }
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    #expect(try await service.searchCorrection(for: request) == correction)
  }

  /// An unavailable correction namespace fails before changing the folder or its results.
  @Test func searchCorrectionPropagatesStorageFailure() async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let service = fixture.service()
    let correction = try FolderSearchCorrection(title: "Corrected title", year: .none)
    let storePath = fixture.container.appendingPathComponent("FolderSearchCorrections")
    let marker = Data("Existing file".utf8)
    try marker.write(to: storePath)

    await #expect(throws: (any Error).self) {
      try await service.setSearchCorrection(correction, for: fixture.request)
    }
    #expect(try Data(contentsOf: storePath) == marker)
    #expect(try fixture.processing.read(rootID: fixture.request.rootID) == .none)
  }

  /// Explicit movie search forwards the saved regional language through the authorized action service.
  @Test func movieSelectionSearchUsesSavedLanguage() async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let language = try MovieSearchLanguage("pt-BR")
    try fixture.repository.update { $0.movieMatchingConfiguration.searchLanguage = language }
    let provider = ActionProvider(changesDuringDownload: true)
    let result = try await fixture.service(movieMetadataProvider: provider).searchMovies(
      for: fixture.request, query: "Dune", year: 2021, language: language)

    #expect(result.movies.first?.title == "Dune")
    #expect(await provider.searchLanguages == ["pt-BR"])
  }

  /// Actual user-requested actions identify their authorized collection and immediate child folder.
  @Test func activityIdentifiesTheCollectionFolderAndMovie() async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let activityHistoryService = MovieFolderActivityServiceFake()
    let movie = MovieMetadata(id: 7, title: "Dune", originalTitle: "Dune", releaseYear: 2021,
      posterPath: "/chosen.png")
    _ = try await fixture.service(activity: activityHistoryService).applyPoster(movie, for: fixture.request)
    let recordedMessages = try await activityHistoryService.entries().map { $0.event.text }

    #expect(recordedMessages.contains { $0.contains("Movies") && $0.contains("Dune (2021)") })
    #expect(recordedMessages.contains { $0.contains("Confirmed movie: “Dune” (2021)") })
    #expect(try await activityHistoryService.entries().contains { $0.event.target?.movieID == 7 })
  }

  /// An action without verified collection capture must not retain correlation or collection identifiers.
  @Test func missingCollectionContextRecordsOnlyUnlinkedActivity() async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let activityHistoryService = MovieFolderActivityServiceFake()
    let request = MoviePosterRequest(rootID: UUID(), childName: fixture.request.childName,
      identity: fixture.request.identity, action: .refresh)
    await #expect(throws: MoviePosterActionServiceError.directoryNotConfigured) {
      try await fixture.service(activity: activityHistoryService).refreshPoster(for: request)
    }
    let events = try await activityHistoryService.entries().map(\.event)

    #expect(events.map(\.status) == [.started, .failed])
    #expect(events.allSatisfy { $0.target == .none && $0.collectionID == .none && $0.activityGroupID == .none })
  }

  /// Pausing collection inclusion still permits explicit owned-poster removal and retains suppression.
  @Test func pausedCollectionAllowsExplicitRemoval() async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let service = fixture.service()
    let movie = MovieMetadata(id: 7, title: "Dune", originalTitle: "Dune", releaseYear: 2021,
      posterPath: "/chosen.png")
    _ = try await service.applyPoster(movie, for: fixture.request)
    try fixture.repository.update { configuration in
      _ = configuration.directories[0].processingConfiguration.setPaused(true)
    }

    #expect(try await service.removePoster(for: fixture.request))
    #expect(try FileSystemService().isPosterSuppressed(toChild: fixture.request.childName, in: fixture.movies))
    #expect(try !FileSystemService().readCurrentFolderCandidate(ofChild: fixture.request.childName, in: fixture.movies)
      .hasCustomIcon)
  }

  /// Cancelling a noncooperative provider retains admission until its service call returns.
  @Test(.timeLimit(.minutes(1))) func cancelledSearchRetainsSharedAdmissionUntilItReturns() async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let movieMetadataProvider = SuspendedActionProvider()
    let service = fixture.service(movieMetadataProvider: movieMetadataProvider)
    let search = Task { try await service.searchMovies(for: fixture.request, query: "Dune", year: 2021) }
    await movieMetadataProvider.waitForSearch()
    search.cancel()
    await #expect(throws: PosterActionError.busy) { try await service.matchedMovieID(for: fixture.request) }
    await #expect(throws: PosterActionError.busy) { try await service.retryFolder(for: fixture.request) }
    await movieMetadataProvider.finishSearch()
    await #expect(throws: CancellationError.self) { try await search.value }
    #expect(try await service.matchedMovieID(for: fixture.request) == .none)
  }

  /// Explicit selection and selected retry retain unrelated evidence and update authoritative counts.
  /// - Parameter choosesMovie: Whether the user resolves a confirmed negative result by explicit selection.
  @Test(arguments: [false, true])
  func selectedActionsUpdateOnlyTheirRequestedFolder(choosesMovie: Bool) async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let configuration = try fixture.repository.read()
    let root = try #require(configuration.directories.first)
    let rootIdentity = try #require(root.identity)
    let context = CollectionProcessingContext(
      rootID: root.id, rootIdentity: rootIdentity, authorizationVersion: root.authorizationVersion,
      credentialRevision: configuration.credentialRevision,
      usesStubTMDbResponses: configuration.usesStubTMDbResponses, appearance: configuration.posterAppearance,
      processingConfigurationRevision: root.processingConfiguration.revision)
    let unrelated = FolderProcessingRecord(
      name: "Unrelated", identity: "untouched", state: .notFound, reason: .noSuitableMovie)
    var initial = try fixture.processing.recordProcessingStart(context: context, action: .automatic)
    initial.folders = [
      FolderProcessingRecord(name: fixture.request.childName, identity: fixture.request.identity,
        state: choosesMovie ? .notFound : .failed, reason: choosesMovie ? .noSuitableMovie : .connectivity),
      unrelated
    ]
    initial.isInventoryComplete = true
    initial.inspectedAt = Date()
    initial.currentRun?.runState = .partial
    _ = try fixture.processing.commit(initial, expectedRevision: initial.revision)
    let movieMetadataProvider = ActionProvider()
    let service = fixture.service(movieMetadataProvider: movieMetadataProvider)
    if choosesMovie {
      let movie = MovieMetadata(id: 7, title: "Dune", originalTitle: "Dune", releaseYear: 2021,
        posterPath: "/chosen.png")
      #expect(try await service.applyPoster(movie, for: fixture.request) == 7)
      #expect(await movieMetadataProvider.searches.isEmpty)
    } else {
      let result = try await service.retryFolder(for: fixture.request)
      guard case .attempted(let summary, let stopSelection) = result else {
        Issue.record("Eligible selected work must be attempted")
        return
      }
      #expect(summary.assigned == 1)
      #expect(!stopSelection)
    }
    let saved = try #require(try fixture.processing.read(rootID: root.id))
    #expect(saved.folders.first { $0.folderName == fixture.request.childName }?.isVerifiedDone == true)
    #expect(saved.folders.first { $0.folderName == unrelated.folderName } == unrelated)
    #expect(saved.calculateCounts().done == 1)
    #expect(saved.calculateCounts().notFound == 1)
    #expect(saved.calculateCounts().total == 2)
  }

  /// Candidate results cannot be returned for a child replaced while the search was suspended.
  @Test(.timeLimit(.minutes(1))) func searchRevalidatesChildAfterProviderReturns() async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let movieMetadataProvider = SuspendedActionProvider()
    let service = fixture.service(movieMetadataProvider: movieMetadataProvider)
    let search = Task { try await service.searchMovies(for: fixture.request, query: "Dune", year: 2021) }
    await movieMetadataProvider.waitForSearch()
    let child = fixture.movies.appendingPathComponent(fixture.request.childName)
    try FileManager.default.moveItem(at: child, to: fixture.movies.appendingPathComponent("Previous"))
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
    await movieMetadataProvider.finishSearch()
    await #expect(throws: MoviePosterActionServiceError.childChanged) { try await search.value }
  }

  /// A previously composed host service rechecks durable admission before direct manual searches.
  @Test func cachedManualServiceHonorsRecoveryModeAndExplicitResume() async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let movieMetadataProvider = ActionProvider()
    let service = fixture.service(movieMetadataProvider: movieMetadataProvider)
    let recovery = try fixture.makeProcessingRecoveryService()
    try recovery.setRecoveryModeEnabled(true)
    await #expect(throws: ProcessingRecoveryError.recoveryMode) {
      try await service.searchMovies(for: fixture.request, query: "Dune", year: .none)
    }
    #expect(await movieMetadataProvider.searches.isEmpty)
    await #expect(throws: ProcessingRecoveryError.recoveryMode) {
      try await service.removePoster(for: fixture.request)
    }
    try recovery.setRecoveryModeEnabled(false)
    #expect(await movieMetadataProvider.searches.isEmpty)
    _ = try await service.searchMovies(for: fixture.request, query: "Dune", year: .none)
    #expect(await movieMetadataProvider.searches == ["Dune:none"])
  }

  /// An authorized empty assignment must remain readable without an access token.
  @Test func readsUnassignedFolderWithoutAccessToken() async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let service = MoviePosterActionService(
      accessTokenStore: ActionAccessTokenStore(token: .none), activity: MovieFolderActivityServiceFake(),
      environment: fixture, networkHistory: NetworkHistoryPresentationFake())
    #expect(try await service.matchedMovieID(for: fixture.request) == .none)
  }

  /// Rejects malformed searches before configuration or access tokens can be consulted.
  @Test(arguments: ["", "  ", "Dune\nArrival", "Dune\rArrival"])
  func rejectsInvalidQuery(_ query: String) async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let service = fixture.service()
    await #expect(throws: MoviePosterActionServiceError.invalidQuery) {
      try await service.searchMovies(for: fixture.request, query: query, year: .none)
    }
  }

  /// Rejects unsupported years instead of silently broadening the user's search.
  @Test(arguments: [1887, 2100])
  func rejectsInvalidYear(_ year: Int) async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    await #expect(throws: MoviePosterActionServiceError.invalidQuery) {
      try await fixture.service().searchMovies(for: fixture.request, query: "Dune", year: year)
    }
  }

  /// Missing or replaced children and removed roots cannot authorize an old Finder request.
  @Test(arguments: ["removedRoot", "missingChild", "replacedIdentity", "wrongPath", "overlap"])
  func rejectsStaleFolderAuthorization(_ scenario: String) async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    var request = fixture.request
    let expected: MoviePosterActionServiceError
    switch scenario {
    case "removedRoot":
      try fixture.repository.update { $0.directories = [] }
      expected = .directoryNotConfigured
    case "missingChild":
      try FileManager.default.removeItem(at: fixture.movies.appendingPathComponent(request.childName))
      expected = .childChanged
    case "replacedIdentity":
      request = MoviePosterRequest(rootID: request.rootID, childName: request.childName,
        identity: "obsolete", action: .change)
      expected = .childChanged
    case "wrongPath":
      try fixture.repository.update { $0.directories[0].path += "/Elsewhere" }
      expected = .directoryUnavailable
    default:
      try fixture.repository.update { configuration in
        let existing = configuration.directories[0]
        let nested = MonitoredDirectory(id: UUID(), path: existing.path + "/Nested",
          transferBookmark: existing.transferBookmark, authorizationVersion: UUID(), identity: existing.identity)
        configuration.directories.append(nested)
      }
      expected = .directoryUnavailable
    }
    await #expect(throws: expected) { try await fixture.service().matchedMovieID(for: request) }
  }

  /// A concurrent authorization access denies entry rather than running without coordination.
  @Test func authorizationContentionPreventsRead() async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let directory = try #require(try fixture.repository.read().directories.first)
    let persistenceAccess = try #require(try fixture.authorizations.acquireAccess(
      for: "host-\(directory.id)-\(directory.authorizationVersion)"))
    await #expect { try await fixture.service().matchedMovieID(for: fixture.request) } throws: { error in
      if case ConfigurationError.busy = error { return true }

      return false
    }
    withExtendedLifetime(persistenceAccess) {}
  }

  /// access tokenStore remain mandatory even when the network provider is injected.
  @Test func missingAccessTokenPreventsSearch() async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let service = fixture.service(token: .none)
    await #expect(throws: MoviePosterActionServiceError.accessTokenUnavailable) {
      try await service.searchMovies(for: fixture.request, query: "Dune", year: .none)
    }
  }

  /// Injected providers cannot bypass validation of malformed nonempty access tokens.
  @Test func malformedAccessTokenPreventsProviderSearch() async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let movieMetadataProvider = ActionProvider()
    await #expect(throws: MovieMetadataError.self) {
      try await fixture.service(token: "invalid\ntoken", movieMetadataProvider: movieMetadataProvider).searchMovies(
        for: fixture.request, query: "Dune", year: .none)
    }
    #expect(await movieMetadataProvider.searches.isEmpty)
  }

  /// Selected IDs and artwork are validated before any authorization or change occurs.
  @Test(arguments: [Int.zero, -1, 7])
  func invalidSelectionRecordsFailure(_ identifier: Int) async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let activity = MovieFolderActivityServiceFake()
    let movie = MovieMetadata(id: identifier, title: "Dune", originalTitle: "Dune", releaseYear: 2021,
      posterPath: identifier == 7 ? "  " : "/poster.png")
    let service = fixture.service(activity: activity)
    await #expect(throws: MoviePosterActionServiceError.invalidSelection) {
      try await service.applyPoster(movie, for: fixture.request)
    }
    let events = try await activity.entries().map(\.event)
    #expect(events.map(\.status) == [.started, .failed])
    #expect(events.first?.activityGroupID == events.last?.activityGroupID)
    #expect(events.last?.failure?.reason == .invalidSelection)
    #expect(events.last?.text.contains("Dune (2021)") == true)
    #expect(try FileSystemService().readCurrentFolderCandidate(ofChild: fixture.request.childName, in: fixture.movies)
      .hasCustomIcon == false)
  }

  /// Selection persists the chosen identity, refresh retains it, and removal clears the owned icon.
  @Test func selectionRefreshAndRemovalUseRealProcessing() async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let movieMetadataProvider = ActionProvider()
    let activity = MovieFolderActivityServiceFake()
    let service = fixture.service(movieMetadataProvider: movieMetadataProvider, activity: activity)
    let movie = MovieMetadata(id: 7, title: "Dune", originalTitle: "Dune", releaseYear: 2021,
      posterPath: "/chosen.png")
    #expect(try await service.applyPoster(movie, for: fixture.request) == 7)
    #expect(try await service.matchedMovieID(for: fixture.request) == 7)
    #expect(try await service.refreshPoster(for: fixture.request) == 7)
    #expect(try await service.removePoster(for: fixture.request))
    #expect(try await service.removePoster(for: fixture.request) == false)
    #expect(try await service.matchedMovieID(for: fixture.request) == .none)
    #expect(await movieMetadataProvider.downloads == ["/chosen.png", "/chosen.png"])
    #expect(await movieMetadataProvider.searches.isEmpty)
    let folderResults = try await activity.entries().compactMap(\.event.folderResult)
    #expect(folderResults.contains(.posterApplied))
    #expect(folderResults.contains(.posterRemoved))
    #expect(folderResults.contains(.noPosterToRemove))
    #expect(try await activity.entries().map(\.event).filter { $0.folderResult == .none }.map(\.status) == [
      .started, .succeeded, .started, .succeeded, .started, .succeeded, .started, .succeeded
    ])
  }

  /// Search trims user input and preserves the provider's pagination result.
  @Test func authorizedSearchPreservesQueryAndResults() async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let movieMetadataProvider = ActionProvider()
    let result = try await fixture.service(movieMetadataProvider: movieMetadataProvider).searchMovies(
      for: fixture.request, query: "  Dune  ", year: 2021)
    #expect(result.movies.map(\.id) == [7])
    #expect(!result.hasMorePages)
    #expect(await movieMetadataProvider.searches == ["Dune:2021"])
  }

  /// Provider cancellation keeps a distinct cancelled event and leaves the folder untouched.
  @Test func cancelledRefreshRecordsCancellation() async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let activity = MovieFolderActivityServiceFake()
    let movieMetadataProvider = ActionProvider(cancels: true)
    await #expect(throws: CancellationError.self) {
      try await fixture.service(movieMetadataProvider: movieMetadataProvider, activity: activity)
        .refreshPoster(for: fixture.request)
    }
    #expect(try await activity.entries().map(\.event).filter { $0.folderResult == .none }.map(\.status)
      == [.started, .cancelled])
    #expect(try FileSystemService().readCurrentFolderCandidate(ofChild: fixture.request.childName, in: fixture.movies)
      .hasCustomIcon == false)
  }

}

extension MoviePosterActionServiceTests {
  /// R120-04: The actual host service resolves identifiers through its configuration and recovery fences.
  @Test(arguments: ["[tmdb:1]", "[imdb:tt0000001]", "[tmdb:1] [imdb:tt0000001]"])
  func hostServiceRetriesExplicitIdentifiers(labels: String) async throws {
    let fixture = try PosterActionFixture(childName: "Unrelated " + labels)
    defer { fixture.cleanup() }
    let configuration = try fixture.repository.read()
    let directory = try #require(configuration.directories.first)
    let context = CollectionProcessingContext(rootID: directory.id,
      rootIdentity: try #require(directory.identity), authorizationVersion: directory.authorizationVersion,
      credentialRevision: configuration.credentialRevision, usesStubTMDbResponses: false,
      appearance: configuration.posterAppearance,
      processingConfigurationRevision: directory.processingConfiguration.revision)
    var state = try fixture.processing.recordProcessingStart(context: context, action: .automatic)
    state.folders = [FolderProcessingRecord(name: fixture.request.childName, identity: fixture.request.identity,
      state: .failed, reason: .metadataFailure)]
    state.isInventoryComplete = true
    state.inspectedAt = Date()
    state.currentRun?.runState = .partial
    _ = try fixture.processing.commit(state, expectedRevision: state.revision)
    let image = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/TestPoster.png")
    let client = try NetworkClient(token: "fixture-token", fixturePosterData: Data(contentsOf: image))
    _ = try await fixture.service(movieMetadataProvider: client).retryFolder(for: fixture.request)
    let saved = try #require(try fixture.processing.read(rootID: directory.id))
    let outcome = try #require(saved.folders.first)
    #expect(outcome.matchedMovieID == 1)
    #expect(outcome.movieIdentitySource == .validatedIdentifier)
    #expect(outcome.isVerifiedDone)
  }

}

/// Supplies private, real persistence and directory identity for an action.
private struct PosterActionFixture: MoviePosterActionEnvironment {
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
  /// An optional configuration change during first-time bookmark recovery.
  private let onBookmarkCreation: (@Sendable (ConfigurationRepository) throws -> Void)?

  /// Creates real stores and a child folder whose identity can authorize the request.
  init(childName: String = "Dune (2021)",
       onBookmarkCreation: (@Sendable (ConfigurationRepository) throws -> Void)? = .none) throws {
    self.onBookmarkCreation = onBookmarkCreation
    container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    movies = container.appendingPathComponent("Movies")
    try FileManager.default.createDirectory(
      at: movies.appendingPathComponent(childName), withIntermediateDirectories: true)
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
    request = MoviePosterRequest(rootID: directory.id, childName: childName,
      identity: try fileSystem.readCurrentFolderCandidate(ofChild: childName, in: movies).identity, action: .change)
  }

  func makeDirectoryBookmark(for directory: URL) throws -> Data {
    try onBookmarkCreation?(repository)

    return try directory.bookmarkData(options: [], includingResourceValuesForKeys: .none, relativeTo: .none)
  }
  func appGroupContainerURL() throws -> URL { container }
  func makeConfigurationRepository() throws -> ConfigurationRepository { repository }
  func makePrivateAuthorizationStore() throws -> PersistenceStore { authorizations }
  func makeCollectionProcessingStore() throws -> CollectionProcessingStore { processing }
  /// Opens corrections in the same disposable container as the other test stores.
  func makeFolderSearchCorrectionStore() throws -> FolderSearchCorrectionStore {
    FolderSearchCorrectionStore(store: try PersistenceStore(
      directory: container.appendingPathComponent("FolderSearchCorrections")))
  }

  /// Opens rejection storage in the same disposable container as the other test stores.
  func makeFolderMovieRejectionStore() throws -> FolderMovieRejectionStore {
    FolderMovieRejectionStore(store: try PersistenceStore(
      directory: container.appendingPathComponent("FolderMovieRejections")))
  }
  /// Supplies nonisolated test implementations instead of inheriting the app module's actor-isolated defaults.
  func makePersistenceStore(directory: URL, maximumRecordBytes: Int?) throws -> PersistenceStore {
    try PersistenceStore(directory: directory, maximumRecordBytes: maximumRecordBytes)
  }
  func makeProcessingRecoveryService() throws -> ProcessingRecoveryService {
    ProcessingRecoveryService(store: try makePersistenceStore(
      directory: container.appendingPathComponent("ProcessingRecovery"), maximumRecordBytes: 8_192))
  }
  /// Composes the real action service without external storage, access tokens, or networking.
  func service(token: String? = "fixture-token", movieMetadataProvider: (any MovieMetadataProvider)? = .none,
               activity: (any MovieFolderActivityServicing)? = .none) -> MoviePosterActionService {
    MoviePosterActionService(accessTokenStore: ActionAccessTokenStore(token: token), activity:
      activity ?? MovieFolderActivityServiceFake(),
      environment: self, movieMetadataProvider: movieMetadataProvider ?? ActionProvider(),
      networkHistory: NetworkHistoryPresentationFake())
  }

  /// Removes all test-owned resources after leases and operations finish.
  func cleanup() { try? FileManager.default.removeItem(at: container) }
}

/// Replaces only the external access token lookup.
private struct ActionAccessTokenStore: ProviderAccessTokenStoring {
  /// Optional synthetic token.
  let token: String?
  func read() throws -> String? { token }
  func save(_ value: String) throws {}
  func remove() throws {}
}

/// Supplies controlled external responses while all authorization and processing remain real.
private actor ActionProvider: MovieMetadataProvider {
  /// Provider calls recorded to distinguish a saved selection from an automatic search.
  private(set) var searches: [String] = []
  /// Regional search language recorded at the actual metadata provider boundary.
  private(set) var searchLanguages: [String] = []
  /// Downloaded poster paths establish whether refresh used the saved movie.
  private(set) var downloads: [String] = []
  /// Optional real configuration change during the asynchronous network boundary.
  let repository: ConfigurationRepository?
  /// Whether configuration changes at the later artwork boundary instead of during search.
  let changesDuringDownload: Bool
  /// Whether metadata retrieval reports cancellation.
  let cancels: Bool

  /// Creates deterministic metadata with optional configuration invalidation or cancellation.
  init(repository: ConfigurationRepository? = .none, cancels: Bool = false, changesDuringDownload: Bool = false) {
    self.repository = repository
    self.cancels = cancels
    self.changesDuringDownload = changesDuringDownload
  }

  /// Supplies completed empty alternative-title evidence for this focused fixture.
  /// Supplies completed release events for this provider.
  func releaseDates(movieID: Int) throws -> MovieReleaseDatesByID { [movieID: []] }
  func alternativeTitles(movieID: Int) throws -> MovieAlternativeTitlesByID { [movieID: []] }

  func searchMoviePage(title: String, year: Int?, language: MovieSearchLanguage, page: Int) throws
    -> MovieSearchPage {
    guard page == 1 else { throw MovieMetadataError.invalidQuery }

    let result = try testSearchData(title: title, year: year, language: language)

    return MovieSearchPage(movies: result.movies, page: 1, totalPages: result.hasMorePages ? 6 : 1)
  }

  /// Supplies the existing first-page fixture independently of pagination transport.
  func testSearchData(title: String, year: Int?, language: MovieSearchLanguage = .english) throws -> MovieSearchResult {
    searches.append("\(title):\(year.map(String.init) ?? "none")")
    searchLanguages.append(language.rawValue)
    if cancels { throw CancellationError() }
    if !changesDuringDownload { try repository?.update { $0.credentialRevision = UUID() } }

    return MovieSearchResult(movies: [MovieMetadata(id: 7, title: "Dune", originalTitle: "Dune",
      releaseYear: 2021, posterPath: "/chosen.png")], hasMorePages: false)
  }

  func downloadPoster(path: String) throws -> Data {
    downloads.append(path)
    if changesDuringDownload { try repository?.update { $0.credentialRevision = UUID() } }
    let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/TestPoster.png")

    return try Data(contentsOf: resources)
  }
}

/// Holds a real service search at its provider boundary without depending on clock delays.
private actor SuspendedActionProvider: MovieMetadataProvider {
  /// Whether the service reached the search boundary.
  private var hasStarted = false
  /// Waiter notified when search begins.
  private var startedWaiter: CheckedContinuation<Void, Never>?
  /// Provider response retained until the test explicitly permits it.
  private var responseWaiter: CheckedContinuation<MovieSearchResult, Never>?

  /// Waits for search entry so cancellation and replacement occur during real suspended work.
  func waitForSearch() async {
    guard !hasStarted else { return }
    await withCheckedContinuation { startedWaiter = $0 }
  }

  /// Releases an empty completed search without manufacturing a matched movie.
  func finishSearch() {
    responseWaiter?.resume(returning: MovieSearchResult(movies: [], hasMorePages: false))
    responseWaiter = .none
  }

  /// Supplies completed empty alternative-title evidence for this focused fixture.
  /// Supplies completed release events for this provider.
  func releaseDates(movieID: Int) throws -> MovieReleaseDatesByID { [movieID: []] }
  func alternativeTitles(movieID: Int) throws -> MovieAlternativeTitlesByID { [movieID: []] }

  func searchMoviePage(title: String, year: Int?, language: MovieSearchLanguage, page: Int) async throws
    -> MovieSearchPage {
    guard page == 1 else { throw MovieMetadataError.invalidQuery }

    let result = await testSearchData(title: title, year: year, language: language)

    return MovieSearchPage(movies: result.movies, page: 1, totalPages: result.hasMorePages ? 6 : 1)
  }

  /// Supplies the existing first-page fixture independently of pagination transport.
  func testSearchData(title: String, year: Int?, language: MovieSearchLanguage = .english) async -> MovieSearchResult {
    hasStarted = true
    startedWaiter?.resume()
    startedWaiter = .none

    return await withCheckedContinuation { responseWaiter = $0 }
  }

  func downloadPoster(path: String) throws -> Data { throw MovieMetadataError.invalidPosterPath }
}

/// Covers stale provider results across search and artwork suspension points.
struct MoviePosterActionServiceConfigurationTests {
  /// A configuration revision changed during provider suspension invalidates its result.
  @Test func configurationChangeDuringSearchRejectsResults() async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let movieMetadataProvider = ActionProvider(repository: fixture.repository)
    await #expect {
      try await fixture.service(movieMetadataProvider: movieMetadataProvider).searchMovies(
        for: fixture.request, query: "Dune", year: .none)
    } throws: { error in
      if case ConfigurationError.configurationChanged = error { return true }

      return false
    }
  }

  /// A budget change during a suspended provider request invalidates its result without extending that search.
  @Test func pageLimitChangeDuringSearchRejectsResults() async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let provider = SuspendedActionProvider()
    let service = fixture.service(movieMetadataProvider: provider)
    let search = Task { try await service.searchMovies(for: fixture.request, query: "Dune", year: 2021) }
    await provider.waitForSearch()
    try fixture.repository.update { $0.searchPageLimit = 5 }
    await provider.finishSearch()
    await #expect(throws: ConfigurationError.configurationChanged) { try await search.value }
    #expect(try FileSystemService().readCurrentFolderCandidate(ofChild: fixture.request.childName, in: fixture.movies)
      .hasCustomIcon == false)
  }

  /// A configuration change during poster download must stop the final change guard.
  @Test func configurationChangeDuringArtworkPreventsChange() async throws {
    let fixture = try PosterActionFixture()
    defer { fixture.cleanup() }
    let movieMetadataProvider = ActionProvider(repository: fixture.repository, changesDuringDownload: true)
    let activity = MovieFolderActivityServiceFake()
    let movie = MovieMetadata(id: 7, title: "Dune", originalTitle: "Dune", releaseYear: 2021,
      posterPath: "/chosen.png")
    do {
      _ = try await fixture.service(movieMetadataProvider: movieMetadataProvider, activity: activity)
        .applyPoster(movie, for: fixture.request)
      Issue.record("Artwork from an obsolete configuration must not mutate the folder")
    } catch ConfigurationError.configurationChanged {}
    #expect(try FileSystemService().readCurrentFolderCandidate(ofChild: fixture.request.childName, in: fixture.movies)
      .hasCustomIcon == false)
    #expect(try await activity.entries().map(\.event).filter { $0.folderResult == .none }.map(\.status)
      == [.started, .failed])
  }

}

/// Holds artwork delivery so another authorized service can commit a rejection before icon mutation.
private actor RejectionDownloadProvider: MovieMetadataProvider {
  /// Whether the apply request has entered the download boundary.
  private var hasStarted = false
  /// Test waiting for download entry.
  private var startWaiter: CheckedContinuation<Void, Never>?
  /// The suspended download resumed after the rejection commits.
  private var downloadWaiter: CheckedContinuation<Void, Never>?

  /// Waits for the actual provider boundary without relying on timing.
  func waitForDownload() async {
    if hasStarted { return }
    await withCheckedContinuation { startWaiter = $0 }
  }

  /// Releases the suspended artwork after the test writes the rejection.
  func finishDownload() {
    downloadWaiter?.resume()
    downloadWaiter = .none
  }

  func downloadPoster(path: String) async throws -> Data {
    hasStarted = true
    startWaiter?.resume()
    startWaiter = .none
    await withCheckedContinuation { downloadWaiter = $0 }
    let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/TestPoster.png")

    return try Data(contentsOf: resources)
  }

  func searchMoviePage(title: String, year: Int?, language: MovieSearchLanguage, page: Int) throws -> MovieSearchPage {
    throw MovieMetadataError.invalidQuery
  }

  func alternativeTitles(movieID: Int) -> MovieAlternativeTitlesByID { [movieID: []] }
  func releaseDates(movieID: Int) -> MovieReleaseDatesByID { [movieID: []] }
}
