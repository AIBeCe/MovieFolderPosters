import Darwin
import FileSystem
import Foundation
@testable import MovieFolderCommon
import Network
import Persistence
import Testing

extension R12004LocalInformationAcceptanceTests {
  /// AT06: Given a completed empty/nonmovie/ambiguous response or provider failure, no weaker match is assigned.
  @Test(arguments: [R12004AcceptanceTransport.Mode.missing, .nonmovie, .ambiguous, .malformed,
    .mismatched, .authentication, .rateLimited, .offline])
  func at06ProviderFailuresPreserveRecoveryAndNeverFallBack(mode: R12004AcceptanceTransport.Mode) async throws {
    let fixture = try R12004AcceptanceFixture(name: "Alien (1979) [tmdb:348] [imdb:tt0078748]", mode: mode)
    defer { try? FileManager.default.removeItem(at: fixture.environment.base) }
    let recovery = ProcessingRecoveryService(store: try PersistenceStore(
      directory: fixture.environment.base.appendingPathComponent("Recovery")))
    let provider = RecoveryAwareMovieMetadataProvider(provider: fixture.provider, recovery: recovery,
      credential: "R12004-fixture-not-a-real-credential")
    let processor = MovieFolderProcessor(persistence: fixture.environment.processing, provider: provider,
      cacheDirectory: fixture.environment.base.appendingPathComponent("Posters"),
      processingLockStore: fixture.environment.coordination, processingStore: fixture.environment.processingStore,
      recovery: recovery, credentialRevision: fixture.environment.context.credentialRevision)
    #expect(try await processor.process(root: fixture.environment.root,
      processingContext: fixture.environment.context).assigned == 0)
    let result = try fixture.outcome()
    #expect(result.matchedMovieID == .none)
    #expect(await fixture.transport.queries.isEmpty)
    let reason: FolderProcessingReason = switch mode {
    case .missing, .nonmovie: .noSuitableMovie
    case .authentication: .authentication
    case .rateLimited: .rateLimited
    case .offline: .connectivity
    default: .invalidResponse
    }
    #expect(result.processingReason == reason)
    if [.authentication, .rateLimited, .offline].contains(mode) {
      #expect(try recovery.read().providerFailureReason == reason)
      let requests = await fixture.transport.paths.count
      _ = try await processor.process(root: fixture.environment.root, processingContext: fixture.environment.context)
      #expect(await fixture.transport.paths.count == requests)
    }
  }

  /// AT17: Edits during each remote stage prevent stale identity and real icon assignment after the response arrives.
  @Test(arguments: ["search/movie", "alternative_titles", "release_dates", "w500/fixture.png"])
  func at17ProviderWaitChangesDiscardStaleAttempts(stage: String) async throws {
    let fixture = try R12004AcceptanceFixture(matching: MovieMatchingConfiguration(readsNFOInformation: true),
      hold: stage)
    defer { try? FileManager.default.removeItem(at: fixture.environment.base) }
    try fixture.writeNFO(year: 1980)
    let task = Task { try await fixture.process() }
    await fixture.transport.waitUntilHeld()
    try fixture.writeNFO(title: "Dune")
    await fixture.transport.resume()
    #expect(try await task.value.assigned == 0)
    #expect(try fixture.outcome().matchedMovieID == .none)
    #expect(try !fixture.fileSystem.readCurrentFolderCandidate(ofChild: fixture.name,
      in: fixture.environment.root).hasCustomIcon)
    let cache = try JSONDecoder().decode(CollectionProcessingCache.self, from: fixture.operationalBytes())
    #expect(cache.folders[fixture.name]?.matchedMovieID == .none)
  }

  /// AT12/AT17: A final-boundary edit or directory replacement prevents the real icon adapter from writing.
  @Test(arguments: [false, true])
  func at17FinalFenceAndReplacementPreventAssignment(replacesFolder: Bool) async throws {
    let fixture = try R12004AcceptanceFixture(matching: MovieMatchingConfiguration(readsNFOInformation: true))
    defer { try? FileManager.default.removeItem(at: fixture.environment.base) }
    try fixture.writeNFO()
    let verifier = R12004AcceptanceMutationVerifier(child: fixture.child, replacesFolder: replacesFolder)
    let processor = fixture.processor(verifier: verifier)
    do {
      #expect(try await processor.process(root: fixture.environment.root,
        processingContext: fixture.environment.context).assigned == 0)
    } catch {
      #expect(replacesFolder)
      #expect(error is DirectoryAccessError || error is AutomaticProcessingIssue)
    }
    #expect(try !fixture.fileSystem.readCurrentFolderCandidate(ofChild: fixture.name,
      in: fixture.environment.root).hasCustomIcon)
  }

  /// AT10: Given supported NFO fields and Unicode encodings, reopening real processing installs the intended movie.
  @Test(arguments: ["title", "originaltitle", "tmdb", "imdb"], [false, true])
  func at10NFOFieldsAndEncodingEstablishMovie(field: String, utf16: Bool) async throws {
    let fixture = try R12004AcceptanceFixture(matching: MovieMatchingConfiguration(readsNFOInformation: true))
    defer { try? FileManager.default.removeItem(at: fixture.environment.base) }
    let xml = field == "title" || field == "originaltitle"
      ? "<movie><\(field)>Alien</\(field)><year>1979</year></movie>"
      : "<movie><uniqueid type=\"\(field)\">\(field == "tmdb" ? "348" : "tt0078748")</uniqueid></movie>"
    try fixture.write("movie.nfo", contents: #require(xml.data(using: utf16 ? .utf16 : .utf8)))
    #expect(try await fixture.process().assigned == 1)
    let source: MovieIdentitySource = field == "title" || field == "originaltitle"
      ? .nfoInformation : .validatedIdentifier
    try fixture.expectAssigned(source: source)
  }

  /// AT12: Given immediate unsafe entries or irrelevant nested/unsupported files, no content-derived fallback occurs.
  @Test(arguments: ["nested", "unsupported", "symlink", "fifo", "hidden"])
  func at12OnlyImmediateRegularSupportedInformationContributes(kind: String) async throws {
    let fixture = try R12004AcceptanceFixture(matching: MovieMatchingConfiguration(readsNFOInformation: true,
      readsImmediateVideoNames: true))
    defer { try? FileManager.default.removeItem(at: fixture.environment.base) }
    switch kind {
    case "nested":
      try FileManager.default.createDirectory(at: fixture.child.appendingPathComponent("nested"),
        withIntermediateDirectories: false)
      try fixture.write("nested/Alien (1979).mkv")
    case "unsupported": try fixture.write("Alien (1979).txt")
    case "symlink":
      let outsideMovie = fixture.environment.base.appendingPathComponent("OutsideMovie.nfo")
      try Data("<movie><title>Alien</title><year>1979</year></movie>".utf8).write(to: outsideMovie)
      try FileManager.default.createSymbolicLink(atPath: fixture.child.appendingPathComponent("movie.nfo").path,
        withDestinationPath: outsideMovie.path)
    case "fifo": #expect(mkfifo(fixture.child.appendingPathComponent("movie.nfo").path, 0o600) == 0)
    default: try fixture.write(".Alien (1979).mkv")
    }
    #expect(try await fixture.process().assigned == (kind == "hidden" ? 1 : 0))
    if kind == "hidden" {
      try fixture.expectAssigned(source: .videoNameInformation)
    } else {
      #expect(await fixture.transport.paths.isEmpty)
    }
  }

  /// AT13: Given exact or exceeded budgets, only a complete within-budget source can establish a unique movie.
  @Test(arguments: ["entries", "nfo-count", "nfo-bytes", "nfo-total"], [false, true])
  func at13InclusiveBudgetsRejectPartialUniqueness(budget: String, exceeds: Bool) async throws {
    let fixture = try R12004AcceptanceFixture(matching: MovieMatchingConfiguration(readsNFOInformation: true))
    defer { try? FileManager.default.removeItem(at: fixture.environment.base) }
    switch budget {
    case "entries":
      try fixture.writeNFO()
      for index in 0..<(exceeds ? 1_024 : 1_023) { try fixture.write("ignored-\(index).txt") }
    case "nfo-count":
      for index in 0..<(exceeds ? 9 : 8) { try fixture.writeNFO(name: "\(index).nfo") }
    case "nfo-bytes": try fixture.writeNFO(bytes: 256 * 1_024 + (exceeds ? 1 : 0))
    default:
      for index in 0..<4 {
        let bytes = exceeds && index == 0 ? 256 * 1_024 - 255 : 256 * 1_024
        try fixture.writeNFO(bytes: bytes, name: "\(index).nfo")
      }
      if exceeds { try fixture.writeNFO(bytes: 256, name: "4.nfo") }
    }
    #expect(try await fixture.process().assigned == (exceeds ? 0 : 1))
    if exceeds {
      #expect(await fixture.transport.paths.isEmpty)
    } else {
      try fixture.expectAssigned(source: .nfoInformation)
    }
  }

  /// AT14: Given each supported case-insensitive extension, filenames establish identity without media decoding.
  @Test(arguments: ["mkv", "mp4", "m4v", "avi", "mov", "mpg", "mpeg", "ts", "jpg", "jpeg", "png",
    "webp", "heic", "tif", "tiff", "bmp", "avif"])
  func at14EverySupportedExtensionUsesItsFilename(suffix: String) async throws {
    let fixture = try R12004AcceptanceFixture(matching: MovieMatchingConfiguration(
      readsImmediateVideoNames: true, readsImmediateImageNames: true))
    defer { try? FileManager.default.removeItem(at: fixture.environment.base) }
    let bytes = Data("deliberately invalid media bytes".utf8)
    try fixture.write("Alien (1979)." + suffix.uppercased(), contents: bytes)
    #expect(try await fixture.process().assigned == 1)
    let video = ["mkv", "mp4", "m4v", "avi", "mov", "mpg", "mpeg", "ts"].contains(suffix)
    try fixture.expectAssigned(source: video ? .videoNameInformation : .imageNameInformation)
    #expect(try Data(contentsOf: fixture.child.appendingPathComponent("Alien (1979)." + suffix.uppercased())) == bytes)
  }

  /// AT14: Given generic artwork/sample stems, they contribute no identity and cannot create a provider request.
  @Test(arguments: ["poster", "cover", "folder", "fanart", "sample", "trailer"])
  func at14GenericNamesCannotEstablishIdentity(stem: String) async throws {
    let fixture = try R12004AcceptanceFixture(matching: MovieMatchingConfiguration(
      readsImmediateVideoNames: true, readsImmediateImageNames: true))
    defer { try? FileManager.default.removeItem(at: fixture.environment.base) }
    try fixture.write(stem + ".jpg")
    try fixture.write(stem.uppercased() + ".MKV")
    #expect(try await fixture.process().assigned == 0)
    #expect(await fixture.transport.paths.isEmpty)
  }
}
