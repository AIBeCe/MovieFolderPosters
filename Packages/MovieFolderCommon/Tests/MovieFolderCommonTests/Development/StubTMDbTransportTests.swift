import Foundation
import MovieFolderCommon
import Network
import Testing

#if DEBUG
  /// Verifies that the packaged fixture transport exercises the real client without live requests.
  struct StubTMDbTransportTests {
    /// All supported fixture endpoints remain compatible with the metadata client's decoding and image checks.
    /// - Throws: Fixture resource, token validation, or client decoding errors.
    @Test func fixtureMovieAndPosterPassThroughRealClient() async throws {
      let image = try #require(Bundle.module.url(forResource: "TestPoster", withExtension: "png"))
      let poster = try Data(contentsOf: image)
      let client = TMDbClient(
        token: try TMDbAccessToken("fixture-token"),
        transport: StubTMDbTransport(posterData: poster))

      let search = try await client.searchMovies(title: "The Last Frame", year: 2026)
      #expect(search.movies == [
        MovieMetadata(
          id: 1, title: "The Last Frame", originalTitle: "The Last Frame",
          releaseYear: 2026, posterPath: "/test-poster.png")
      ])
      #expect(!search.hasMorePages)
      let downloaded = try await client.downloadPoster(path: "/test-poster.png")
      #expect(downloaded == poster)
    }

    /// Other movie titles remain unresolved instead of receiving the known fixture movie.
    /// - Throws: Token validation or client decoding errors.
    @Test func unmatchedTitleReturnsCompleteEmptySearch() async throws {
      let client = TMDbClient(
        token: try TMDbAccessToken("fixture-token"),
        transport: StubTMDbTransport(posterData: Data()))

      let search = try await client.searchMovies(title: "Another Movie", year: .none)
      #expect(search.movies.isEmpty)
      #expect(!search.hasMorePages)
    }

    /// Unsupported hosts and paths fail locally without falling back to a live transport.
    /// - Parameter address: An unsupported host or endpoint that must remain local to the fixture transport.
    /// - Throws: A fixture URL construction failure.
    @Test(arguments: [
      "https://example.invalid/3/search/movie",
      "https://api.themoviedb.org/3/unsupported",
      "https://image.tmdb.org/t/p/w500/unsupported.png"
    ])
    func unsupportedEndpointFailsLocally(address: String) async throws {
      let endpoint = try #require(URL(string: address))
      let transport: any HTTPTransport = StubTMDbTransport(posterData: Data())

      await #expect(throws: TMDbError.invalidConfiguration) { try await transport.send(URLRequest(url: endpoint)) }
    }

    /// Cancellation is checked before an otherwise supported fixture response is constructed.
    /// - Throws: A fixture URL construction failure.
    @Test func cancelledRequestDoesNotProduceFixtureResponse() async throws {
      let endpoint = try #require(URL(string: "https://api.themoviedb.org/3/configuration"))
      let transport: any HTTPTransport = StubTMDbTransport(posterData: Data())
      let request = Task {
        withUnsafeCurrentTask { $0?.cancel() }

        return try await transport.send(URLRequest(url: endpoint))
      }

      await #expect(throws: CancellationError.self) { try await request.value }
    }
  }
#endif
