import FileSystem
import Foundation
@_spi(Testing) import Network
import Persistence
import Testing

@testable import Common

/// Exercises R120-01 through automatic collection processing and its durable user-facing outcomes.
struct R12001MatchingAcceptanceTests {
  /// Given a Brazilian folder title and a verified TMDb alias, processing preserves that movie identity.
  @Test func verifiedInternationalAliasPersistsProviderMovieIdentity() async throws {
    let language = try MovieSearchLanguage("pt-BR")
    let fixture = try CollectionProcessingTestEnvironment(
      names: ["Coração Valente (1995)"],
      matchingConfiguration: MovieMatchingConfiguration(searchLanguage: language))
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let movie = MovieMetadata(
      id: 42, title: "Braveheart", originalTitle: "Braveheart", releaseYear: 1995, posterPath: .none)
    let evidence = MovieAlternativeTitle(countryCode: "BR", title: "Coração Valente", type: "")
    let transport = try R120AcceptanceTransport(movies: [movie], alternatives: [42: [evidence]])
    let provider = try NetworkClient(service: MovieNetworkService(
      token: "acceptance-fixture", testTransport: transport))

    _ = try await fixture.processor(provider: provider).process(
      root: fixture.root, processingContext: fixture.context)

    let state = try #require(try fixture.processingStore.read(rootID: fixture.context.rootID))
    let result = try #require(state.folders.first)
    #expect(result.matchedMovieID == 42)
    #expect(result.movieIdentitySource == .conservativeMatch)
    #expect(result.processingReason == .missingArtwork)
    #expect(await transport.searchLanguages == ["pt-BR"])
    #expect(await transport.requestedAliasIDs == [42])
  }

  /// Given direct and verified alias evidence for different IDs, the persisted result remains ambiguous.
  @Test func competingInternationalEvidencePersistsSeveralMatches() async throws {
    let fixture = try CollectionProcessingTestEnvironment(names: ["Coração Valente (1995)"])
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let search = MovieSearchResult(movies: [
      MovieMetadata(id: 42, title: "Coração Valente", originalTitle: "Braveheart", releaseYear: 1995,
        posterPath: .none),
      MovieMetadata(id: 43, title: "Other Film", originalTitle: "Other Film", releaseYear: 1995, posterPath: .none)
    ], hasMorePages: false)
    let alias = MovieAlternativeTitle(countryCode: "BR", title: "Coração Valente", type: "")
    let transport = try R120AcceptanceTransport(movies: search.movies, alternatives: [42: [], 43: [alias]])
    let provider = try NetworkClient(service: MovieNetworkService(
      token: "acceptance-fixture", testTransport: transport))

    _ = try await fixture.processor(provider: provider).process(
      root: fixture.root, processingContext: fixture.context)

    let state = try #require(try fixture.processingStore.read(rootID: fixture.context.rootID))
    let result = try #require(state.folders.first)
    #expect(result.processingState == .severalMatches)
    #expect(result.processingReason == .ambiguousMovie)
    #expect(result.matchedMovieID == .none)
    #expect(await transport.requestedAliasIDs == [42, 43])
  }

  /// Given five candidates, processing spends at most five alias requests; six candidates remain unresolved.
  @Test(arguments: [5, 6])
  func candidateBoundaryPersistsBoundedMatchingResult(candidateCount: Int) async throws {
    let fixture = try CollectionProcessingTestEnvironment(names: ["Unknown Title (1995)"])
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let movies = (1...candidateCount).map {
      MovieMetadata(id: $0, title: "Candidate \($0)", originalTitle: "Candidate \($0)", releaseYear: 1995,
        posterPath: .none)
    }
    let transport = try R120AcceptanceTransport(
      movies: movies, alternatives: Dictionary(uniqueKeysWithValues: movies.map { ($0.id, []) }))
    let provider = try NetworkClient(service: MovieNetworkService(
      token: "acceptance-fixture", testTransport: transport))

    _ = try await fixture.processor(provider: provider).process(
      root: fixture.root, processingContext: fixture.context)

    let state = try #require(try fixture.processingStore.read(rootID: fixture.context.rootID))
    let result = try #require(state.folders.first)
    if candidateCount == 5 {
      #expect(result.processingState == .notFound)
      #expect(await transport.requestedAliasIDs.count == 5)
    } else {
      #expect(result.processingState == .unresolved)
      #expect(result.processingReason == .manualMatchingRequired)
      #expect(await transport.requestedAliasIDs.isEmpty)
    }
  }
}

/// Deterministic HTTP fixture that exercises TMDb decoding, request language, and alias provenance.
private actor R120AcceptanceTransport: NetworkTestTransport {
  /// Encoded complete search result returned by the controlled API.
  private let searchResponse: Data
  /// Encoded alternative-title response for each configured provider identity.
  private let alternativeResponses: [Int: Data]
  /// Language query parameters observed by the transport.
  private(set) var searchLanguages = [String]()
  /// Candidate IDs whose alias evidence was requested.
  private(set) var requestedAliasIDs = [Int]()

  /// Encodes controlled provider responses without network or Keychain access.
  init(movies: [MovieMetadata], alternatives: MovieAlternativeTitlesByID) throws {
    let results = movies.map { movie in
      [
        "id": movie.id,
        "title": movie.title,
        "original_title": movie.originalTitle,
        "release_date": movie.releaseYear.map { "\($0)-01-01" } ?? "",
        "poster_path": movie.posterPath.map { $0 as Any } ?? NSNull()
      ] as [String: Any]
    }
    searchResponse = try JSONSerialization.data(withJSONObject: [
      "page": 1, "total_pages": 1, "results": results
    ])
    alternativeResponses = try Dictionary(uniqueKeysWithValues: alternatives.map { id, titles in
      let entries = titles.map { title in
        ["iso_3166_1": title.countryCode, "title": title.title, "type": title.type]
      }

      return (id, try JSONSerialization.data(withJSONObject: ["id": id, "titles": entries]))
    })
  }

  // swiftlint:disable:next async_without_await
  func send(_ request: URLRequest) async throws -> NetworkTestResponse {
    guard let url = request.url else { throw MovieMetadataError.invalidQuery }
    if url.path == "/3/search/movie" {
      let language = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
        .first { $0.name == "language" }?.value
      searchLanguages.append(language ?? "")

      return NetworkTestResponse(data: searchResponse, statusCode: 200, contentType: "application/json")
    }
    let components = url.path.split(separator: "/")
    if components.count == 4, components[0] == "3", components[1] == "movie",
      components[3] == "alternative_titles", let id = Int(components[2]) {
      requestedAliasIDs.append(id)
      let response: Data
      if let configured = alternativeResponses[id] {
        response = configured
      } else {
        response = try JSONSerialization.data(withJSONObject: ["id": id, "titles": []])
      }

      return NetworkTestResponse(data: response, statusCode: 200, contentType: "application/json")
    }

    throw MovieMetadataError.invalidConfiguration
  }
}

extension R12001MatchingAcceptanceTests {
  /// Given warm alias evidence, changing language or access token revision forces a fresh provider response.
  @Test func languageAndAccessTokenChangesDoNotReuseCachedAliasEvidence() async throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let movie = MovieMetadata(
      id: 42, title: "Alien", originalTitle: "Alien", releaseYear: 1979, posterPath: "/alien.jpg")
    let alias = MovieAlternativeTitle(countryCode: "BR", title: "Alien", type: "")
    let transport = try R120AcceptanceTransport(movies: [movie], alternatives: [42: [alias]])
    let provider = try NetworkClient(service: MovieNetworkService(
      token: "acceptance-fixture", testTransport: transport))
    let accessToken = UUID()
    let search = MovieSearchResult(movies: [movie], hasMorePages: false)
    let portuguese = MovieFolderProcessor(
      persistence: fixture.persistence, provider: provider, cacheDirectory: fixture.cache,
      credentialRevision: accessToken, movieMatchingConfiguration: MovieMatchingConfiguration(
        searchLanguage: try MovieSearchLanguage("pt-BR")))
    let german = MovieFolderProcessor(
      persistence: fixture.persistence, provider: provider, cacheDirectory: fixture.cache,
      credentialRevision: accessToken, movieMatchingConfiguration: MovieMatchingConfiguration(
        searchLanguage: try MovieSearchLanguage("de-DE")))
    let newAccessToken = MovieFolderProcessor(
      persistence: fixture.persistence, provider: provider, cacheDirectory: fixture.cache,
      credentialRevision: UUID(), movieMatchingConfiguration: MovieMatchingConfiguration(
        searchLanguage: try MovieSearchLanguage("de-DE")))
    var state = CollectionProcessingCache()

    let first = try await portuguese.fetchAlternativeTitlesAndReleaseDates(
      title: "Alien", year: 1979, search: search, state: &state)
    let second = try await german.fetchAlternativeTitlesAndReleaseDates(
      title: "Alien", year: 1979, search: search, state: &state)
    let third = try await newAccessToken.fetchAlternativeTitlesAndReleaseDates(title: "Alien",
      year: 1979, search: search, state: &state)

    #expect(first == .matched(movie))
    #expect(second == .matched(movie))
    #expect(third == .matched(movie))
    #expect(await transport.requestedAliasIDs == [42, 42, 42])
  }
}
