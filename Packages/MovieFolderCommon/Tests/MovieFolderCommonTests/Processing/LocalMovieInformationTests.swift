@testable import FileSystem
import Foundation
@testable import MovieFolderCommon
import Network
import Testing

/// NFO interpretation is movie-specific and accepts bounded labelled identifiers with title/year metadata.
@Test func nfoInformationParsesMovieMetadata() {
  let xml = "<movie><title>Alien</title><originaltitle>Alien</originaltitle><year>1979</year>"
    + #"<uniqueid type="tmdb">348</uniqueid><uniqueid type="imdb">tt0078748</uniqueid></movie>"#
  let result = NFOInformationParser().parse(Data(xml.utf8))
  #expect(result?.title == "Alien")
  #expect(result?.year == 1979)
  #expect(result?.identifiers == [.tmdb(348), .imdb("tt0078748")])
}

/// BOM-labelled Unicode XML receives the same DTD rejection before the parser can resolve anything.
@Test(arguments: [String.Encoding.utf16])
func nfoInformationUnicodeEncodingRetainsEntitySafety(encoding: String.Encoding) throws {
  let valid = try #require("<movie><title>Alien</title></movie>".data(using: encoding))
  #expect(NFOInformationParser().parse(valid)?.title == "Alien")
  let unsafe = try #require("<!DOCTYPE movie><movie><title>Alien</title></movie>".data(using: encoding))
  #expect(NFOInformationParser().parse(unsafe) == .none)
}

/// Unsafe, malformed and contradictory XML cannot provide partial automatic information.
@Test(arguments: [
  #"<!DOCTYPE movie><movie><title>Alien</title></movie>"#,
  #"<!DOCTYPE movie [<!ENTITY title "Alien">]><movie><title>&title;</title></movie>"#,
  #"<!DOCTYPE movie SYSTEM "https://example.invalid/movie.dtd"><movie/>"#,
  #"<tvshow><title>Alien</title></tvshow>"#, #"<movie><title>Alien</movie>"#,
  #"<movie><year>zero</year></movie>"#,
  #"<movie><uniqueid type="tmdb">0</uniqueid></movie>"#,
  #"<movie><uniqueid type="tmdb">348]junk</uniqueid></movie>"#,
  #"<movie><uniqueid type="imdb">tt0078748]junk</uniqueid></movie>"#,
  #"<movie><title>Alien</title><title>Dune</title></movie>"#
]) func nfoInformationRejectsUnsafeOrContradictoryXML(xml: String) {
  #expect(NFOInformationParser().parse(Data(xml.utf8)) == .none)
}

/// Enabled video names can establish identity while disabled sources leave the same unparseable folder unresolved.
@Test(arguments: [false, true], ["mkv", "jpg"])
func localInformationProcessingUsesOnlyEnabledImmediateNames(enabled: Bool, suffix: String) async throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  try fixture.addFolder("Unclear (2021) (2022)")
  try Data().write(to: fixture.movies.appendingPathComponent("Unclear (2021) (2022)/Dune (2021)." + suffix))
  let provider = CountingProvider()
  let processor = MovieFolderProcessor(persistence: fixture.persistence, provider: provider,
    cacheDirectory: fixture.cache, posterAssigner: fixture.assigner,
    movieMatchingConfiguration: MovieMatchingConfiguration(readsImmediateVideoNames: enabled && suffix == "mkv",
      readsImmediateImageNames: enabled && suffix == "jpg"))
  let summary = try await processor.process(root: fixture.movies)
  #expect(summary.assigned == (enabled ? 1 : 0))
  #expect(await provider.searchCount == (enabled ? 1 : 0))
}

/// A contradictory enabled NFO identity cannot be hidden by a valid labelled folder identity.
@Test func localInformationProcessingReconcilesFolderAndNFOIdentifiers() async throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  let name = "Dune [tmdb:42]"
  try fixture.addFolder(name)
  try Data(#"<movie><uniqueid type="tmdb">43</uniqueid></movie>"#.utf8)
    .write(to: fixture.movies.appendingPathComponent(name + "/movie.nfo"))
  let provider = CountingProvider()
  let processor = MovieFolderProcessor(persistence: fixture.persistence, provider: provider,
    cacheDirectory: fixture.cache, posterAssigner: fixture.assigner,
    movieMatchingConfiguration: MovieMatchingConfiguration(readsNFOInformation: true))
  let summary = try await processor.process(root: fixture.movies)
  #expect(summary.assigned == 0)
  #expect(summary.unresolved == 1)
  #expect(await provider.searchCount == 0)
  #expect(await provider.posterCount == 0)
}

/// Complete source ranking is independent of enumeration order; generic images contribute no identity.
@Test(arguments: [0, 1, 2, 3])
func localInformationResolverUsesApprovedTitlePrecedence(level: Int) throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  let folder = "Folder Movie (2000)"
  try fixture.addFolder(folder)
  let child = fixture.movies.appendingPathComponent(folder)
  if level == 0 {
    try Data("<movie><title>NFO Movie</title><year>1979</year></movie>".utf8)
      .write(to: child.appendingPathComponent("movie.nfo"))
  }
  if level <= 1 { try Data().write(to: child.appendingPathComponent("Video Movie (1980).mkv")) }
  if level <= 2 { try Data().write(to: child.appendingPathComponent("Image Movie (1981).jpg")) }
  try Data().write(to: child.appendingPathComponent("poster.png"))
  let service = FileSystemService()
  let readResult = try service.movieInformation(toChild: folder, in: fixture.movies,
    expectedIdentity: service.fileIdentity(at: child),
    options: .init(readsNFOInformation: true, readsImmediateVideoNames: true, readsImmediateImageNames: true))
  let result = LocalMovieInformationResolver().resolve(folderName: folder, readResult: readResult)

  guard case .title(let title, let year, _) = result else { Issue.record("Expected ranked title"); return }

  #expect(title == ["NFO Movie", "Video Movie", "Image Movie", "Folder Movie"][level])
  #expect(year == [1979, 1980, 1981, 2000][level])
}

/// Distinct equally ranked names block title fallback instead of selecting the first entry.
@Test func localInformationResolverRejectsConflictingVideoNames() throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  try fixture.addFolder("Folder Movie (2000)")
  let child = fixture.movies.appendingPathComponent("Folder Movie (2000)")
  for name in ["Alien (1979).mkv", "Dune (2021).mp4"] { try Data().write(to: child.appendingPathComponent(name)) }
  let service = FileSystemService()
  let readResult = try service.movieInformation(toChild: "Folder Movie (2000)", in: fixture.movies,
    expectedIdentity: service.fileIdentity(at: child), options: .init(readsImmediateVideoNames: true))

  guard case .conflicting = LocalMovieInformationResolver().resolve(
    folderName: "Folder Movie (2000)", readResult: readResult)
  else { Issue.record("Conflicting videos must block fallback"); return }
}

/// Opt-in NFO crosses real processing boundaries and assigns only downloaded provider artwork.
@Test func localInformationProcessingMatchesNFOWithoutUsingLocalArtwork() async throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  try fixture.addFolder("Unclear (2021) (2022)")
  let child = fixture.movies.appendingPathComponent("Unclear (2021) (2022)")
  try Data("<movie><title>Dune</title><year>2021</year></movie>".utf8)
    .write(to: child.appendingPathComponent("movie.nfo"))
  try Data("not an image".utf8).write(to: child.appendingPathComponent("poster.jpg"))
  let provider = CountingProvider()
  let processor = MovieFolderProcessor(persistence: fixture.persistence, provider: provider,
    cacheDirectory: fixture.cache, posterAssigner: fixture.assigner,
    movieMatchingConfiguration: MovieMatchingConfiguration(readsNFOInformation: true, readsImmediateImageNames: true))
  #expect(try await processor.process(root: fixture.movies).assigned == 1)
  #expect(await provider.posterCount == 1)
  #expect(fixture.assigner.assignmentCount == 1)
  #expect(try Data(contentsOf: child.appendingPathComponent("poster.jpg")) == Data("not an image".utf8))
}

/// Generic artwork and sample names cannot override the folder's movie information.
@Test(arguments: ["poster", "cover", "folder", "fanart", "sample", "trailer"])
func localInformationResolverIgnoresGenericNames(name: String) throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  try fixture.addFolder("Alien (1979)")
  let child = fixture.movies.appendingPathComponent("Alien (1979)")
  for suffix in ["jpg", "mkv"] { try Data().write(to: child.appendingPathComponent(name + "." + suffix)) }
  let service = FileSystemService()
  let readResult = try service.movieInformation(toChild: "Alien (1979)", in: fixture.movies,
    expectedIdentity: service.fileIdentity(at: child),
    options: .init(readsImmediateVideoNames: true, readsImmediateImageNames: true))

  guard case .title(let title, let year, .folderName) = LocalMovieInformationResolver()
    .resolve(folderName: "Alien (1979)", readResult: readResult) else {
    Issue.record("Generic names must leave folder fallback")
    return
  }

  #expect(title == "Alien")
  #expect(year == 1979)
}

/// Within-budget repeated labels collapse before any name-parser bound, preserving one consistent identity.
@Test(arguments: [false, true])
func localInformationResolverDeduplicatesIdentifiersAcrossManyFiles(conflicts: Bool) throws {
  let fixture = try Fixture()
  defer { try? FileManager.default.removeItem(at: fixture.base) }
  try fixture.addFolder("Movie")
  let child = fixture.movies.appendingPathComponent("Movie")
  for index in 0..<400 {
    try Data().write(to: child.appendingPathComponent("Movie \(index) [tmdb:348].mkv"))
  }
  if conflicts { try Data().write(to: child.appendingPathComponent("Conflict [tmdb:349].mkv")) }
  let service = FileSystemService()
  let readResult = try service.movieInformation(toChild: "Movie", in: fixture.movies,
    expectedIdentity: service.fileIdentity(at: child), options: .init(readsImmediateVideoNames: true))
  #expect(readResult.isComplete)
  let result = LocalMovieInformationResolver().resolve(folderName: "Movie", readResult: readResult)
  if conflicts {
    guard case .conflicting = result else { Issue.record("Conflicting ID must remain unresolved"); return }
  } else {
    guard case .identifiers(let identifiers) = result else { Issue.record("Expected unique repeated ID"); return }

    #expect(identifiers == [.tmdb(348)])
  }
}
