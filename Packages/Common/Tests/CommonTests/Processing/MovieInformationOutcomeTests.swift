import FileSystem
import Foundation
@testable import Common
import Testing

/// Successful source interpretations retain accurate, stable movie-identity provenance in persisted outcomes.
@Test(arguments: [0, 1, 2, 3])
func movieInformationOutcomeRetainsSourceProvenance(source: Int) async throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  let name = source == 0 ? "Alien [tmdb:348]" : "Unclear (2021) (2022)"
  try fixture.addFolder(name)
  let child = fixture.movies.appendingPathComponent(name)
  if source == 1 {
    try Data("<movie><title>Alien</title><year>1979</year></movie>".utf8)
      .write(to: child.appendingPathComponent("movie.nfo"))
  } else if source > 1 {
    try Data().write(to: child.appendingPathComponent("Alien (1979)." + (source == 2 ? "mkv" : "jpg")))
  }
  let provider: any MovieMetadataProvider = source == 0
    ? IdentifierInformationProvider(fails: false, disagrees: false, hasPoster: true)
    : CountingProvider(primaryReleaseYear: 1979)
  let processor = MovieFolderProcessor(persistence: fixture.persistence, provider: provider,
    cacheDirectory: fixture.cache, posterAssigner: fixture.assigner,
    movieMatchingConfiguration: MovieMatchingConfiguration(readsNFOInformation: true,
      readsImmediateVideoNames: true, readsImmediateImageNames: true))
  #expect(try await processor.process(root: fixture.movies).assigned == 1)
  let access = try #require(try fixture.persistence.acquireAccess(for:
    MovieFolderProcessor.processingStateKey(for: fixture.movies)))
  let cache = try JSONDecoder().decode(CollectionProcessingCache.self, from: #require(try access.read()))
  #expect(cache.folders[name]?.movieIdentitySource?.rawValue ==
    ["validatedIdentifier", "nfoInformation", "videoNameInformation", "imageNameInformation"][source])
}

/// Contradiction is explained distinctly from malformed XML and incomplete selected filesystem information.
@Test(arguments: [0, 1, 2, 3])
func movieInformationOutcomeDistinguishesConflictFromUnusableInputs(kind: Int) async throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  let name = "Alien [tmdb:42]"
  try fixture.addFolder(name)
  let nfo = fixture.movies.appendingPathComponent(name + "/movie.nfo")
  if kind == 2 {
    try FileManager.default.createSymbolicLink(atPath: nfo.path, withDestinationPath: "/absent")
  } else {
    let xml: String
    switch kind {
    case 0:
      xml = #"<movie><uniqueid type="tmdb">43</uniqueid></movie>"#
    case 3:
      xml = "<movie><title>Alien</title><title>Dune</title></movie>"
    default:
      xml = "<movie>"
    }
    try Data(xml.utf8).write(to: nfo)
  }
  let provider = IdentifierInformationProvider(fails: false, disagrees: false, hasPoster: true)
  let processor = MovieFolderProcessor(persistence: fixture.persistence, provider: provider,
    cacheDirectory: fixture.cache, posterAssigner: fixture.assigner,
    movieMatchingConfiguration: MovieMatchingConfiguration(readsNFOInformation: true))
  #expect(try await processor.process(root: fixture.movies).unresolved == 1)
  #expect(try await processor.process(root: fixture.movies).examined == 0)
  #expect(await provider.lookupCount == 0)
  let access = try #require(try fixture.persistence.acquireAccess(for:
    MovieFolderProcessor.processingStateKey(for: fixture.movies)))
  let cache = try JSONDecoder().decode(CollectionProcessingCache.self, from: #require(try access.read()))
  #expect(cache.folders[name]?.processingReason?.rawValue ==
    (kind == 0 || kind == 3 ? "conflictingMovieInformation" : "manualMatchingRequired"))
}

/// Different valid provider identities report disagreement, without treating provider failure as contradiction.
@Test func movieInformationOutcomeReportsProviderIdentifierConflict() async throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  let name = "Alien [tmdb:348] [imdb:tt0078748]"
  try fixture.addFolder(name)
  let provider = IdentifierInformationProvider(fails: false, disagrees: true)
  let processor = MovieFolderProcessor(persistence: fixture.persistence, provider: provider,
    cacheDirectory: fixture.cache, posterAssigner: fixture.assigner)
  #expect(try await processor.process(root: fixture.movies).unresolved == 1)
  let access = try #require(try fixture.persistence.acquireAccess(for:
    MovieFolderProcessor.processingStateKey(for: fixture.movies)))
  let cache = try JSONDecoder().decode(CollectionProcessingCache.self, from: #require(try access.read()))
  #expect(cache.folders[name]?.processingReason == .conflictingMovieInformation)
  #expect(await provider.lookupCount == 2)
}

/// Explicit selection resolves conflicting local information and remains authoritative on the next visit.
@Test func movieInformationOutcomeExplicitSelectionResolvesConflict() async throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  let name = "Alien [tmdb:42]"
  try fixture.addFolder(name)
  try Data(#"<movie><uniqueid type="tmdb">43</uniqueid></movie>"#.utf8)
    .write(to: fixture.movies.appendingPathComponent(name + "/movie.nfo"))
  let provider = IdentifierInformationProvider(fails: false, disagrees: false, hasPoster: true)
  let processor = MovieFolderProcessor(persistence: fixture.persistence, provider: provider,
    cacheDirectory: fixture.cache, posterAssigner: fixture.assigner,
    movieMatchingConfiguration: MovieMatchingConfiguration(readsNFOInformation: true))
  #expect(try await processor.process(root: fixture.movies).unresolved == 1)
  let candidate = try #require(FileSystemService().candidates(in: fixture.movies).first)
  let selected = MovieMetadata(id: 348, title: "Alien", originalTitle: "Alien", releaseYear: 1979,
    posterPath: "/fixture.png")
  #expect(try await processor.applyMoviePoster(selected, root: fixture.movies, child: name,
    expectedIdentity: candidate.identity) == 348)
  _ = try await processor.process(root: fixture.movies)
  let access = try #require(try fixture.persistence.acquireAccess(for:
    MovieFolderProcessor.processingStateKey(for: fixture.movies)))
  let cache = try JSONDecoder().decode(CollectionProcessingCache.self, from: #require(try access.read()))
  #expect(cache.folders[name]?.matchedMovieID == 348)
  #expect(cache.folders[name]?.movieIdentitySource == .explicitSelection)
  #expect(await provider.lookupCount == 0)
}

/// Stored conflict reasons produce exact actionable guidance and no automatic retry deadline.
@Test func movieInformationOutcomeConflictGuidanceAndWireRoundTrip() throws {
  let event = MovieFolderActivityLogEvent(action: .automaticProcessing, status: .partial,
    folderResult: .unresolved, reason: .conflictingMovieInformation)
  #expect(event.text.contains("Movie identifiers or local movie information conflict; choose manually."))
  let malformed = MovieFolderActivityLogEvent(action: .automaticProcessing, status: .partial,
    folderResult: .unresolved, reason: .manualMatchingRequired)
  #expect(!malformed.text.contains("disagrees"))
  let record = FolderProcessingRecord(name: "Movie", state: .unresolved, reason: .conflictingMovieInformation,
    retryAt: Date())
  #expect(record.automaticRetryAt == .none)
  #expect(try JSONDecoder().decode(FolderProcessingRecord.self, from: JSONEncoder().encode(record)) == record)
  let sources: [MovieIdentitySource] = [
    .validatedIdentifier, .nfoInformation, .videoNameInformation, .imageNameInformation
  ]
  for source in sources {
    #expect(try JSONDecoder().decode(MovieIdentitySource.self, from: JSONEncoder().encode(source)) == source)
  }
}
