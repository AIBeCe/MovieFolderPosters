import Darwin
import FileSystem
import Foundation
import Network
import Persistence
import Testing
@testable import MovieFolderCommon

/// AT04–AT20/AT22 integration acceptance through real processing, durable outcomes and disposable Finder icons.
/// Full-app Settings/Choose Movie E2E is covered separately by the native UI test target.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct R12004LocalInformationAcceptanceTests {
  /// AT04/20: Host-style recovery composition resolves each identity through a real selected retry.
  @Test(arguments: ["[tmdb:1]", "[imdb:tt0000001]", "[tmdb:1] [imdb:tt0000001]"])
  func at04HostProviderCompositionResolvesSelectedIdentifiers(labels: String) async throws {
    let name = "Unrelated " + labels
    let environment = try CollectionProcessingTestEnvironment(names: [name])
    defer { try? FileManager.default.removeItem(at: environment.base) }
    let image = try #require(Bundle.module.url(forResource: "TestPoster", withExtension: "png"))
    let client = TMDbClient(token: try TMDbAccessToken("fixture-token"),
      transport: StubTMDbTransport(posterData: try Data(contentsOf: image)))
    let recovery = ProcessingRecoveryService(store: try PersistenceStore(
      directory: environment.base.appendingPathComponent("Recovery")))
    let provider = RecoveryAwareMovieMetadataProvider(provider: client, recovery: recovery, credential: "fixture-token")
    let fileSystem = FileSystemService()
    let candidate = try fileSystem.readCurrentFolderCandidate(ofChild: name, in: environment.root)
    var state = try environment.processingStore.recordProcessingStart(context: environment.context, action: .automatic)
    state.folders = [FolderProcessingRecord(name: name, identity: candidate.identity,
      state: .failed, reason: .metadataFailure)]
    state.isInventoryComplete = true
    state.inspectedAt = Date()
    state.currentRun?.runState = .partial
    _ = try environment.processingStore.commit(state, expectedRevision: state.revision)
    let processor = environment.processor(provider: provider)
    _ = try await processor.retryEligibleFolder(root: environment.root, child: name,
      expectedIdentity: candidate.identity, processingContext: environment.context)
    let saved = try #require(try environment.processingStore.read(rootID: environment.context.rootID))
    let outcome = try #require(saved.folders.first)
    #expect(outcome.matchedMovieID == 1)
    #expect(outcome.movieIdentitySource == .validatedIdentifier)
    #expect(outcome.isVerifiedDone)
  }

  /// AT04: Given valid labelled identities, when a collection is processed, then one provider identity owns its icon.
  @Test(arguments: ["[tmdb:348]", "[tmdb-348]", "[TMDB348]", "[imdb:tt0078748]", "[tt0078748]",
    "[tmdb:348] [imdb:tt0078748]", "[tmdb:348] [tmdb:348]"])
  func at04LabelledIdentifiersEstablishOneOwnedPoster(labels: String) async throws {
    let fixture = try R12004AcceptanceFixture(name: "Alien " + labels)
    defer { try? FileManager.default.removeItem(at: fixture.environment.base) }
    #expect(try await fixture.process().assigned == 1)
    try fixture.expectAssigned(source: .validatedIdentifier)
    #expect(await fixture.transport.queries.isEmpty)
    #expect(await fixture.transport.paths.filter { $0 == "/3/movie/348" }.count <= 1)
  }

  /// AT05: Given invalid or contradictory explicit labels, processing never searches the weaker folder title.
  @Test(arguments: ["[tmdb:0]", "[tmdb:-1]", "[tmdb:2147483648]", "[tmdb:999999999999999999999]",
    "[imdb:tt123]", "[imdb:tt0000000]", "[imdb:tt12345678901]", "[tmdb:348junk]",
    "[imdb:tt0078748junk]", "[tmdb:nope]", "[tmdb:348", "[tmdb:348] [tmdb:349]"])
  func at05UnusableIdentifiersNeverFallBack(labels: String) async throws {
    let fixture = try R12004AcceptanceFixture(name: "Alien (1979) " + labels)
    defer { try? FileManager.default.removeItem(at: fixture.environment.base) }
    #expect(try await fixture.process().assigned == 0)
    #expect(try fixture.outcome().matchedMovieID == .none)
    #expect(await fixture.transport.paths.isEmpty)
    #expect(try !fixture.fileSystem.readCurrentFolderCandidate(ofChild: fixture.name,
      in: fixture.environment.root).hasCustomIcon)
  }

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

  /// AT07: Given each source enabled or disabled independently, only the explicitly enabled source can match.
  @Test(arguments: ["nfo", "video", "image"], [false, true])
  func at07SourceGatesAreIndependent(source: String, enabled: Bool) async throws {
    let matching = MovieMatchingConfiguration(readsNFOInformation: source == "nfo" && enabled,
      readsImmediateVideoNames: source == "video" && enabled, readsImmediateImageNames: source == "image" && enabled)
    let fixture = try R12004AcceptanceFixture(matching: matching)
    defer { try? FileManager.default.removeItem(at: fixture.environment.base) }
    if source == "nfo" { try fixture.writeNFO() }
    else { try fixture.write("Alien (1979)." + (source == "video" ? "mkv" : "jpg")) }
    #expect(try await fixture.process().assigned == (enabled ? 1 : 0))
    if enabled {
      let identity: MovieIdentitySource = source == "nfo" ? .nfoInformation
        : (source == "video" ? .videoNameInformation : .imageNameInformation)
      try fixture.expectAssigned(source: identity)
    } else {
      #expect(await fixture.transport.paths.isEmpty)
      #expect(try fixture.outcome().matchedMovieID == .none)
    }
  }

  /// AT08: Given multiple ranked sources, lower titles cannot replace identifiers or the highest available title.
  @Test(arguments: [0, 1, 2, 3, 4], [false, true])
  func at08HighestCompleteSourceWins(level: Int, reversesCreation: Bool) async throws {
    let fixture = try R12004AcceptanceFixture(name: level == 0 ? "Folder [tmdb:348]" : "Folder Movie (1979)",
      matching: MovieMatchingConfiguration(readsNFOInformation: true,
        readsImmediateVideoNames: true, readsImmediateImageNames: true))
    defer { try? FileManager.default.removeItem(at: fixture.environment.base) }
    var names = [String]()
    if level <= 1 { names.append("movie.nfo") }
    if level <= 2 { names.append("Video Movie (1979).mkv") }
    if level <= 3 { names.append("Image Movie (1979).jpg") }
    if reversesCreation { names.reverse() }
    for name in names {
      if name == "movie.nfo" { try fixture.writeNFO(title: "NFO Movie") }
      else { try fixture.write(name) }
    }
    #expect(try await fixture.process().assigned == 1)
    let sources: [MovieIdentitySource] = [.validatedIdentifier, .nfoInformation, .videoNameInformation,
      .imageNameInformation, .conservativeMatch]
    try fixture.expectAssigned(source: sources[level])
    let queries = await fixture.transport.queries
    #expect(queries == (level == 0 ? [] : [["", "NFO Movie", "Video Movie", "Image Movie", "Folder Movie"][level]]))
  }

  /// AT09: Given equal-rank or cross-source contradictions, the persisted conflict remains manual on another visit.
  @Test(arguments: ["video", "image", "nfo", "folder-nfo", "provider"])
  func at09ContradictionsRemainManualWithoutRetryLoop(kind: String) async throws {
    let fixture = try R12004AcceptanceFixture(
      name: kind == "folder-nfo" ? "Alien [tmdb:348]" :
        (kind == "provider" ? "Alien [tmdb:348] [imdb:tt0078748]" : "Folder Movie (1979)"),
      matching: MovieMatchingConfiguration(readsNFOInformation: true,
        readsImmediateVideoNames: true, readsImmediateImageNames: true),
      mode: kind == "provider" ? .disagree : .normal)
    defer { try? FileManager.default.removeItem(at: fixture.environment.base) }
    switch kind {
    case "video", "image":
      let suffix = kind == "video" ? "mkv" : "jpg"
      try fixture.write("Alien (1979)." + suffix)
      try fixture.write("Dune (1979)." + suffix)
    case "nfo":
      try fixture.writeNFO(title: "Alien", name: "one.nfo")
      try fixture.writeNFO(title: "Dune", name: "two.nfo")
    case "folder-nfo": try fixture.write("movie.nfo", contents: Data(
      #"<movie><uniqueid type="tmdb">349</uniqueid></movie>"#.utf8))
    default: break
    }
    #expect(try await fixture.process().assigned == 0)
    let result = try fixture.outcome()
    #expect(result.processingReason == .conflictingMovieInformation)
    #expect(result.nextRetryAt == .none)
    let requests = await fixture.transport.paths.count
    #expect(try await fixture.process().examined == 0)
    #expect(await fixture.transport.paths.count == requests)
  }

  /// AT09: Equally ranked files with the same interpretation still establish one unique movie.
  @Test(arguments: ["nfo", "video", "image"])
  func at09ConsistentSameRankFilesEstablishOneMovie(source: String) async throws {
    let fixture = try R12004AcceptanceFixture(matching: MovieMatchingConfiguration(readsNFOInformation: true,
      readsImmediateVideoNames: true, readsImmediateImageNames: true))
    defer { try? FileManager.default.removeItem(at: fixture.environment.base) }
    let identitySource: MovieIdentitySource
    if source == "nfo" {
      try fixture.writeNFO(name: "first.nfo")
      try fixture.writeNFO(name: "second.nfo")
      identitySource = .nfoInformation
    } else {
      let extensions = source == "video" ? ["mkv", "mp4"] : ["jpg", "png"]
      for suffix in extensions { try fixture.write("Alien (1979)." + suffix) }
      identitySource = source == "video" ? .videoNameInformation : .imageNameInformation
    }
    #expect(try await fixture.process().assigned == 1)
    try fixture.expectAssigned(source: identitySource)
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

  /// AT11: Given unsafe or malformed selected XML, processing rejects the complete document without provider work.
  @Test(arguments: ["", "<movie>", "<tvshow><title>Alien</title></tvshow>",
    "<movie><year>zero</year></movie>", "<movie><year>0000</year></movie>",
    "<movie><uniqueid type=\"tmdb\">348]junk</uniqueid></movie>",
    "<movie><title>Alien</title><title>Dune</title></movie>",
    "<movie><title>Alien</title><year>1979</year><year>1980</year></movie>",
    "<movie><uniqueid type=\"tmdb\">348</uniqueid><uniqueid type=\"tmdb\">349</uniqueid></movie>",
    "<!DOCTYPE movie><movie><title>Alien</title></movie>",
    "<!DOCTYPE movie [<!ENTITY title 'Alien'>]><movie><title>&title;</title></movie>",
    "<!DOCTYPE movie SYSTEM 'https://invalid.example/movie.dtd'><movie/>"])
  func at11UnsafeNFOCannotEstablishPartialIdentity(xml: String) async throws {
    let fixture = try R12004AcceptanceFixture(name: "Alien (1979)",
      matching: MovieMatchingConfiguration(readsNFOInformation: true))
    defer { try? FileManager.default.removeItem(at: fixture.environment.base) }
    try fixture.write("movie.nfo", contents: Data(xml.utf8))
    #expect(try await fixture.process().assigned == 0)
    #expect(try fixture.outcome().matchedMovieID == .none)
    #expect(await fixture.transport.paths.isEmpty)
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
    if kind == "hidden" { try fixture.expectAssigned(source: .videoNameInformation) }
    else { #expect(await fixture.transport.paths.isEmpty) }
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
    if exceeds { #expect(await fixture.transport.paths.isEmpty) }
    else { try fixture.expectAssigned(source: .nfoInformation) }
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

  /// AT15: Given a local poster file, provider artwork is downloaded and the local file's bytes remain untouched.
  @Test func at15ProviderArtworkIsUsedWithoutChangingMovieContents() async throws {
    let fixture = try R12004AcceptanceFixture(matching: MovieMatchingConfiguration(
      readsNFOInformation: true, readsImmediateImageNames: true))
    defer { try? FileManager.default.removeItem(at: fixture.environment.base) }
    try fixture.writeNFO()
    let local = Data("local artwork must never be selected or rewritten".utf8)
    try fixture.write("poster.jpg", contents: local)
    try fixture.write("video.mkv", contents: local)
    #expect(try await fixture.process().assigned == 1)
    try fixture.expectAssigned(source: .nfoInformation)
    #expect(await fixture.transport.paths.contains("/t/p/w500/fixture.png"))
    #expect(try Data(contentsOf: fixture.child.appendingPathComponent("poster.jpg")) == local)
    #expect(try Data(contentsOf: fixture.child.appendingPathComponent("video.mkv")) == local)
  }

  /// AT16: Reopening reuses unchanged unresolved information and reassesses changed information without persisting XML.
  @Test func at16ChangedUnresolvedInformationReassessesAfterReopen() async throws {
    let fixture = try R12004AcceptanceFixture(matching: MovieMatchingConfiguration(readsNFOInformation: true),
      mode: .unknownIsEmpty)
    defer { try? FileManager.default.removeItem(at: fixture.environment.base) }
    let raw = "<movie><!--private-NFO-secret--><title>Unknown</title><year>1979</year></movie>"
    try fixture.write("movie.nfo", contents: Data(raw.utf8))
    #expect(try await fixture.process().assigned == 0)
    #expect(try fixture.outcome().processingState == .notFound)
    let before = try fixture.operationalBytes()
    let original = try JSONDecoder().decode(CollectionProcessingCache.self, from: before)
    let sha256 = try #require(original.folders[fixture.name]?.localInformationReadResultSHA256)
    #expect(sha256.count == 64)
    try fixture.expectPrivateNFOAbsent("private-NFO-secret")
    #expect(try await fixture.process().examined == 0)
    #expect(await fixture.transport.queries == ["Unknown"])
    try fixture.writeNFO()
    #expect(try await fixture.process().assigned == 1)
    try fixture.expectAssigned(source: .nfoInformation)
    let changed = try JSONDecoder().decode(CollectionProcessingCache.self, from: fixture.operationalBytes())
    #expect(changed.folders[fixture.name]?.localInformationReadResultSHA256 != sha256)
    #expect(await fixture.transport.queries == ["Unknown", "Alien"])
    try fixture.expectPrivateNFOAbsent("private-NFO-secret")
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

  /// AT18: Cancellation saves no negative identity; a later authorized visit completes from current information.
  @Test func at18CancellationDoesNotSaveNegativeIdentityAndCanResume() async throws {
    let fixture = try R12004AcceptanceFixture(matching: MovieMatchingConfiguration(readsNFOInformation: true),
      hold: "search/movie")
    defer { try? FileManager.default.removeItem(at: fixture.environment.base) }
    try fixture.writeNFO()
    let task = Task { try await fixture.process() }
    await fixture.transport.waitUntilHeld()
    task.cancel()
    await fixture.transport.resume()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try fixture.outcome().matchedMovieID == .none)
    #expect(try fixture.outcome().processingState != .notFound)
    #expect(try !fixture.fileSystem.readCurrentFolderCandidate(ofChild: fixture.name,
      in: fixture.environment.root).hasCustomIcon)
    #expect(try await fixture.process().assigned == 1)
    try fixture.expectAssigned(source: .nfoInformation)
  }

  /// AT19: Conflicting new information cannot replace an installed confirmed or explicitly selected identity/icon.
  @Test(arguments: [false, true])
  func at19ConfirmedAndExplicitPostersSurviveInformationChanges(explicit: Bool) async throws {
    let fixture = try R12004AcceptanceFixture(matching: MovieMatchingConfiguration(readsNFOInformation: true))
    defer { try? FileManager.default.removeItem(at: fixture.environment.base) }
    try fixture.writeNFO()
    if explicit {
      let candidate = try #require(fixture.fileSystem.candidates(in: fixture.environment.root).first)
      let movie = MovieMetadata(id: 348, title: "Alien", originalTitle: "Alien", releaseYear: 1979,
        posterPath: "/fixture.png")
      #expect(try await fixture.processor().applyMoviePoster(movie, root: fixture.environment.root,
        child: fixture.name, expectedIdentity: candidate.identity,
        processingContext: fixture.environment.context) == 348)
    } else { #expect(try await fixture.process().assigned == 1) }
    let icon = try r12004InstalledIconMaterial(at: fixture.child)
    let requests = await fixture.transport.paths.count
    try fixture.write("movie.nfo", contents: Data(#"<movie><uniqueid type="tmdb">999</uniqueid></movie>"#.utf8))
    #expect(try await fixture.process().assigned == 0)
    try fixture.expectAssigned(source: explicit ? .explicitSelection : .nfoInformation)
    #expect(try r12004InstalledIconMaterial(at: fixture.child) == icon)
    #expect(await fixture.transport.paths.count == requests)
  }

  /// AT20: Selected retry reopens changed negative input; fresh refresh cannot use information changed during search.
  @Test(arguments: ["selected", "refresh-current", "refresh-changed"])
  func at20SelectedRetryUsesCurrentInformationAndFreshRefreshIsProtected(operation: String) async throws {
    let refresh = operation != "selected"
    let changes = operation == "refresh-changed"
    let fixture = try R12004AcceptanceFixture(matching: MovieMatchingConfiguration(readsNFOInformation: true),
      mode: .unknownIsEmpty, hold: changes ? "search/movie" : .none)
    defer { try? FileManager.default.removeItem(at: fixture.environment.base) }
    if !refresh {
      try fixture.writeNFO(title: "Unknown")
      #expect(try await fixture.process().assigned == 0)
      #expect(try fixture.outcome().processingState == .notFound)
    }
    try fixture.writeNFO()
    let candidate = try #require(fixture.fileSystem.candidates(in: fixture.environment.root).first)
    let processor = fixture.processor()
    if refresh && !changes {
      #expect(try await processor.refreshPoster(root: fixture.environment.root, child: fixture.name,
        expectedIdentity: candidate.identity, processingContext: fixture.environment.context) == 348)
      try fixture.expectAssigned(source: .nfoInformation)
    } else if refresh {
      let task = Task { try await processor.refreshPoster(root: fixture.environment.root, child: fixture.name,
        expectedIdentity: candidate.identity, processingContext: fixture.environment.context) }
      await fixture.transport.waitUntilHeld()
      try fixture.writeNFO(title: "Dune")
      await fixture.transport.resume()
      await #expect(throws: AutomaticProcessingIssue.changedInformation) { try await task.value }
      #expect(try !fixture.fileSystem.readCurrentFolderCandidate(ofChild: fixture.name,
        in: fixture.environment.root).hasCustomIcon)
    } else {
      let result = try await processor.retryEligibleFolder(root: fixture.environment.root, child: fixture.name,
        expectedIdentity: candidate.identity, processingContext: fixture.environment.context)

      guard case .attempted(let summary, _) = result else { Issue.record("Expected eligible changed input"); return }

      #expect(summary.assigned == 1)
      try fixture.expectAssigned(source: .nfoInformation)
    }
  }
}

/// Changes only an isolated fixture at the real synchronous current-authorization boundary.
private struct R12004AcceptanceMutationVerifier: MovieFolderProcessingVerifier {
  /// Disposable directory selected for this scenario.
  let child: URL
  /// Whether the test replaces the directory rather than edits its NFO.
  let replacesFolder: Bool
  func checkAutomaticProcessing(in root: URL) throws -> PersistenceAccess? { .none }
  func checkIconChange(_ change: MovieFolderIconChange, to candidate: MovieFolderCandidate,
    in root: URL) throws -> PersistenceAccess? {
    if change == .automaticPosterAssignment {
      if replacesFolder {
        try FileManager.default.moveItem(at: child, to: child.appendingPathExtension("previous"))
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
      } else {
        try Data("<movie><title>Dune</title><year>1979</year></movie>".utf8)
          .write(to: child.appendingPathComponent("movie.nfo"))
      }
    }

    return .none
  }
}

extension R12004LocalInformationAcceptanceTests {
  /// AT11: A positive-control loopback sentinel observes requests; DTD and entity inputs make no resource connection.
  @Test func at11XMLNeverFetchesExternalResources() async throws {
    let sentinel = try R12004XMLResourceSentinel()
    defer { sentinel.stop() }
    try await sentinel.positiveControl()
    for xml in [
      "<!DOCTYPE movie SYSTEM '\(sentinel.url.absoluteString)'><movie><title>Alien</title></movie>",
      "<!DOCTYPE movie [<!ENTITY external SYSTEM '\(sentinel.url.absoluteString)'>]>"
        + "<movie><title>&external;</title></movie>"
    ] {
      let fixture = try R12004AcceptanceFixture(name: "Alien (1979)",
        matching: MovieMatchingConfiguration(readsNFOInformation: true))
      defer { try? FileManager.default.removeItem(at: fixture.environment.base) }
      try fixture.write("movie.nfo", contents: Data(xml.utf8))
      #expect(try await fixture.process().assigned == 0)
      #expect(try fixture.outcome().matchedMovieID == .none)
      #expect(await fixture.transport.paths.isEmpty)
      #expect(sentinel.requestCount == 1)
    }
    // A second successful request drains earlier queued connections before the final absence assertion.
    try await sentinel.positiveControl(expectedCount: 2)
    #expect(sentinel.requestCount == 2)
  }

  /// AT22: Explicit migration preserves settings/outcome facts, defaults reads off and adopts an old labelled result.
  @Test func at22MigrationPreservesFactsAndAdoptsLegacyIdentifiers() async throws {
    let fixture = try R12004AcceptanceFixture(name: "Alien [tmdb:348]")
    defer { try? FileManager.default.removeItem(at: fixture.environment.base) }
    let environment = fixture.environment
    var original = try environment.configuration.read()
    original.movieMatchingConfiguration.comparesOriginalTitles = false
    original.directories[0].movieMatchingConfiguration = MovieMatchingConfiguration()
    var settings = try r12004JSONObject(JSONEncoder().encode(original))
    settings["version"] = 7
    settings["movieMatchingConfiguration"] = try r12004PriorMatching(settings["movieMatchingConfiguration"])
    var directories = try #require(settings["directories"] as? [[String: Any]])
    directories[0]["identificationPolicy"] = try r12004PriorMatching(directories[0]["identificationPolicy"])
    settings["directories"] = directories
    let settingsBytes = try JSONSerialization.data(withJSONObject: settings)
    let settingsStore = try PersistenceStore(directory: environment.base.appendingPathComponent("Settings"))
    do {
      let access = try #require(try settingsStore.acquireAccess(for: ConfigurationRepository.recordKey))
      try access.write(settingsBytes)
    }
    let candidate = try #require(fixture.fileSystem.candidates(in: environment.root).first)
    let oldFolder = FolderProcessingRecord(name: fixture.name, identity: candidate.identity, state: .notFound,
      reason: .noSuitableMovie, assessedAt: Date(timeIntervalSince1970: 1_234), fingerprint: candidate.fingerprint)
    let oldOutcome = CollectionProcessingState(revision: 17, context: environment.context, folders: [oldFolder],
      isInventoryComplete: true, inspectedAt: Date(timeIntervalSince1970: 1_234),
      lastCompletedRunContext: environment.context)
    var outcome = try r12004JSONObject(JSONEncoder().encode(oldOutcome))
    outcome["schemaVersion"] = 3
    for key in ["context", "lastCompletedRunContext"] {
      var context = try #require(outcome[key] as? [String: Any])
      context["identificationPolicy"] = try r12004PriorMatching(context["identificationPolicy"])
      outcome[key] = context
    }
    let outcomeBytes = try JSONSerialization.data(withJSONObject: outcome)
    let outcomeStore = try PersistenceStore(directory: environment.base.appendingPathComponent("Outcomes"))
    do {
      let access = try #require(try outcomeStore.acquireAccess(for:
        CollectionProcessingStore.processingStateKey(for: environment.context.rootID)))
      try access.write(outcomeBytes)
    }
    var oldRecord = FolderProcessingCacheRecord(fingerprint: candidate.fingerprint, status: .unresolved,
      retryDate: .none, matchedMovieID: .none, posterPath: .none, processingReason: .noSuitableMovie)
    oldRecord.savedMatchingRulesVersion = 1
    let retained = FolderProcessingCacheRecord(fingerprint: "historical", status: .processed, retryDate: .none,
      matchedMovieID: 999, posterPath: "/saved.png", movieIdentitySource: .explicitSelection)
    var operational = try r12004JSONObject(JSONEncoder().encode(CollectionProcessingCache(
      folders: [fixture.name: oldRecord, "Retained historical": retained])))
    operational["schemaVersion"] = 1
    operational["movieMatchingConfiguration"] = try r12004PriorMatching(operational["movieMatchingConfiguration"])
    let operationalBytes = try JSONSerialization.data(withJSONObject: operational)
    let operationalStore = try PersistenceStore(directory: environment.base.appendingPathComponent(
      "Processing/\(original.processingCacheRevision)"))
    let operationalKey = MovieFolderProcessor.processingStateKey(for: environment.root)
    do {
      let access = try #require(try operationalStore.acquireAccess(for: operationalKey))
      try access.write(operationalBytes)
    }
    let backups = try PersistenceStore(directory: environment.base.appendingPathComponent("Backups"))
    let migrator = MovieFolderStorageMigrator(configurationStore: settingsStore, collectionOutcomeStore: outcomeStore,
      backupStore: backups, operationalContainer: environment.base, processingLockStore: environment.coordination)
    #expect(try migrator.migrate().migratedRecordCount == 3)
    let current = try environment.configuration.read()
    #expect(current.credentialRevision == original.credentialRevision)
    #expect(current.processingCacheRevision == original.processingCacheRevision)
    #expect(current.networkHistoryConfigurationRevision == original.networkHistoryConfigurationRevision)
    #expect(current.directories == original.directories)
    #expect(current.movieMatchingConfiguration == original.movieMatchingConfiguration)
    #expect(!current.movieMatchingConfiguration.readsNFOInformation)
    #expect(!current.movieMatchingConfiguration.readsImmediateVideoNames)
    #expect(!current.movieMatchingConfiguration.readsImmediateImageNames)
    let migratedOutcome = try #require(try environment.processingStore.read(rootID: environment.context.rootID))
    #expect(migratedOutcome.folders == [oldFolder])
    #expect(migratedOutcome.revision == 17)
    for (kind, bytes) in [(MovieFolderStorageRecordKind.settings, settingsBytes),
      (.collectionOutcomes(environment.context.rootID), outcomeBytes),
      (.operationalProcessing(environment.context.rootID), operationalBytes)] {
      let access = try #require(try backups.acquireAccess(for:
        MovieFolderStorageMigrator.backupRecordKey(for: kind, originalPayload: bytes)))
      #expect(try access.read() == bytes)
    }
    do {
      let access = try #require(try operationalStore.acquireAccess(for: operationalKey))
      let cache = try JSONDecoder().decode(CollectionProcessingCache.self, from: #require(try access.read()))
      #expect(cache.folders["Retained historical"]?.matchedMovieID == 999)
      #expect(cache.folders["Retained historical"]?.movieIdentitySource == .explicitSelection)
    }
    let processor = MovieFolderProcessor(persistence: operationalStore, provider: fixture.provider,
      cacheDirectory: environment.base.appendingPathComponent("Posters"), processingLockStore: environment.coordination,
      processingStore: environment.processingStore, credentialRevision: environment.context.credentialRevision)
    #expect(try await processor.process(root: environment.root, processingContext: environment.context).assigned == 1)
    try fixture.expectAssigned(source: .validatedIdentifier)
    #expect(await fixture.transport.queries.isEmpty)
  }
}

/// Extracts a complete legacy fixture object without weakening the production decoder.
private func r12004JSONObject(_ data: Data) throws -> [String: Any] {
  try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// Removes only the new opt-in fields to recreate the preceding supported schema accurately.
private func r12004PriorMatching(_ value: Any?) throws -> [String: Any] {
  var fields = try #require(value as? [String: Any])
  for name in ["readsNFOInformation", "readsImmediateVideoNames", "readsImmediateImageNames"] {
    fields.removeValue(forKey: name)
  }

  return fields
}

/// Reads real icon contents and its resource fork so preservation assertions cover the installed artwork.
private func r12004InstalledIconMaterial(at child: URL) throws -> Data {
  let icon = child.appendingPathComponent("Icon\r")
  var result = try Data(contentsOf: icon)
  let length = getxattr(icon.path, "com.apple.ResourceFork", nil, 0, 0, XATTR_NOFOLLOW)
  try #require(length >= 0 && length <= 4 * 1_024 * 1_024)
  var fork = Data(count: length)
  let count = fork.withUnsafeMutableBytes {
    getxattr(icon.path, "com.apple.ResourceFork", $0.baseAddress, length, 0, XATTR_NOFOLLOW)
  }
  #expect(count == length)
  result.append(fork)

  return result
}
