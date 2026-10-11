import Foundation
import ImageIO
import UniformTypeIdentifiers

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

public struct HTTPResponse: Sendable {
    public let data: Data
    public let statusCode: Int
    public let contentType: String?
    public let retryAfter: String?

    public init(data: Data, statusCode: Int, contentType: String?, retryAfter: String? = nil) {
        self.data = data
        self.statusCode = statusCode
        self.contentType = contentType
        self.retryAfter = retryAfter
    }
}

public struct MovieMetadata: Equatable, Sendable {
    public let id: Int
    public let title: String
    public let originalTitle: String
    public let releaseYear: Int?
    public let posterPath: String?

    public init(id: Int, title: String, originalTitle: String, releaseYear: Int?, posterPath: String?) {
        self.id = id
        self.title = title
        self.originalTitle = originalTitle
        self.releaseYear = releaseYear
        self.posterPath = posterPath
    }
}

public struct MovieSearchResult: Equatable, Sendable {
    public let movies: [MovieMetadata]
    public let hasMorePages: Bool

    public init(movies: [MovieMetadata], hasMorePages: Bool) {
        self.movies = movies
        self.hasMorePages = hasMorePages
    }
}

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

public struct TMDbAccessToken: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private let value: String

    public init(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TMDbError.missingToken }
        guard !value.unicodeScalars.contains(where: { scalar in
            scalar == "\r" || scalar == "\n"
        }) else { throw TMDbError.missingToken }
        self.value = trimmed
    }

    fileprivate var authorizationValue: String { "Bearer \(value)" }
    public var description: String { "TMDbAccessToken(<redacted>)" }
    public var debugDescription: String { description }
}

public final class URLSessionTransport: HTTPTransport {
    private static let maximumResponseBytes = 10 * 1_024 * 1_024
    private let session: URLSession

    public convenience init() {
        self.init(configuration: Self.defaultConfiguration())
    }

    init(configuration: URLSessionConfiguration) {
        session = URLSession(configuration: configuration, delegate: RedirectBlocker(), delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    private static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        return configuration
    }

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
            return HTTPResponse(data: data, statusCode: http.statusCode,
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

private final class RedirectBlocker: NSObject, URLSessionTaskDelegate, Sendable {
    // This delegate is stateless; URLSession may call it concurrently without shared mutable state.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public struct TMDbClient: Sendable {
    private let token: TMDbAccessToken
    private let transport: any HTTPTransport
    private static let apiBase = URL(string: "https://api.themoviedb.org/3")!
    private static let maxResponseBytes = 10 * 1_024 * 1_024

    public init(token: TMDbAccessToken, transport: any HTTPTransport = URLSessionTransport()) {
        self.token = token
        self.transport = transport
    }

    public func searchMovies(title: String, year: Int?) async throws -> MovieSearchResult {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, !cleanTitle.contains("\r"), !cleanTitle.contains("\n"),
              year.map({ (1...9999).contains($0) }) ?? true else { throw TMDbError.invalidQuery }
        var components = URLComponents(url: Self.apiBase.appending(path: "search/movie"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "query", value: cleanTitle),
                                 URLQueryItem(name: "include_adult", value: "false"),
                                 URLQueryItem(name: "language", value: "en-US"),
                                 URLQueryItem(name: "page", value: "1")]
        if let year { components.queryItems?.append(URLQueryItem(name: "year", value: String(year))) }
        guard let url = components.url else { throw TMDbError.invalidQuery }
        var request = URLRequest(url: url)
        request.setValue(token.authorizationValue, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let response = try await send(request)
        try validateStatus(response)
        guard let type = response.contentType?.lowercased(), type.contains("json"),
              response.data.count <= Self.maxResponseBytes else { throw TMDbError.malformedResponse }
        do {
            let page = try JSONDecoder().decode(SearchPage.self, from: response.data)
            guard page.page == 1, page.totalPages >= 0,
                  page.totalPages != 0 || page.results.isEmpty else { throw TMDbError.malformedResponse }
            let movies = try page.results.map { item -> MovieMetadata in
                guard item.id > 0, !item.title.isEmpty, !item.originalTitle.isEmpty else {
                    throw TMDbError.malformedResponse
                }
                let date = try parseReleaseDate(item.releaseDate)
                return MovieMetadata(id: item.id, title: item.title, originalTitle: item.originalTitle,
                                     releaseYear: date?.year, posterPath: item.posterPath)
            }
            return MovieSearchResult(movies: movies, hasMorePages: page.totalPages > page.page)
        } catch let error as TMDbError {
            throw error
        } catch {
            throw TMDbError.malformedResponse
        }
    }

    public func downloadPoster(path: String) async throws -> Data {
        guard path.hasPrefix("/"), !path.hasPrefix("//"), path.count > 1,
              !path.contains(".."), !path.contains("%"), !path.contains("?"), !path.contains("#"),
              !path.dropFirst().contains("/") else { throw TMDbError.invalidPosterPath }
        let configRequest = authenticatedRequest(url: Self.apiBase.appending(path: "configuration"))
        let configResponse = try await send(configRequest)
        try validateStatus(configResponse)
        guard let type = configResponse.contentType?.lowercased(), type.contains("json") else {
            throw TMDbError.invalidConfiguration
        }
        let configuration: ImageConfiguration
        do { configuration = try JSONDecoder().decode(ImageConfiguration.self, from: configResponse.data) }
        catch { throw TMDbError.invalidConfiguration }
        guard let base = URL(string: configuration.images.secureBaseURL),
              let baseComponents = URLComponents(url: base, resolvingAgainstBaseURL: false),
              baseComponents.scheme == "https", baseComponents.host == "image.tmdb.org",
              baseComponents.user == nil, baseComponents.password == nil,
              baseComponents.port == nil || baseComponents.port == 443,
              baseComponents.path == "/t/p/", baseComponents.percentEncodedPath == "/t/p/",
              baseComponents.query == nil,
              baseComponents.fragment == nil,
              configuration.images.posterSizes.contains("w500") else { throw TMDbError.invalidConfiguration }
        guard let imageURL = URL(string: "https://image.tmdb.org/t/p/w500\(path)"),
              let imageComponents = URLComponents(url: imageURL, resolvingAgainstBaseURL: false),
              imageComponents.scheme == "https", imageComponents.host == "image.tmdb.org",
              imageComponents.user == nil, imageComponents.password == nil,
              imageComponents.port == nil, imageComponents.path.hasPrefix("/t/p/w500/"),
              imageComponents.query == nil, imageComponents.fragment == nil else {
            throw TMDbError.invalidConfiguration
        }
        var request = URLRequest(url: imageURL)
        request.setValue("image/jpeg,image/png", forHTTPHeaderField: "Accept")
        let response = try await send(request)
        try validateStatus(response)
        guard response.data.count <= Self.maxResponseBytes,
              let mime = response.contentType?.split(separator: ";").first?.lowercased(),
              ["image/jpeg", "image/png"].contains(String(mime)), isValidImage(response.data) else {
            throw TMDbError.invalidImage
        }
        return response.data
    }

    private func authenticatedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(token.authorizationValue, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

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

    private func validateStatus(_ response: HTTPResponse) throws {
        switch response.statusCode {
        case 200..<300: return
        case 401, 403: throw TMDbError.authentication
        case 429: throw TMDbError.rateLimited(retryAfter: response.retryAfter)
        default: throw TMDbError.httpStatus(response.statusCode)
        }
    }

    private func parseReleaseDate(_ value: String?) throws -> (year: Int, month: Int, day: Int)? {
        guard let value, !value.isEmpty else { return nil }
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...9999).contains(year) else { throw TMDbError.malformedResponse }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components), calendar.component(.year, from: date) == year,
              calendar.component(.month, from: date) == month,
              calendar.component(.day, from: date) == day else { throw TMDbError.malformedResponse }
        return (year, month, day)
    }

    private func isValidImage(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        let structurallyComplete = hasCompletePNG(bytes) || hasCompleteJPEG(bytes)
        guard structurallyComplete else { return false }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let type = CGImageSourceGetType(source) as String?,
              [UTType.jpeg.identifier, UTType.png.identifier].contains(type) else { return false }
        let options = [kCGImageSourceShouldCache: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, options),
              image.width > 0, image.height > 0 else { return false }
        return true
    }

    private func hasCompletePNG(_ bytes: [UInt8]) -> Bool {
        let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        guard bytes.starts(with: signature) else { return false }
        var offset = signature.count
        var sawHeader = false
        var sawImageData = false
        while offset + 12 <= bytes.count {
            let length = UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
                | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
            guard length <= UInt32(bytes.count - offset - 12) else { return false }
            let typeStart = offset + 4
            let dataStart = offset + 8
            let dataEnd = dataStart + Int(length)
            let crcEnd = dataEnd + 4
            let type = String(decoding: bytes[typeStart..<(typeStart + 4)], as: UTF8.self)
            guard pngCRC(bytes[typeStart..<dataEnd]) == readUInt32(bytes, at: dataEnd) else { return false }
            if !sawHeader {
                guard type == "IHDR", length == 13 else { return false }
                sawHeader = true
            } else if type == "IDAT" {
                sawImageData = sawImageData || length > 0
            } else if type == "IEND" {
                return length == 0 && sawImageData && crcEnd == bytes.count
            }
            offset = crcEnd
        }
        return false
    }

    private func hasCompleteJPEG(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 4 && bytes[0] == 0xff && bytes[1] == 0xd8
            && bytes[bytes.count - 2] == 0xff && bytes[bytes.count - 1] == 0xd9
    }

    private func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

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

private struct SearchPage: Decodable {
    let page: Int
    let totalPages: Int
    let results: [SearchItem]
    enum CodingKeys: String, CodingKey { case page, results; case totalPages = "total_pages" }
}

private struct SearchItem: Decodable {
    let id: Int
    let title: String
    let originalTitle: String
    let releaseDate: String?
    let posterPath: String?
    enum CodingKeys: String, CodingKey {
        case id, title
        case originalTitle = "original_title"
        case releaseDate = "release_date"
        case posterPath = "poster_path"
    }
}

private struct ImageConfiguration: Decodable {
    let images: Images
    struct Images: Decodable {
        let secureBaseURL: String
        let posterSizes: [String]
        enum CodingKeys: String, CodingKey {
            case secureBaseURL = "secure_base_url"
            case posterSizes = "poster_sizes"
        }
    }
}
