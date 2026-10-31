import FileSystem
import Foundation
import Network
import Persistence
import Testing

@testable import MovieFolderCommon

/// Verifies inclusion admission before provider work and identity-based exclusion after renaming.
struct CollectionInclusionProcessingTests {
  /// Rejected manual admission cannot clear an existing authoritative exclusion or start an operation.
  @Test(arguments: [false, true])
  func rejectedExcludedManualActionPreservesOutcome(refresh: Bool) async throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try fixture.addFolder("Dune (2021)")
    let candidate = try #require(try FileSystemService().candidates(in: fixture.movies).first)
    let configuration = CollectionProcessingConfiguration(excludedFolders: [
      ExcludedMovieFolder(identity: candidate.identity, lastKnownName: candidate.name)
    ])
    let root = MonitoredDirectory(id: UUID(), path: fixture.movies.path, transferBookmark: Data([1]),
      authorizationVersion: UUID(), identity: try FileSystemService().persistentDirectoryIdentity(at: fixture.movies),
      processingConfiguration: configuration)
    let repository = ConfigurationRepository(store: try PersistenceStore(
      directory: fixture.base.appendingPathComponent("Settings")))
    try repository.update { $0.directories = [root] }
    let saved = try repository.read()
    let context = CollectionProcessingContext(
      rootID: root.id, rootIdentity: try #require(root.identity), authorizationVersion: root.authorizationVersion,
      credentialRevision: saved.credentialRevision, usesStubTMDbResponses: false, appearance: saved.posterAppearance,
      processingConfigurationRevision: configuration.revision)
    let store = CollectionProcessingStore(store: try PersistenceStore(
      directory: fixture.base.appendingPathComponent("Outcomes")), configuration: repository)
    let provider = CountingProvider()
    let processor = MovieFolderProcessor(
      persistence: fixture.persistence, provider: provider, cacheDirectory: fixture.cache,
      posterAssigner: fixture.assigner, processingStore: store, processingConfiguration: configuration)
    _ = try await processor.process(root: fixture.movies, processingContext: context)
    let before = try #require(try store.read(rootID: root.id))
    #expect(before.folders.first?.processingState == .excluded)

    await #expect(throws: CollectionProcessingError.configurationChanged) {
      if refresh {
        return try await processor.refreshPoster(root: fixture.movies, child: candidate.name,
          expectedIdentity: candidate.identity, processingContext: context)
      }
      let movie = MovieMetadata(id: 7, title: "Dune", originalTitle: "Dune", releaseYear: 2021,
        posterPath: "/dune.jpg")

      return try await processor.applyMoviePoster(movie, root: fixture.movies, child: candidate.name,
        expectedIdentity: candidate.identity, processingContext: context)
    }
    #expect(try store.read(rootID: root.id) == before)
    #expect(await provider.searchCount == .zero)
    #expect(await provider.posterCount == .zero)
  }

  /// A paused collection rejects both automatic visits and explicit assignment before provider disclosure.
  @Test func pausedCollectionDoesNotContactProvider() async throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try fixture.addFolder("Dune (2021)")
    let candidate = try #require(try FileSystemService().candidates(in: fixture.movies).first)
    let provider = CountingProvider()
    let processor = MovieFolderProcessor(
      persistence: fixture.persistence, provider: provider, cacheDirectory: fixture.cache,
      posterAssigner: fixture.assigner, processingConfiguration: CollectionProcessingConfiguration(isPaused: true))

    await #expect(throws: CollectionProcessingError.configurationChanged) {
      try await processor.process(root: fixture.movies)
    }
    let movie = MovieMetadata(id: 7, title: "Dune", originalTitle: "Dune", releaseYear: 2021, posterPath: "/dune.jpg")
    await #expect(throws: CollectionProcessingError.configurationChanged) {
      try await processor.applyMoviePoster(
        movie, root: fixture.movies, child: candidate.name, expectedIdentity: candidate.identity)
    }
    #expect(await provider.searchCount == .zero)
    #expect(await provider.posterCount == .zero)
    #expect(fixture.assigner.assignmentCount == .zero)
  }

  /// Exclusion follows stable identity, preserving processing decisions while suppressing provider and icon work.
  @Test func exclusionFollowsRenamedFolder() async throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try fixture.addFolder("Dune (2021)")
    let candidate = try #require(try FileSystemService().candidates(in: fixture.movies).first)
    let configuration = CollectionProcessingConfiguration(excludedFolders: [
      ExcludedMovieFolder(identity: candidate.identity, lastKnownName: candidate.name)
    ])
    try FileManager.default.moveItem(
      at: fixture.movies.appendingPathComponent(candidate.name),
      to: fixture.movies.appendingPathComponent("Dune.2021"))
    let provider = CountingProvider()
    let processor = MovieFolderProcessor(
      persistence: fixture.persistence, provider: provider, cacheDirectory: fixture.cache,
      posterAssigner: fixture.assigner, processingConfiguration: configuration)

    let summary = try await processor.process(root: fixture.movies)

    #expect(summary.excluded == 1)
    #expect(summary.examined == .zero)
    #expect(await provider.searchCount == .zero)
    #expect(await provider.posterCount == .zero)
    #expect(fixture.assigner.assignmentCount == .zero)
  }
}
