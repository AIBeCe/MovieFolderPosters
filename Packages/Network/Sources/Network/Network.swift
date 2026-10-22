import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Sends an HTTP request and returns its response without imposing a transport implementation.
public protocol HTTPTransport: Sendable {
  /// Sends one request, propagating cancellation and transport failures to the caller.
  ///
  /// - Parameter request: The request to send.
  /// - Returns: The response body and selected HTTP metadata.
  /// - Throws: A transport-specific error, including cancellation.
  func send(_ request: URLRequest) async throws -> HTTPResponse
}

/// The response data and HTTP metadata needed by the TMDb client.
public struct HTTPResponse: Sendable {
  /// The response body, limited by the transport's configured maximum size.
  public let data: Data
  /// The HTTP status code returned by the server.
  public let statusCode: Int
  /// The response's content type, if the server supplied one.
  public let contentType: String?
  /// The server's retry delay header, if supplied.
  public let retryAfter: String?

  /// Creates a response value from the body and relevant HTTP headers.
  ///
  /// - Parameters:
  ///   - data: The response body.
  ///   - statusCode: The HTTP status code.
  ///   - contentType: The response content type, when available.
  ///   - retryAfter: The server-provided retry delay, when available.
  public init(data: Data, statusCode: Int, contentType: String?, retryAfter: String? = .none) {
    self.data = data
    self.statusCode = statusCode
    self.contentType = contentType
    self.retryAfter = retryAfter
  }
}

/// Movie fields returned from a TMDb search result.
public struct MovieMetadata: Equatable, Sendable {
  /// The TMDb movie identifier.
  public let id: Int
  /// The localized movie title.
  public let title: String
  /// The movie's original-language title.
  public let originalTitle: String
  /// The release year, when the release date is available and valid.
  public let releaseYear: Int?
  /// The relative TMDb poster path, when the movie has a poster.
  public let posterPath: String?

  /// Creates movie metadata using values decoded from a search result.
  ///
  /// - Parameters:
  ///   - id: The TMDb identifier.
  ///   - title: The localized title.
  ///   - originalTitle: The original-language title.
  ///   - releaseYear: The release year, if known.
  ///   - posterPath: The relative poster path, if available.
  public init(id: Int, title: String, originalTitle: String, releaseYear: Int?, posterPath: String?) {
    self.id = id
    self.title = title
    self.originalTitle = originalTitle
    self.releaseYear = releaseYear
    self.posterPath = posterPath
  }
}

/// Movies returned from the first page of a TMDb search.
public struct MovieSearchResult: Equatable, Sendable {
  /// The validated movie results in server order.
  public let movies: [MovieMetadata]
  /// Whether TMDb reports additional result pages.
  public let hasMorePages: Bool

  /// Creates a search result with its movies and pagination state.
  public init(movies: [MovieMetadata], hasMorePages: Bool) {
    self.movies = movies
    self.hasMorePages = hasMorePages
  }
}

/// Failures reported while validating or communicating with TMDb.
public enum TMDbError: Error, Equatable, Sendable, CustomStringConvertible {
  case missingToken
  case invalidQuery
  case authentication
  case rateLimited(retryAfter: String?)
  case httpStatus(Int)
  case malformedResponse
  case invalidPosterPath
  case invalidImage
  case invalidConfiguration
  case responseTooLarge
  case transport(code: Int)

  /// A user-safe diagnostic description without credential or response-body data.
  public var description: String {
    switch self {
    case .missingToken: "A TMDb access token is required."
    case .invalidQuery: "The movie search query is invalid."
    case .authentication: "TMDb authentication failed."
    case .rateLimited: "TMDb rate limited the request."
    case .httpStatus(let status): "TMDb returned HTTP status \(status)."
    case .malformedResponse: "TMDb returned a malformed response."
    case .invalidPosterPath: "The poster path is invalid."
    case .invalidImage: "The poster image is invalid or unsupported."
    case .invalidConfiguration: "TMDb image configuration is invalid."
    case .responseTooLarge: "The response exceeds the allowed size."
    case .transport(let code): "The network request failed (code \(code))."
    }
  }
}

/// A validated TMDb read access token whose textual representations are redacted.
public struct TMDbAccessToken: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  /// The trimmed bearer token held only for authenticated requests.
  private let value: String

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
    self.value = trimmed
  }

  /// Formats the bearer token for the Authorization header.
  fileprivate var authorizationValue: String { "Bearer \(value)" }
  /// A redacted description suitable for logs and diagnostics.
  public var description: String { "TMDbAccessToken(<redacted>)" }
  /// The same redacted value exposed by ``description``.
  public var debugDescription: String { description }
}

/// URLSession-backed transport with bounded response reads and redirect blocking.
public final class URLSessionTransport: HTTPTransport {
  /// Maximum number of response bytes accepted from URLSession.
  private static let maximumResponseBytes = 10 * 1_024 * 1_024
  /// The ephemeral session used to perform requests.
  private let session: URLSession

  /// Creates an ephemeral transport with caching and cookies disabled.
  public convenience init() {
    self.init(configuration: Self.defaultConfiguration())
  }

  /// Creates a transport using an injected URLSession configuration.
  init(configuration: URLSessionConfiguration) {
    session = URLSession(
      configuration: configuration, delegate: RedirectBlocker(), delegateQueue: .none)
  }

  /// Invalidates outstanding work and releases the underlying session.
  deinit {
    session.invalidateAndCancel()
  }

  /// Builds the cookie-free, cache-free default transport configuration.
  private static func defaultConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = .none
    configuration.httpShouldSetCookies = false
    configuration.urlCache = .none
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 20
    configuration.timeoutIntervalForResource = 45

    return configuration
  }

  /// Sends a request, bounding response size and translating URL loading failures.
  ///
  /// - Parameter request: The request to send.
  /// - Returns: The response body and HTTP metadata.
  /// - Throws: ``TMDbError`` for transport and response-limit failures, or cancellation.
  public func send(_ request: URLRequest) async throws -> HTTPResponse {
    do {
      let (bytes, response) = try await session.bytes(for: request)
      defer { bytes.task.cancel() }
      try Task.checkCancellation()
      guard let http = response as? HTTPURLResponse else { throw TMDbError.malformedResponse }
      if http.expectedContentLength > Int64(Self.maximumResponseBytes) {
        throw TMDbError.responseTooLarge
      }
      var data = Data()
      for try await byte in bytes {
        try Task.checkCancellation()
        guard data.count < Self.maximumResponseBytes else { throw TMDbError.responseTooLarge }
        data.append(byte)
      }
      return HTTPResponse(
        data: data, statusCode: http.statusCode,
        contentType: http.value(forHTTPHeaderField: "Content-Type"),
        retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as TMDbError {
      throw error
    } catch let error as URLError where error.code == .cancelled {
      throw CancellationError()
    } catch let error as URLError {
      throw TMDbError.transport(code: error.code.rawValue)
    } catch {
      throw TMDbError.transport(code: (error as NSError).code)
    }
  }
}

/// Prevents URLSession from forwarding authenticated requests through redirects.
private final class RedirectBlocker: NSObject, URLSessionTaskDelegate, Sendable {
  // This delegate is stateless; URLSession may call it concurrently without shared mutable state.
  /// Cancels automatic redirects so credentials cannot be forwarded to another URL.
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(.none)
  }
}

/// Searches TMDb and downloads validated poster images using a read access token.
public struct TMDbClient: Sendable {
  /// The token added to authenticated TMDb API requests.
  private let token: TMDbAccessToken
  /// The injected transport used for API and image requests.
  private let transport: any HTTPTransport
  /// The TMDb API root used to construct endpoint URLs.
  private static let apiBase = URL(string: "https://api.themoviedb.org/3")
  /// Maximum body size accepted from any TMDb endpoint.
  private static let maxResponseBytes = 10 * 1_024 * 1_024

  /// Creates a client using the supplied token and HTTP transport.
  ///
  /// - Parameters:
  ///   - token: The validated TMDb read access token.
  ///   - transport: The transport used for API requests.
  public init(token: TMDbAccessToken, transport: any HTTPTransport = URLSessionTransport()) {
    self.token = token
    self.transport = transport
  }

  /// Validates the configured token with TMDb's authentication endpoint.
  ///
  /// - Throws: ``TMDbError`` for rejected responses, transport failures, or cancellation.
  public func validateCredential() async throws {
    guard let apiBase = Self.apiBase else { throw TMDbError.invalidConfiguration }
    let request = authenticatedRequest(url: apiBase.appending(path: "authentication"))
    let response = try await send(request)
    try validateStatus(response)
    guard response.statusCode == 200 else { throw TMDbError.httpStatus(response.statusCode) }
    guard let contentType = response.contentType?.split(separator: ";").first?
      .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), contentType == "application/json"
    else { throw TMDbError.malformedResponse }
    do {
      let authentication = try JSONDecoder().decode(AuthenticationResponse.self, from: response.data)
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
  /// - Returns: Validated movies and whether additional pages exist.
  /// - Throws: ``TMDbError`` for invalid input, rejected responses, or transport failures.
  public func searchMovies(title: String, year: Int?) async throws -> MovieSearchResult {
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
      URLQueryItem(name: "language", value: "en-US"),
      URLQueryItem(name: "page", value: "1")
    ]
    if let year { components.queryItems?.append(URLQueryItem(name: "year", value: String(year))) }
    guard let url = components.url else { throw TMDbError.invalidQuery }
    var request = URLRequest(url: url)
    request.setValue(token.authorizationValue, forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let response = try await send(request)
    try validateStatus(response)
    guard let type = response.contentType?.lowercased(), type.contains("json"),
      response.data.count <= Self.maxResponseBytes
    else { throw TMDbError.malformedResponse }
    do {
      let page = try JSONDecoder().decode(SearchPage.self, from: response.data)
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
    let configResponse = try await send(configRequest)
    try validateStatus(configResponse)
    guard let type = configResponse.contentType?.lowercased(), type.contains("json") else {
      throw TMDbError.invalidConfiguration
    }
    let configuration: ImageConfiguration
    do {
      configuration = try JSONDecoder().decode(ImageConfiguration.self, from: configResponse.data)
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
    let response = try await send(request)
    try validateStatus(response)
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
    request.setValue(token.authorizationValue, forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    return request
  }

  /// Sends one bounded request while preserving cancellation and normalizing transport errors.
  private func send(_ request: URLRequest) async throws -> HTTPResponse {
    try Task.checkCancellation()
    do {
      let response = try await transport.send(request)
      try Task.checkCancellation()
      guard response.data.count <= Self.maxResponseBytes else { throw TMDbError.responseTooLarge }
      return response
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as URLError where error.code == .cancelled {
      throw CancellationError()
    } catch let error as TMDbError {
      throw error
    } catch {
      throw TMDbError.transport(code: (error as NSError).code)
    }
  }

  /// Maps HTTP status codes to the client's stable error cases.
  private func validateStatus(_ response: HTTPResponse) throws {
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
private struct SearchPage: Decodable {
  /// The page number returned by TMDb.
  let page: Int
  /// The total number of result pages reported by TMDb.
  let totalPages: Int
  /// Movie records on this page.
  let results: [SearchItem]
  /// Maps the API pagination key to Swift naming.
  enum CodingKeys: String, CodingKey {
    case page, results
    case totalPages = "total_pages"
  }
}

/// Minimal response contract for TMDb's credential authentication endpoint.
private struct AuthenticationResponse: Decodable {
  /// Whether TMDb accepted the supplied credential.
  let success: Bool
}

/// The subset of a TMDb search result used by the application.
private struct SearchItem: Decodable {
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
private struct ImageConfiguration: Decodable {
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
