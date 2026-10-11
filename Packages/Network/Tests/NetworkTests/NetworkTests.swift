import Foundation
import CoreGraphics
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Network

private actor ScriptedTransport: HTTPTransport {
    private var responses: [Result<HTTPResponse, Error>]
    private(set) var requests: [URLRequest] = []

    init(_ responses: [Result<HTTPResponse, Error>]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        return try responses.removeFirst().get()
    }

    func capturedRequests() -> [URLRequest] { requests }
}

private func response(_ json: String, status: Int = 200) -> HTTPResponse {
    HTTPResponse(data: Data(json.utf8), statusCode: status, contentType: "application/json")
}

private func validPNG() -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
    let image = context.makeImage()!
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    precondition(CGImageDestinationFinalize(destination))
    return data as Data
}

@Test func searchMapsExactTitleAndReportsAdditionalPages() async throws {
    let transport = ScriptedTransport([.success(response("""
    {"page":1,"total_pages":2,"results":[{"id":42,"title":"Alien","original_title":"Alien",
    "release_date":"1979-05-25","poster_path":"/alien.jpg"}]}
    """))])
    let client = try TMDbClient(token: TMDbAccessToken("secret-token"), transport: transport)

    let result = try await client.searchMovies(title: "Alien", year: 1979)
    let requests = await transport.capturedRequests()
    let components = try #require(URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false))
    let query = Dictionary(uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value ?? "") })

    #expect(result.movies == [MovieMetadata(id: 42, title: "Alien", originalTitle: "Alien",
                                              releaseYear: 1979, posterPath: "/alien.jpg")])
    #expect(result.hasMorePages)
    #expect(components.host == "api.themoviedb.org")
    #expect(query["query"] == "Alien")
    #expect(query["year"] == "1979")
    #expect(query["include_adult"] == "false")
    #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
}

@Test func noResultsIsEmptyAndNotMorePages() async throws {
    let transport = ScriptedTransport([.success(response("{\"page\":1,\"total_pages\":0,\"results\":[]}"))])
    let client = try TMDbClient(token: TMDbAccessToken("token"), transport: transport)
    let result = try await client.searchMovies(title: "missing", year: nil)
    #expect(result.movies.isEmpty)
    #expect(!result.hasMorePages)
}

@Test func accessTokenRejectsEmptyAndLineBreaksAndRedactsDescription() throws {
    #expect(throws: TMDbError.self) { try TMDbAccessToken("  ") }
    #expect(throws: TMDbError.self) { try TMDbAccessToken("x\r\nInjected: yes") }
    let token = try TMDbAccessToken("private-value")
    #expect(!String(describing: token).contains("private-value"))
}

@Test func unauthorizedStatusIsTypedAndDoesNotExposeBody() async throws {
    let transport = ScriptedTransport([.success(HTTPResponse(data: Data("secret-body".utf8), statusCode: 401,
                                                               contentType: "text/plain"))])
    let client = try TMDbClient(token: TMDbAccessToken("token"), transport: transport)
    await #expect(throws: TMDbError.authentication) {
        try await client.searchMovies(title: "Alien", year: nil)
    }
}

@Test(arguments: [401, 403])
func authFailuresAreTyped(status: Int) async throws {
    let transport = ScriptedTransport([.success(response("{}", status: status))])
    let client = try TMDbClient(token: TMDbAccessToken("token"), transport: transport)
    await #expect(throws: TMDbError.authentication) {
        try await client.searchMovies(title: "Alien", year: nil)
    }
}

@Test func rateLimitCarriesRetryAfterWithoutBody() async throws {
    let transport = ScriptedTransport([.success(HTTPResponse(
        data: Data("private response".utf8), statusCode: 429, contentType: "text/plain", retryAfter: "30"
    ))])
    let client = try TMDbClient(token: TMDbAccessToken("token"), transport: transport)
    await #expect(throws: TMDbError.rateLimited(retryAfter: "30")) {
        try await client.searchMovies(title: "Alien", year: nil)
    }
}

@Test(arguments: [400, 500, 503])
func otherHTTPFailuresPreserveStatus(status: Int) async throws {
    let transport = ScriptedTransport([.success(response("private body", status: status))])
    let client = try TMDbClient(token: TMDbAccessToken("token"), transport: transport)
    await #expect(throws: TMDbError.httpStatus(status)) {
        try await client.searchMovies(title: "Alien", year: nil)
    }
}

@Test func transportFailureIsRedactedAndTyped() async throws {
    let transport = ScriptedTransport([.failure(URLError(.notConnectedToInternet))])
    let client = try TMDbClient(token: TMDbAccessToken("token"), transport: transport)
    await #expect(throws: TMDbError.transport(code: URLError.notConnectedToInternet.rawValue)) {
        try await client.searchMovies(title: "Alien", year: nil)
    }
}

@Test func clientRejectsOversizedInjectedTransportResponse() async throws {
    let oversized = Data(repeating: 0x61, count: 10 * 1_024 * 1_024 + 1)
    let transport = ScriptedTransport([.success(HTTPResponse(data: oversized, statusCode: 200,
                                                               contentType: "application/json"))])
    let client = try TMDbClient(token: TMDbAccessToken("token"), transport: transport)
    await #expect(throws: TMDbError.responseTooLarge) {
        try await client.searchMovies(title: "Alien", year: nil)
    }
}

@Test(arguments: [
    "not-json",
    "{\"page\":1,\"total_pages\":1,\"results\":[{\"id\":0,\"title\":\"x\",\"original_title\":\"x\"}]}",
    """
    {"page":1,"total_pages":1,"results":[{"id":1,"title":"x","original_title":"x",
    "release_date":"2023-02-29"}]}
    """,
    """
    {"page":1,"total_pages":1,"results":[{"id":1,"title":"x","original_title":"x",
    "release_date":"2020-1-02"}]}
    """,
    "{\"page\":2,\"total_pages\":2,\"results\":[]}",
    "{\"page\":1,\"total_pages\":0,\"results\":[{\"id\":9,\"title\":\"x\",\"original_title\":\"x\"}]}"
])
func malformedSearchPayloadsAreRejected(json: String) async throws {
    let transport = ScriptedTransport([.success(response(json))])
    let client = try TMDbClient(token: TMDbAccessToken("token"), transport: transport)
    await #expect(throws: TMDbError.malformedResponse) {
        try await client.searchMovies(title: "Alien", year: nil)
    }
}

@Test func validUnknownDateMapsToNilAndNoAuthLeaksToPosterRequest() async throws {
    let configuration = HTTPResponse(data: Data("""
    {"images":{"secure_base_url":"https://image.tmdb.org/t/p/","poster_sizes":["w185","w500"]}}
    """.utf8), statusCode: 200, contentType: "application/json")
    let png = validPNG()
    let transport = ScriptedTransport([
        .success(response("""
        {"page":1,"total_pages":1,"results":[{"id":3,"title":"Unknown","original_title":"Unknown",
        "release_date":"","poster_path":"/p.png"}]}
        """)),
        .success(configuration),
        .success(HTTPResponse(data: png, statusCode: 200, contentType: "image/png"))
    ])
    let client = try TMDbClient(token: TMDbAccessToken("token"), transport: transport)
    let search = try await client.searchMovies(title: "Unknown", year: nil)
    #expect(search.movies.first?.releaseYear == nil)
    let downloaded = try await client.downloadPoster(path: "/p.png")
    #expect(downloaded == png)
    let requests = await transport.capturedRequests()
    #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer token")
    #expect(requests[2].url?.host == "image.tmdb.org")
    #expect(requests[2].value(forHTTPHeaderField: "Authorization") == nil)
}

@Test(arguments: ["", "p.png", "/../p.png", "/%2e%2e/p.png", "/p.png?x=1", "//evil.test/p.png", "/a/b.png"])
func unsafePosterPathsAreRejected(path: String) async throws {
    let transport = ScriptedTransport([])
    let client = try TMDbClient(token: TMDbAccessToken("token"), transport: transport)
    await #expect(throws: TMDbError.invalidPosterPath) { try await client.downloadPoster(path: path) }
    #expect(await transport.capturedRequests().isEmpty)
}

@Test func invalidPosterImageIsRejected() async throws {
    let configuration = HTTPResponse(data: Data("""
    {"images":{"secure_base_url":"https://image.tmdb.org/t/p/","poster_sizes":["w500"]}}
    """.utf8), statusCode: 200, contentType: "application/json")
    let transport = ScriptedTransport([
        .success(configuration),
        .success(HTTPResponse(data: Data("not image".utf8), statusCode: 200, contentType: "image/png"))
    ])
    let client = try TMDbClient(token: TMDbAccessToken("token"), transport: transport)
    await #expect(throws: TMDbError.invalidImage) { try await client.downloadPoster(path: "/p.png") }
}

@Test func truncatedPNGIsRejected() async throws {
    let configuration = HTTPResponse(data: Data("""
    {"images":{"secure_base_url":"https://image.tmdb.org/t/p/","poster_sizes":["w500"]}}
    """.utf8), statusCode: 200, contentType: "application/json")
    let valid = validPNG()
    let truncated = Data(valid.prefix(41))
    let transport = ScriptedTransport([
        .success(configuration),
        .success(HTTPResponse(data: truncated, statusCode: 200, contentType: "image/png"))
    ])
    let client = try TMDbClient(token: TMDbAccessToken("token"), transport: transport)
    await #expect(throws: TMDbError.invalidImage) { try await client.downloadPoster(path: "/p.png") }
}

@Test(arguments: [
    "https://evil.example/t/p/",
    "https://user:password@image.tmdb.org/t/p/",
    "https://image.tmdb.org:8443/t/p/",
    "https://image.tmdb.org/t/p/?x=y",
    "https://image.tmdb.org/t/p/#fragment"
])
func untrustedImageConfigurationIsRejected(baseURL: String) async throws {
    let json = """
    {"images":{"secure_base_url":"\(baseURL)","poster_sizes":["w500"]}}
    """
    let configuration = HTTPResponse(data: Data(json.utf8), statusCode: 200,
                                     contentType: "application/json")
    let transport = ScriptedTransport([.success(configuration)])
    let client = try TMDbClient(token: TMDbAccessToken("token"), transport: transport)
    await #expect(throws: TMDbError.invalidConfiguration) { try await client.downloadPoster(path: "/p.png") }
    #expect(await transport.capturedRequests().count == 1)
}

@Test func cancelledTaskIsCancelledBeforeSending() async throws {
    let transport = ScriptedTransport([])
    let client = try TMDbClient(token: TMDbAccessToken("token"), transport: transport)
    let task = Task { @Sendable in
        withUnsafeCurrentTask { $0?.cancel() }
        return try await client.searchMovies(title: "Alien", year: nil)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await transport.capturedRequests().isEmpty)
}

private actor BlockingTransport: HTTPTransport {
    private var responseContinuation: CheckedContinuation<HTTPResponse, Never>?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var hasStarted = false

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        await withCheckedContinuation { continuation in
            responseContinuation = continuation
            hasStarted = true
            startedContinuation?.resume()
            startedContinuation = nil
        }
    }

    func waitUntilStarted() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }

    func resume(with response: HTTPResponse) {
        responseContinuation?.resume(returning: response)
        responseContinuation = nil
    }
}

@Test func cancellationDuringTransportIsPropagatedAfterResponse() async throws {
    let transport = BlockingTransport()
    let client = try TMDbClient(token: TMDbAccessToken("token"), transport: transport)
    let task = Task { try await client.searchMovies(title: "Alien", year: nil) }
    await transport.waitUntilStarted()
    task.cancel()
    await transport.resume(with: response("{\"page\":1,\"total_pages\":0,\"results\":[]}"))
    await #expect(throws: CancellationError.self) { try await task.value }
}

private final class ControlledURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var paths: [String] = []
    nonisolated(unsafe) private static var stoppedPaths: [String] = []
    nonisolated(unsafe) private static var responseSignals: [String: DispatchSemaphore] = [:]
    nonisolated(unsafe) private static var stopSignals: [String: DispatchSemaphore] = [:]
    private static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "transport.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let path = url.path
        Self.lock.lock()
        Self.paths.append(path)
        Self.lock.unlock()

        let status = path == "/redirect" ? 302 : 200
        let headers = ["Content-Type": "application/json", "Retry-After": "12"]
            .merging(path == "/redirect" ? ["Location": "https://transport.test/followed"] : [:]) { _, new in new }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: headers)!
        if path == "/redirect" {
            let redirectedRequest = URLRequest(url: URL(string: "https://transport.test/followed")!)
            client?.urlProtocol(self, wasRedirectedTo: redirectedRequest, redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("redirect body".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        Self.responseSignal(path).signal()
        if path == "/hang" { return }
        if path == "/oversized" {
            client?.urlProtocol(self, didLoad: Data(repeating: 0x61, count: 10 * 1_024 * 1024 + 1))
            return
        }
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        guard let path = request.url?.path else { return }
        Self.lock.lock()
        Self.stoppedPaths.append(path)
        Self.lock.unlock()
        Self.stopSignal(path).signal()
    }

    static func recordedPaths() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }

    static func recordedStoppedPaths() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return stoppedPaths
    }

    static func waitForResponse(path: String) { responseSignal(path).wait() }
    static func waitForStop(path: String) { stopSignal(path).wait() }

    private static func responseSignal(_ path: String) -> DispatchSemaphore {
        lock.lock()
        defer { lock.unlock() }
        if let semaphore = responseSignals[path] { return semaphore }
        let semaphore = DispatchSemaphore(value: 0)
        responseSignals[path] = semaphore
        return semaphore
    }

    private static func stopSignal(_ path: String) -> DispatchSemaphore {
        lock.lock()
        defer { lock.unlock() }
        if let semaphore = stopSignals[path] { return semaphore }
        let semaphore = DispatchSemaphore(value: 0)
        stopSignals[path] = semaphore
        return semaphore
    }
}

private func controlledTransport() -> URLSessionTransport {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ControlledURLProtocol.self]
    return URLSessionTransport(configuration: configuration)
}

@Test func urlSessionTransportPreservesResponseHeaders() async throws {
    let transport = controlledTransport()
    let result = try await transport.send(URLRequest(url: URL(string: "https://transport.test/headers")!))
    #expect(result.statusCode == 200)
    #expect(result.contentType == "application/json")
    #expect(result.retryAfter == "12")
}

@Test func urlSessionTransportBoundsResponseAndStopsTask() async throws {
    let transport = controlledTransport()
    let request = URLRequest(url: URL(string: "https://transport.test/oversized")!)
    await #expect(throws: TMDbError.responseTooLarge) { try await transport.send(request) }
    ControlledURLProtocol.waitForStop(path: "/oversized")
    #expect(ControlledURLProtocol.recordedStoppedPaths().contains("/oversized"))
}

@Test func urlSessionTransportDoesNotFollowRedirects() async throws {
    let transport = controlledTransport()
    let request = URLRequest(url: URL(string: "https://transport.test/redirect")!)
    let response = try await transport.send(request)
    #expect(response.statusCode == 302)
    #expect(ControlledURLProtocol.recordedPaths().filter { $0 == "/followed" }.isEmpty)
}

@Test func urlSessionTransportCancelsAnInFlightRequest() async throws {
    let transport = controlledTransport()
    let request = URLRequest(url: URL(string: "https://transport.test/hang")!)
    let task = Task { try await transport.send(request) }
    ControlledURLProtocol.waitForResponse(path: "/hang")
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    ControlledURLProtocol.waitForStop(path: "/hang")
    #expect(ControlledURLProtocol.recordedStoppedPaths().contains("/hang"))
}
