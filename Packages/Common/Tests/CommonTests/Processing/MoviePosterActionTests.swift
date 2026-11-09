import Darwin
import FileSystem
import Foundation
import Persistence
import Testing

@testable import Common

/// Regression coverage for explicit poster actions and live authorization checks.
struct MoviePosterActionTests {
  /// Verifies new Overlap During Search Prevents Manual Poster Change.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func newOverlapDuringSearchPreventsManualPosterChange() async throws {
    let fixture = try ActionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try fixture.addFolder("Dune (2021)")
    let repository = ConfigurationRepository(
      store: try PersistenceStore(
        directory: fixture.base.appendingPathComponent("configuration")))
    let target = MonitoredDirectory(
      id: UUID(), path: fixture.movies.path, transferBookmark: Data([1]),
      authorizationVersion: UUID(), identity: "target")
    let other = MonitoredDirectory(
      id: UUID(), path: fixture.base.appendingPathComponent("Other").path,
      transferBookmark: Data([2]), authorizationVersion: UUID(), identity: "other")
    try repository.update { $0.directories = [target, other] }
    let before = try repository.read()
    let provider = ActionProvider(posterData: fixture.posterData, delaysSearch: true)
    let processor = fixture.processor(
      provider: provider,
      processingVerifier: ConfigurationIconChangeVerifier(
        repository: repository, directory: target,
        configuration: before))
    let identity = try fixture.identity(of: "Dune (2021)")
    let task = Task {
      try await processor.refreshPoster(root: fixture.movies, child: "Dune (2021)", expectedIdentity: identity)
    }
    await provider.waitForSearch()
    try repository.update { $0.directories[1].path = fixture.movies.appendingPathComponent("Nested").path }
    await provider.allowSearch()
    do {
      _ = try await task.value
      Issue.record("A newly overlapping root must prevent change after network suspension")
    } catch ConfigurationError.configurationChanged {}
    #expect(!(try FileSystemService().readCurrentFolderCandidate(
      ofChild: "Dune (2021)", in: fixture.movies).hasCustomIcon))
  }

  /// Verifies selecting Explicit Movie Bypasses Ambiguous Search And Records Selection.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func selectingExplicitMovieBypassesAmbiguousSearchAndRecordsSelection() async throws {
    let fixture = try ActionFixture()
    try fixture.addFolder("Dune (2021)")
    let provider = ActionProvider(posterData: fixture.posterData)
    let processor = fixture.processor(provider: provider)
    let identity = try fixture.identity(of: "Dune (2021)")
    let selected = MovieMetadata(
      id: 7, title: "Dune", originalTitle: "Dune",
      releaseYear: 2021, posterPath: "/chosen.jpg")

    let movieID = try await processor.applyMoviePoster(
      selected, root: fixture.movies, child: "Dune (2021)", expectedIdentity: identity
    )

    let storedID = try await processor.matchedMovieID(
      root: fixture.movies, child: "Dune (2021)", expectedIdentity: identity
    )
    let searchCount = await provider.searchCount
    let posterPaths = await provider.posterPaths
    #expect(movieID == 7)
    #expect(storedID == 7)
    #expect(searchCount == 0)
    #expect(posterPaths == ["/chosen.jpg"])
  }

  /// Verifies refresh Downloads Again Using Saved Movie Without Searching.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func refreshDownloadsAgainUsingSavedMovieWithoutSearching() async throws {
    let fixture = try ActionFixture()
    try fixture.addFolder("Dune (2021)")
    let provider = ActionProvider(posterData: fixture.posterData)
    let processor = fixture.processor(provider: provider)
    let identity = try fixture.identity(of: "Dune (2021)")
    let selected = MovieMetadata(
      id: 7, title: "Dune", originalTitle: "Dune",
      releaseYear: 2021, posterPath: "/chosen.jpg")
    _ = try await processor.applyMoviePoster(
      selected, root: fixture.movies, child: "Dune (2021)", expectedIdentity: identity
    )

    let movieID = try await processor.refreshPoster(
      root: fixture.movies, child: "Dune (2021)", expectedIdentity: identity
    )

    let searchCount = await provider.searchCount
    let posterPaths = await provider.posterPaths
    #expect(movieID == 7)
    #expect(searchCount == 0)
    #expect(posterPaths == ["/chosen.jpg", "/chosen.jpg"])
  }

  /// Verifies remove Suppresses Automatic Recreation.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func removeSuppressesAutomaticRecreation() async throws {
    let fixture = try ActionFixture()
    try fixture.addFolder("Dune (2021)")
    let provider = ActionProvider(posterData: fixture.posterData)
    let processor = fixture.processor(provider: provider)
    let identity = try fixture.identity(of: "Dune (2021)")
    let selected = MovieMetadata(
      id: 7, title: "Dune", originalTitle: "Dune",
      releaseYear: 2021, posterPath: "/chosen.jpg")
    _ = try await processor.applyMoviePoster(
      selected, root: fixture.movies, child: "Dune (2021)", expectedIdentity: identity
    )

    let removed = try await processor.removePoster(
      root: fixture.movies, child: "Dune (2021)", expectedIdentity: identity
    )
    let summary = try await processor.process(root: fixture.movies)

    let searchCount = await provider.searchCount
    let posterPaths = await provider.posterPaths
    #expect(removed)
    #expect(summary.examined == 0)
    #expect(searchCount == 0)
    #expect(posterPaths == ["/chosen.jpg"])
  }

  /// Verifies refresh Does Not Require An Existing Custom Icon.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func refreshDoesNotRequireAnExistingCustomIcon() async throws {
    let fixture = try ActionFixture()
    try fixture.addFolder("Dune (2021)")
    let provider = ActionProvider(posterData: fixture.posterData)
    let processor = fixture.processor(provider: provider)
    let identity = try fixture.identity(of: "Dune (2021)")

    let movieID = try await processor.refreshPoster(
      root: fixture.movies, child: "Dune (2021)", expectedIdentity: identity
    )

    let posterPaths = await provider.posterPaths
    #expect(movieID == 42)
    #expect(posterPaths == ["/dune.jpg"])
  }

  /// Verifies selection Rejects Foreign Icon Before Downloading Poster.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func selectionRejectsForeignIconBeforeDownloadingPoster() async throws {
    let fixture = try ActionFixture()
    try fixture.addFolder("Dune (2021)")
    try fixture.markCustomIcon("Dune (2021)")
    let provider = ActionProvider(posterData: fixture.posterData)
    let processor = fixture.processor(provider: provider)
    let identity = try fixture.identity(of: "Dune (2021)")
    let selected = MovieMetadata(
      id: 7, title: "Dune", originalTitle: "Dune",
      releaseYear: 2021, posterPath: "/chosen.jpg")

    do {
      _ = try await processor.applyMoviePoster(
        selected, root: fixture.movies, child: "Dune (2021)", expectedIdentity: identity
      )
      Issue.record("A foreign custom icon must be preserved")
    } catch {
      #expect(error as? PosterActionError == .foreignIcon)
    }
    let posterPaths = await provider.posterPaths
    #expect(posterPaths.isEmpty)
  }

  /// Verifies action Rejects Changed Identity Before Provider Request.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func actionRejectsChangedIdentityBeforeProviderRequest() async throws {
    let fixture = try ActionFixture()
    try fixture.addFolder("Dune (2021)")
    let provider = ActionProvider(posterData: fixture.posterData)
    let processor = fixture.processor(provider: provider)
    let selected = MovieMetadata(
      id: 7, title: "Dune", originalTitle: "Dune",
      releaseYear: 2021, posterPath: "/chosen.jpg")

    do {
      _ = try await processor.applyMoviePoster(
        selected, root: fixture.movies, child: "Dune (2021)", expectedIdentity: "stale"
      )
      Issue.record("A stale folder identity must be rejected")
    } catch {
      #expect(error as? PosterActionError == .changedIdentity)
    }
    let posterPaths = await provider.posterPaths
    #expect(posterPaths.isEmpty)
  }

  /// Verifies action Uses The Same Root Access As Automatic Processing.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func actionUsesTheSameRootAccessAsAutomaticProcessing() async throws {
    let fixture = try ActionFixture()
    try fixture.addFolder("Dune (2021)")
    let canonicalPath = fixture.movies.resolvingSymlinksInPath().standardizedFileURL.path
    let access = try #require(try fixture.persistence.acquireAccess(
        for: "movie-folder-processing:\(canonicalPath)"
      ))
    let provider = ActionProvider(posterData: fixture.posterData)
    let processor = fixture.processor(provider: provider)
    let identity = try fixture.identity(of: "Dune (2021)")

    do {
      _ = try await processor.refreshPoster(
        root: fixture.movies, child: "Dune (2021)", expectedIdentity: identity
      )
      Issue.record("A manual action must not overlap processing for the same root")
    } catch {
      #expect(error as? PosterActionError == .busy)
    }
    withExtendedLifetime(access) {}
  }

  /// Verifies refresh Repeats Search Instead Of Reusing An Ambiguous Cached Query.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func refreshRepeatsSearchInsteadOfReusingAnAmbiguousCachedQuery() async throws {
    let fixture = try ActionFixture()
    try fixture.addFolder("Dune (2021)")
    let ambiguous = MovieSearchResult(
      movies: [
        MovieMetadata(
          id: 1, title: "Dune", originalTitle: "Dune", releaseYear: 2021,
          posterPath: "/one.jpg"),
        MovieMetadata(
          id: 2, title: "Dune", originalTitle: "Dune", releaseYear: 2021,
          posterPath: "/two.jpg")
      ], hasMorePages: false)
    let provider = ActionProvider(posterData: fixture.posterData, searchResult: ambiguous)
    let processor = fixture.processor(provider: provider)
    _ = try await processor.process(root: fixture.movies)
    await provider.setSearchResult(
      MovieSearchResult(
        movies: [
          MovieMetadata(
            id: 51, title: "Dune", originalTitle: "Dune", releaseYear: 2021,
            posterPath: "/resolved.jpg")
        ], hasMorePages: false))
    let identity = try fixture.identity(of: "Dune (2021)")

    let movieID = try await processor.refreshPoster(
      root: fixture.movies, child: "Dune (2021)", expectedIdentity: identity
    )

    let searchCount = await provider.searchCount
    let posterPaths = await provider.posterPaths
    #expect(movieID == 51)
    #expect(searchCount == 2)
    #expect(posterPaths == ["/resolved.jpg"])
  }

  /// Verifies corrupt State Prevents Selection Before Icon Change.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func corruptStatePreventsSelectionBeforeIconChange() async throws {
    let fixture = try ActionFixture()
    try fixture.addFolder("Dune (2021)")
    let identity = try fixture.identity(of: "Dune (2021)")
    try fixture.writeRawState(Data("invalid-json".utf8))
    let provider = ActionProvider(posterData: fixture.posterData)
    let processor = fixture.processor(provider: provider)
    let selected = MovieMetadata(
      id: 7, title: "Dune", originalTitle: "Dune",
      releaseYear: 2021, posterPath: "/chosen.jpg")

    do {
      _ = try await processor.applyMoviePoster(
        selected, root: fixture.movies, child: "Dune (2021)", expectedIdentity: identity
      )
      Issue.record("Corrupt processing state must fail before assigning an icon")
    } catch {
      #expect(!(try FileSystemService().readCurrentFolderCandidate(ofChild: "Dune (2021)", in: fixture.movies)
          .hasCustomIcon))
    }
    let posterPaths = await provider.posterPaths
    #expect(posterPaths.isEmpty)
  }

  /// Verifies selection Rejects Nonpositive Movie IDWithout Downloading Poster.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func selectionRejectsNonpositiveMovieIDWithoutDownloadingPoster() async throws {
    let fixture = try ActionFixture()
    try fixture.addFolder("Dune (2021)")
    let provider = ActionProvider(posterData: fixture.posterData)
    let processor = fixture.processor(provider: provider)
    let identity = try fixture.identity(of: "Dune (2021)")
    let selected = MovieMetadata(
      id: 0, title: "Dune", originalTitle: "Dune",
      releaseYear: 2021, posterPath: "/chosen.jpg")

    do {
      _ = try await processor.applyMoviePoster(
        selected, root: fixture.movies, child: "Dune (2021)", expectedIdentity: identity
      )
      Issue.record("An invalid movie ID must be rejected")
    } catch {
      #expect(error as? PosterActionError == .unresolved)
    }
    let posterPaths = await provider.posterPaths
    #expect(posterPaths.isEmpty)
  }

}

/// Manual recovery and coordination regression scenarios.
extension MoviePosterActionTests {
  /// Manual selection shares provider throttling and cannot authorize unrelated work before its retry boundary.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func manualSelectionHonorsSharedBackoffBeforeResumingEligibleFolders() async throws {
    let fixture = try ActionFixture()
    try fixture.addFolder("Arrival (2016)")
    try fixture.addFolder("Dune (2021)")
    let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
    let recovery = ProcessingRecoveryService(
      store: try PersistenceStore(directory: fixture.base.appendingPathComponent("Recovery")), now: { clock.now })
    let provider = ActionProvider(posterData: fixture.posterData, searchError: .rateLimited(retryAfter: "600"))
    let processor = MovieFolderProcessor(
      persistence: fixture.persistence,
      provider: RecoveryAwareMovieMetadataProvider(
        provider: ActionProviderAdapter(provider: provider), recovery: recovery, accessToken: "token"),
      cacheDirectory: fixture.base.appendingPathComponent("cache"), now: { clock.now }, recovery: recovery)
    let first = try await processor.process(root: fixture.movies)
    #expect(first.providerRetryAt != nil)
    await provider.setSearchError(.none)
    let identity = try fixture.identity(of: "Dune (2021)")
    let selected = MovieMetadata(
      id: 7, title: "Dune", originalTitle: "Dune",
      releaseYear: 2021, posterPath: "/chosen.jpg")

    do {
      _ = try await processor.applyMoviePoster(
        selected, root: fixture.movies, child: "Dune (2021)", expectedIdentity: identity)
      Issue.record("Manual selection must honor shared provider throttling")
    } catch let error as ProcessingRecoveryError {
      #expect(error == .providerBackoff(until: clock.now.addingTimeInterval(600), reason: .rateLimited))
    }
    let blockedDownloads = await provider.posterPaths
    #expect(blockedDownloads.isEmpty)
    clock.advance(by: 601)
    _ = try await processor.applyMoviePoster(
      selected, root: fixture.movies, child: "Dune (2021)", expectedIdentity: identity
    )
    let next = try await processor.process(root: fixture.movies)

    let searchCount = await provider.searchCount
    #expect(next.providerRetryAt == nil)
    #expect(searchCount == 2)
  }

  /// Verifies manual Change Gate Can Refuse After Download Without Changing Icon Or Record.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func manualChangeGateCanRefuseAfterDownloadWithoutChangingIconOrRecord() async throws {
    let fixture = try ActionFixture()
    try fixture.addFolder("Dune (2021)")
    let identity = try fixture.identity(of: "Dune (2021)")
    let provider = ActionProvider(posterData: fixture.posterData)
    let processor = fixture.processor(provider: provider, processingVerifier: RefusingIconChangeVerifier())
    let selected = MovieMetadata(
      id: 7, title: "Dune", originalTitle: "Dune",
      releaseYear: 2021, posterPath: "/chosen.jpg")

    do {
      _ = try await processor.applyMoviePoster(
        selected, root: fixture.movies, child: "Dune (2021)", expectedIdentity: identity
      )
      Issue.record("A refused settings gate must stop the icon change")
    } catch {
      #expect(error as? PosterActionError == .busy)
    }

    let storedID = try await processor.matchedMovieID(
      root: fixture.movies, child: "Dune (2021)", expectedIdentity: identity
    )
    let hasCustomIcon = try FileSystemService().readCurrentFolderCandidate(ofChild: "Dune (2021)", in: fixture.movies)
      .hasCustomIcon
    let posterPaths = await provider.posterPaths
    #expect(storedID == nil)
    #expect(!(hasCustomIcon))
    #expect(posterPaths == ["/chosen.jpg"])
  }

  /// Verifies stable Coordination Access Serializes Different State Stores.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func stableCoordinationAccessSerializesDifferentStateStores() async throws {
    let fixture = try ActionFixture()
    try fixture.addFolder("Dune (2021)")
    let stableStore = try PersistenceStore(directory: fixture.base.appendingPathComponent("coordination"))
    let secondStateStore = try PersistenceStore(directory: fixture.base.appendingPathComponent("second-state"))
    let firstProvider = ActionProvider(posterData: fixture.posterData, delaysSearch: true)
    let secondProvider = ActionProvider(posterData: fixture.posterData)
    let first = fixture.processor(provider: firstProvider, processingLockStore: stableStore)
    let second = MovieFolderProcessor(
      persistence: secondStateStore, provider: ActionProviderAdapter(provider: secondProvider),
      cacheDirectory: fixture.base.appendingPathComponent("second-cache"),
      processingLockStore: stableStore
    )

    let firstTask = Task { try await first.process(root: fixture.movies) }
    await firstProvider.waitForSearch()
    let secondResult = try await second.process(root: fixture.movies)
    await firstProvider.allowSearch()
    _ = try await firstTask.value

    #expect(secondResult.rootAccessUnavailable)
    let secondSearchCount = await secondProvider.searchCount
    #expect(secondSearchCount == 0)
  }
}
