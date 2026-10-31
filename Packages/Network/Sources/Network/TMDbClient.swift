import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A validated TMDb read access token whose textual representations are redacted.
public struct TMDbAccessToken: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  /// The trimmed bearer token held only for authenticated requests.
  private let accessToken: String

  /// Validates and stores a token after trimming surrounding whitespace.
  ///
  /// - Parameter value: The bearer token. Line breaks and empty values are rejected.
  /// - Throws: ``TMDbError/missingToken`` when the value is empty or contains a line break.
  public init(_ value: String) throws {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw TMDbError.missingToken }
    guard
      !value.unicodeScalars.contains(where: { scalar in scalar == "\r" || scalar == "\n" })
    else { throw TMDbError.missingToken }
    self.accessToken = trimmed
  }

  /// Formats the bearer token for the Authorization header.
  fileprivate var bearerAuthorizationHeaderValue: String { "Bearer \(accessToken)" }
  /// A redacted description suitable for logs and diagnostics.
  public var description: String { "TMDbAccessToken(<redacted>)" }
  /// The same redacted value exposed by ``description``.
  public var debugDescription: String { description }
}

/// Searches TMDb and downloads validated poster images using a read access token.
public struct TMDbClient: Sendable {
  /// The token added to authenticated TMDb API requests.
  private let token: TMDbAccessToken
  /// The injected transport used for API and image requests.
  private let transport: any HTTPTransport
  /// The optional recorder retained for the lifetime of this client.
  private let requestDelegate: (any TMDbClientRequestDelegate)?
  /// The TMDb API root used to construct endpoint URLs.
  private static let apiBase = URL(string: "https://api.themoviedb.org/3")
  /// Maximum body size accepted from any TMDb endpoint.
  private static let maxResponseBytes = 10 * 1_024 * 1_024

  /// Creates a client using the supplied token and HTTP transport.
  ///
  /// - Parameters:
  ///   - token: The validated TMDb read access token.
  ///   - transport: The transport used for API requests.
  ///   - requestDelegate: An optional privacy-safe observer of dispatched requests.
  public init(
    token: TMDbAccessToken,
    transport: any HTTPTransport = URLSessionTransport(),
    requestDelegate: (any TMDbClientRequestDelegate)? = .none
  ) {
    self.token = token
    self.transport = transport
    self.requestDelegate = requestDelegate
  }

  /// Validates the configured token with TMDb's authentication endpoint.
  ///
  /// - Throws: ``TMDbError`` for rejected responses, transport failures, or cancellation.
  public func validateCredential() async throws {
    guard let apiBase = Self.apiBase else { throw TMDbError.invalidConfiguration }
    let request = authenticatedRequest(url: apiBase.appending(path: "authentication"))
    let response = try await send(request, purpose: .credentialValidation)
    try validateHTTPStatus(response)
    guard response.statusCode == 200 else { throw TMDbError.httpStatus(response.statusCode) }
    guard let contentType = response.contentType?.split(separator: ";").first?
      .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), contentType == "application/json"
    else { throw TMDbError.malformedResponse }
    do {
      let authentication = try JSONDecoder().decode(TMDbAuthenticationResponse.self, from: response.data)
      guard authentication.success else { throw TMDbError.malformedResponse }
    } catch let error as TMDbError {
      throw error
    } catch {
      throw TMDbError.malformedResponse
    }
  }

  /// Searches the first TMDb movie-result page by title and optional release year.
  ///
  /// - Parameters:
  ///   - title: The nonempty title query.
  ///   - year: An optional Gregorian year from 1 through 9999.
  ///   - language: Validated language sent unchanged as the single provider language parameter.
  /// - Returns: Validated movies and whether additional pages exist.
  /// - Throws: ``TMDbError`` for invalid input, rejected responses, or transport failures.
  public func searchMovies(title: String, year: Int?, language: TMDbLanguage = .english)
    async throws -> MovieSearchResult {
    let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanTitle.isEmpty, !cleanTitle.contains("\r"), !cleanTitle.contains("\n"),
      year.map({ (1...9999).contains($0) }) ?? true
    else { throw TMDbError.invalidQuery }
    guard let apiBase = Self.apiBase,
      var components = URLComponents(
        url: apiBase.appending(path: "search/movie"), resolvingAgainstBaseURL: false)
    else { throw TMDbError.invalidConfiguration }
    components.queryItems = [
      URLQueryItem(name: "query", value: cleanTitle),
      URLQueryItem(name: "include_adult", value: "false"),
      URLQueryItem(name: "language", value: language.rawValue),
      URLQueryItem(name: "page", value: "1")
    ]
    if let year { components.queryItems?.append(URLQueryItem(name: "year", value: String(year))) }
    guard let url = components.url else { throw TMDbError.invalidQuery }
    var request = URLRequest(url: url)
    request.setValue(token.bearerAuthorizationHeaderValue, forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let response = try await send(request, purpose: .movieSearch)
    try validateHTTPStatus(response)
    guard let type = response.contentType?.lowercased(), type.contains("json"),
      response.data.count <= Self.maxResponseBytes
    else { throw TMDbError.malformedResponse }
    do {
      let page = try JSONDecoder().decode(TMDbMovieSearchPage.self, from: response.data)
      guard page.page == 1, page.totalPages >= 0,
        page.totalPages != 0 || page.results.isEmpty
      else { throw TMDbError.malformedResponse }
      let movies = try page.results.map { item -> MovieMetadata in
        guard item.id > 0, !item.title.isEmpty, !item.originalTitle.isEmpty else {
          throw TMDbError.malformedResponse
        }
        let date = try parseReleaseDate(item.releaseDate)

        return MovieMetadata(
          id: item.id, title: item.title, originalTitle: item.originalTitle,
          releaseYear: date?.year, posterPath: item.posterPath)
      }
      return MovieSearchResult(movies: movies, hasMorePages: page.totalPages > page.page)
    } catch let error as TMDbError {
      throw error
    } catch {
      throw TMDbError.malformedResponse
    }
  }

  /// Retrieves complete alternative-title evidence for one positive movie identity.
  /// - Parameter movieID: The TMDb movie identity whose alternative titles are requested.
  /// - Returns: Exactly one dictionary entry, including a valid empty title list.
  /// - Throws: `TMDbError` for invalid input, mismatched identity, malformed evidence, or provider failure.
  public func alternativeTitles(movieID: Int) async throws -> MovieAlternativeTitlesByID {
    guard movieID > 0 else { throw TMDbError.invalidQuery }

    guard let base = Self.apiBase else { throw TMDbError.invalidConfiguration }

    let request = authenticatedRequest(url: base.appending(path: "movie/\(movieID)/alternative_titles"))
    let response = try await send(request, purpose: .alternativeTitles)
    try validateHTTPStatus(response)

    guard response.contentType?.split(separator: ";").first?
      .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "application/json" else {
      throw TMDbError.malformedResponse
    }

    do {
      let evidence = try JSONDecoder().decode(TMDbAlternativeTitleResponse.self, from: response.data)

      guard evidence.id == movieID, evidence.titles.allSatisfy({
        !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }) else { throw TMDbError.malformedResponse }

      return [movieID: evidence.titles.map {
        MovieAlternativeTitle(countryCode: $0.countryCode, title: $0.title, type: $0.type)
      }]
    } catch let error as TMDbError {
      throw error
    } catch {
      throw TMDbError.malformedResponse
    }
  }

  /// Downloads and validates the poster at a TMDb-relative poster path.
  ///
  /// - Parameter path: A single relative poster path beginning with `/`.
  /// - Returns: The validated image bytes.
  /// - Throws: ``TMDbError`` for invalid paths, image data, configuration, or requests.
  public func downloadPoster(path: String) async throws -> Data {
    guard path.hasPrefix("/"), !path.hasPrefix("//"), path.count > 1,
      !path.contains(".."), !path.contains("%"), !path.contains("?"), !path.contains("#"),
      !path.dropFirst().contains("/")
    else { throw TMDbError.invalidPosterPath }
    guard let apiBase = Self.apiBase else { throw TMDbError.invalidConfiguration }
    let configRequest = authenticatedRequest(url: apiBase.appending(path: "configuration"))
    let configResponse = try await send(configRequest, purpose: .posterConfiguration)
    try validateHTTPStatus(configResponse)
    guard let type = configResponse.contentType?.lowercased(), type.contains("json") else {
      throw TMDbError.invalidConfiguration
    }
    let configuration: TMDbPosterImageConfiguration
    do {
      configuration = try JSONDecoder().decode(TMDbPosterImageConfiguration.self, from: configResponse.data)
    } catch { throw TMDbError.invalidConfiguration }
    guard let base = URL(string: configuration.images.secureBaseURL),
      let baseComponents = URLComponents(url: base, resolvingAgainstBaseURL: false),
      baseComponents.scheme == "https", baseComponents.host == "image.tmdb.org",
      baseComponents.user == .none, baseComponents.password == .none,
      baseComponents.port == .none || baseComponents.port == 443,
      baseComponents.path == "/t/p/", baseComponents.percentEncodedPath == "/t/p/",
      baseComponents.query == .none,
      baseComponents.fragment == .none,
      configuration.images.posterSizes.contains("w500")
    else { throw TMDbError.invalidConfiguration }
    guard let imageURL = URL(string: "https://image.tmdb.org/t/p/w500\(path)"),
      let imageComponents = URLComponents(url: imageURL, resolvingAgainstBaseURL: false),
      imageComponents.scheme == "https", imageComponents.host == "image.tmdb.org",
      imageComponents.user == .none, imageComponents.password == .none,
      imageComponents.port == .none, imageComponents.path.hasPrefix("/t/p/w500/"),
      imageComponents.query == .none, imageComponents.fragment == .none
    else {
      throw TMDbError.invalidConfiguration
    }
    var request = URLRequest(url: imageURL)
    request.setValue("image/jpeg,image/png", forHTTPHeaderField: "Accept")
    let response = try await send(request, purpose: .posterDownload)
    try validateHTTPStatus(response)
    guard response.data.count <= Self.maxResponseBytes,
      let mime = response.contentType?.split(separator: ";").first?.lowercased(),
      ["image/jpeg", "image/png"].contains(String(mime)), isValidImage(response.data)
    else {
      throw TMDbError.invalidImage
    }

    return response.data
  }

  /// Builds an authenticated JSON request for a TMDb API endpoint.
  private func authenticatedRequest(url: URL) -> URLRequest {
    var request = URLRequest(url: url)
    request.setValue(token.bearerAuthorizationHeaderValue, forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    return request
  }

  /// Sends one bounded request while preserving cancellation and normalizing transport errors.
  private func send(_ request: URLRequest, purpose: TMDbRequestCategory) async throws -> HTTPTransportResponse {
    try Task.checkCancellation()

    let recordingTicket = await requestDelegate?.tmdbClientWillSendRequest(purpose: purpose)
    try Task.checkCancellation()

    do {
      let response = try await transport.send(request)
      try Task.checkCancellation()
      guard response.data.count <= Self.maxResponseBytes else { throw TMDbError.responseTooLarge }
      await completeRequest(
        purpose: purpose, result: .response(statusCode: response.statusCode),
        recordingTicket: recordingTicket)

      return response
    } catch is CancellationError {
      await completeRequest(purpose: purpose, result: .cancelled, recordingTicket: recordingTicket)
      throw CancellationError()
    } catch let error as URLError where error.code == .cancelled {
      await completeRequest(purpose: purpose, result: .cancelled, recordingTicket: recordingTicket)
      throw CancellationError()
    } catch let error as TMDbError where error == .responseTooLarge {
      await completeRequest(
        purpose: purpose, result: .responseTooLarge, recordingTicket: recordingTicket)
      throw error
    } catch let error as TMDbError {
      await completeRequest(
        purpose: purpose, result: .transportFailure, recordingTicket: recordingTicket)
      throw error
    } catch {
      await completeRequest(
        purpose: purpose, result: .transportFailure, recordingTicket: recordingTicket)
      throw TMDbError.transport(code: (error as NSError).code)
    }
  }

  /// Completes one ticketed request without exposing transport errors or request data.
  private func completeRequest(
    purpose: TMDbRequestCategory,
    result: TMDbRequestCompletionResult,
    recordingTicket: UUID?
  ) async {
    guard let recordingTicket else { return }

    await requestDelegate?.tmdbClientDidCompleteRequest(
      purpose: purpose, result: result, completedAt: Date(), recordingTicket: recordingTicket)
  }

  /// Maps HTTP status codes to the client's stable error cases.
  private func validateHTTPStatus(_ response: HTTPTransportResponse) throws {
    switch response.statusCode {
    case 200..<300: return
    case 401, 403: throw TMDbError.authentication
    case 429: throw TMDbError.rateLimited(retryAfter: response.retryAfter)
    default: throw TMDbError.httpStatus(response.statusCode)
    }
  }

  /// Parses and validates an ISO-style Gregorian release date returned by TMDb.
  private func parseReleaseDate(_ value: String?) throws -> (year: Int, month: Int, day: Int)? {
    guard let value, !value.isEmpty else { return .none }
    let parts = value.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
      let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
      (1...9999).contains(year)
    else { throw TMDbError.malformedResponse }
    var calendar = Calendar(identifier: .gregorian)
    guard let timeZone = TimeZone(secondsFromGMT: 0) else { throw TMDbError.malformedResponse }
    calendar.timeZone = timeZone
    var components = DateComponents()
    components.calendar = calendar
    components.timeZone = calendar.timeZone
    components.year = year
    components.month = month
    components.day = day
    guard let date = calendar.date(from: components), calendar.component(.year, from: date) == year,
      calendar.component(.month, from: date) == month,
      calendar.component(.day, from: date) == day
    else { throw TMDbError.malformedResponse }

    return (year, month, day)
  }

  /// Validates the image container, decoder status, type, and bounded thumbnail decoding.
  private func isValidImage(_ data: Data) -> Bool {
    let bytes = [UInt8](data)
    let structurallyComplete = hasCompletePNG(bytes) || hasCompleteJPEG(bytes)
    guard structurallyComplete else { return false }
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceGetCount(source) == 1,
      CGImageSourceGetStatus(source) == .statusComplete,
      CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
      let type = CGImageSourceGetType(source) as String?,
      [UTType.jpeg.identifier, UTType.png.identifier].contains(type)
    else { return false }
    let options =
      [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 512,
        kCGImageSourceShouldCache: false
      ] as CFDictionary
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options),
      image.width > 0, image.height > 0
    else { return false }

    return true
  }

  /// Confirms PNG chunks are complete and include a header, image data, and end marker.
  private func hasCompletePNG(_ bytes: [UInt8]) -> Bool {
    let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
    guard bytes.starts(with: signature) else { return false }
    var offset = signature.count
    var sawHeader = false
    var sawImageData = false
    while offset + 12 <= bytes.count {
      let length =
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
        | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
      guard length <= UInt32(bytes.count - offset - 12) else { return false }
      let typeStart = offset + 4
      let dataStart = offset + 8
      let dataEnd = dataStart + Int(length)
      let crcEnd = dataEnd + 4
      let type = bytes[typeStart..<(typeStart + 4)]
      guard pngCRC(bytes[typeStart..<dataEnd]) == readUInt32(bytes, at: dataEnd) else {
        return false
      }
      if !sawHeader {
        guard type.elementsEqual("IHDR".utf8), length == 13 else { return false }
        sawHeader = true
      } else if type.elementsEqual("IDAT".utf8) {
        sawImageData = sawImageData || length > 0
      } else if type.elementsEqual("IEND".utf8) {
        return length == 0 && sawImageData && crcEnd == bytes.count
      }
      offset = crcEnd
    }

    return false
  }

  /// Checks that the JPEG stream has its start and end markers.
  private func hasCompleteJPEG(_ bytes: [UInt8]) -> Bool {
    bytes.count >= 4 && bytes[0] == 0xff && bytes[1] == 0xd8
      && bytes[bytes.count - 2] == 0xff && bytes[bytes.count - 1] == 0xd9
  }

  /// Reads one big-endian 32-bit integer from a previously bounds-checked offset.
  private func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
    UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
      | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
  }

  /// Computes the PNG CRC-32 checksum for a chunk type and payload.
  private func pngCRC(_ bytes: ArraySlice<UInt8>) -> UInt32 {
    var crc: UInt32 = 0xffff_ffff
    for byte in bytes {
      crc ^= UInt32(byte)
      for _ in 0..<8 {
        crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1
      }
    }

    return crc ^ 0xffff_ffff
  }
}

/// The page-level response shape used for TMDb movie search.
private struct TMDbMovieSearchPage: Decodable {
  /// The page number returned by TMDb.
  let page: Int
  /// The total number of result pages reported by TMDb.
  let totalPages: Int
  /// Movie records on this page.
  let results: [TMDbMovieSearchRecord]
  /// Maps the API pagination key to Swift naming.
  enum CodingKeys: String, CodingKey {
    case page, results
    case totalPages = "total_pages"
  }
}

/// Minimal response contract for TMDb's credential authentication endpoint.
private struct TMDbAuthenticationResponse: Decodable {
  /// Whether TMDb accepted the supplied credential.
  let success: Bool
}

/// The subset of a TMDb search result used by the application.
private struct TMDbMovieSearchRecord: Decodable {
  /// The TMDb movie identifier.
  let id: Int
  /// The localized title.
  let title: String
  /// The original-language title.
  let originalTitle: String
  /// The unparsed release date supplied by TMDb.
  let releaseDate: String?
  /// The relative poster path, when available.
  let posterPath: String?
  /// Maps TMDb's snake-case fields to Swift properties.
  enum CodingKeys: String, CodingKey {
    case id, title
    case originalTitle = "original_title"
    case releaseDate = "release_date"
    case posterPath = "poster_path"
  }
}

/// The subset of TMDb image configuration needed to validate poster URLs.
private struct TMDbPosterImageConfiguration: Decodable {
  /// Image host and available size configuration returned by TMDb.
  let images: Images
  /// The validated fields required to construct a poster URL.
  struct Images: Decodable {
    /// The HTTPS base URL for TMDb images.
    let secureBaseURL: String
    /// Image-size codes enabled by the image service.
    let posterSizes: [String]
    /// Maps TMDb's snake-case fields to Swift properties.
    enum CodingKeys: String, CodingKey {
      case secureBaseURL = "secure_base_url"
      case posterSizes = "poster_sizes"
    }
  }
}

/// Private TMDb transport envelope; public evidence remains keyed by provider identity.
private struct TMDbAlternativeTitleResponse: Decodable {
  /// Returned movie identity, checked against the requested identity before use.
  let id: Int
  /// All provider title records, including an empty completed result.
  let titles: [Title]

  /// One transport title with TMDb's country-key spelling.
  struct Title: Decodable {
    /// Country provenance returned by TMDb.
    let countryCode: String
    /// Full alternative title.
    let title: String
    /// Provider classification.
    let type: String
    /// Maps only the transport-specific country name.
    enum CodingKeys: String, CodingKey { case countryCode = "iso_3166_1", title, type }
  }
}

/// Provider transport envelope, validated before dated events become public evidence.
private struct TMDbReleaseDateResponse: Decodable {
  /// Identity checked against the requested movie.
  let id: Int
  /// Complete country groups returned for the movie.
  let results: [Country]

  /// Country provenance and all its dated releases.
  struct Country: Decodable {
    /// Two-letter country code.
    let countryCode: String
    /// Raw events requiring calendar and type validation.
    let releaseDates: [Event]
    /// TMDb transport field mappings.
    enum CodingKeys: String, CodingKey { case countryCode = "iso_3166_1", releaseDates = "release_dates" }
  }

  /// Raw event timestamp and provider type.
  struct Event: Decodable {
    /// Original ISO timestamp.
    let releaseDate: String
    /// Positive provider type.
    let type: Int
    /// TMDb timestamp field mapping.
    enum CodingKeys: String, CodingKey { case releaseDate = "release_date", type }
  }
}

extension TMDbClient {
  /// Retrieves complete dated release evidence for one positive provider identity.
  /// - Parameter movieID: The requested TMDb identity.
  /// - Returns: Exactly one keyed entry, including a valid completed empty event list.
  /// - Throws: `TMDbError` for invalid input, malformed evidence, provider failures, or cancellation.
  public func releaseDates(movieID: Int) async throws -> MovieReleaseDatesByID {
    guard movieID > 0 else { throw TMDbError.invalidQuery }

    guard let base = Self.apiBase else { throw TMDbError.invalidConfiguration }

    let request = authenticatedRequest(url: base.appending(path: "movie/\(movieID)/release_dates"))
    let response = try await send(request, purpose: .releaseDates)
    try validateHTTPStatus(response)

    guard response.contentType?.split(separator: ";").first?
      .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "application/json" else {
      throw TMDbError.malformedResponse
    }

    do {
      let evidence = try JSONDecoder().decode(TMDbReleaseDateResponse.self, from: response.data)

      guard evidence.id == movieID else { throw TMDbError.malformedResponse }

      var dates = [MovieReleaseDate]()
      for country in evidence.results {
        guard MovieReleaseDate.isValidCountryCode(country.countryCode) else { throw TMDbError.malformedResponse }

        for event in country.releaseDates {
          dates.append(try MovieReleaseDate(countryCode: country.countryCode,
            timestamp: event.releaseDate, type: event.type))
        }
      }

      return [movieID: dates]
    } catch let error as TMDbError {
      throw error
    } catch {
      throw TMDbError.malformedResponse
    }
  }
}
