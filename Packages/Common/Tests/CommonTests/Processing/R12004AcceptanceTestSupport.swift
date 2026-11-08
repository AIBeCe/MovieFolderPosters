import Darwin
import FileSystem
import Foundation
@testable import Common
@_spi(Testing) import Network
import Persistence
import Synchronization
import Testing

/// Disposable configured collection exercising real processing, persistence, provider decoding and icon assignment.
struct R12004AcceptanceFixture {
  /// Existing real collection/settings/outcome fixture.
  let environment: CollectionProcessingTestEnvironment
  /// Deterministic HTTP boundary; never forwards a request to the network.
  let transport: R12004AcceptanceTransport
  /// Real authenticated TMDb client using only a fake fixture token.
  let provider: NetworkClient
  /// Selected immediate folder name.
  let name: String
  /// Disposable movie directory.
  var child: URL { environment.root.appendingPathComponent(name) }
  /// Real synchronous icon/ownership inspector.
  let fileSystem = FileSystemService()

  /// Builds isolated processing state; all files remain under a fresh temporary directory.
  init(
    name: String = "Unclear (2021) (2022)",
    matching: MovieMatchingConfiguration = MovieMatchingConfiguration(),
    mode: R12004AcceptanceTransport.Mode = .normal,
    hold: String? = .none
  ) throws {
    self.name = name
    environment = try CollectionProcessingTestEnvironment(names: [name], matchingConfiguration: matching)
    transport = R12004AcceptanceTransport(mode: mode, hold: hold)
    provider = try NetworkClient(service: MovieNetworkService(
      token: "R12004-fixture-not-a-real-access-token", testTransport: transport))
  }

  /// Constructs a new processor so durable behavior is tested across composition/reopen boundaries.
  func processor(verifier: (any MovieFolderProcessingVerifier)? = .none) -> MovieFolderProcessor {
    MovieFolderProcessor(persistence: environment.processing, provider: provider,
      cacheDirectory: environment.base.appendingPathComponent("Posters"),
      processingLockStore: environment.coordination, processingVerifier: verifier,
      processingStore: environment.processingStore, credentialRevision: environment.context.credentialRevision,
      movieMatchingConfiguration: environment.context.movieMatchingConfiguration)
  }

  /// Runs a complete authorized collection visit through the real processing boundary.
  func process() async throws -> ProcessingSummary {
    try await processor().process(root: environment.root, processingContext: environment.context)
  }

  /// Reads the durable user-facing result rather than an internal matching algorithm's return value.
  func outcome() throws -> FolderProcessingRecord {
    let state = try #require(try environment.processingStore.read(rootID: environment.context.rootID))

    return try #require(state.folders.first { $0.folderName == name })
  }

  /// Reads the persisted operational record for hash/privacy and recovery assertions.
  func operationalBytes() throws -> Data {
    let access = try #require(try environment.processing.acquireAccess(for:
      MovieFolderProcessor.processingStateKey(for: environment.root)))

    return try #require(try access.read())
  }

  /// Checks every persisted application namespace for source-only private XML information.
  func expectPrivateNFOAbsent(_ marker: String) throws {
    let operationalText = try #require(String(bytes: operationalBytes(), encoding: .utf8))
    #expect(!operationalText.contains(marker))
    for (directory, key) in [("Settings", ConfigurationRepository.recordKey),
      ("Outcomes", CollectionProcessingStore.processingStateKey(for: environment.context.rootID))] {
      let store = try PersistenceStore(directory: environment.base.appendingPathComponent(directory))
      let access = try #require(try store.acquireAccess(for: key))
      let bytes = try #require(try access.read())
      let text = try #require(String(bytes: bytes, encoding: .utf8))
      #expect(!text.contains(marker))
    }
  }

  /// Writes test inputs only into the disposable immediate movie directory.
  func write(_ name: String, contents: Data = Data()) throws {
    try contents.write(to: child.appendingPathComponent(name))
  }

  /// Supplies deterministic NFO title/year information, optionally padded to an exact approved byte boundary.
  func writeNFO(title: String = "Alien", year: Int = 1979, bytes: Int? = .none, name: String = "movie.nfo") throws {
    var contents = Data("<movie><title>\(title)</title><year>\(year)</year></movie>".utf8)
    if let bytes, bytes > contents.count { contents.append(Data(repeating: 32, count: bytes - contents.count)) }
    try write(name, contents: contents)
  }

  /// Checks the full user-visible successful result, including real persisted icon ownership.
  func expectAssigned(source: MovieIdentitySource, movieID: Int = 348) throws {
    let result = try outcome()
    #expect(result.isVerifiedDone)
    #expect(result.matchedMovieID == movieID)
    #expect(result.movieIdentitySource == source)
    let candidate = try #require(fileSystem.candidates(in: environment.root).first { $0.name == name })
    #expect(try fileSystem.hasAssignedPoster(toChild: name, in: environment.root,
      expectedIdentity: candidate.identity))
  }
}

/// Small loopback-only sentinel that observes resource connections and has an explicit bounded shutdown.
final class R12004XMLResourceSentinel: Sendable {
  /// Listening descriptor bound only to 127.0.0.1 and an OS-selected ephemeral port.
  private let descriptor: Int32
  /// Thread-safe lifetime and connection observations.
  private let state = Mutex((stopped: false, requests: 0))
  /// Signals complete worker termination before its descriptor can be reused.
  private let finished = DispatchSemaphore(value: 0)
  /// Malicious XML's controlled local resource URL.
  let url: URL
  /// Number of connections, including the explicit positive control.
  var requestCount: Int { state.withLock { $0.requests } }

  /// Starts a bounded local fixture without DNS, access tokens, or an external service.
  init() throws {
    let socketFD = socket(AF_INET, SOCK_STREAM, 0)
    try #require(socketFD >= 0)
    var initialized = false
    defer { if !initialized { close(socketFD) } }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = UInt32(INADDR_LOOPBACK).bigEndian
    let addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, addressLength) }
    }
    try #require(bound == 0, "Loopback bind failed with POSIX code \(errno)")
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let inspected = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) }
    }
    try #require(inspected == 0 && listen(socketFD, 4) == 0)
    try #require(fcntl(socketFD, F_SETFL, O_NONBLOCK) == 0)
    url = try #require(URL(string: "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))/external.dtd"))
    descriptor = socketFD
    initialized = true
    DispatchQueue.global().async { self.serve() }
  }

  /// Proves the same endpoint and observer actually receive a request before testing absence.
  func positiveControl(expectedCount: Int = 1) async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = .none
    configuration.urlCache = .none
    configuration.timeoutIntervalForRequest = 2
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let (_, response) = try await session.data(from: url)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    #expect(requestCount == expectedCount)
  }

  /// Waits at most two seconds for the bounded worker before closing its descriptor.
  func stop() {
    state.withLock { $0.stopped = true }
    let result = finished.wait(timeout: .now() + 2)
    #expect(result == .success)
    if result == .success { close(descriptor) }
  }

  /// Counts local resource connections and replies immediately; every blocking client operation is bounded.
  private func serve() {
    defer { finished.signal() }
    while !state.withLock({ $0.stopped }) {
      var pending = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
      if poll(&pending, 1, 10) <= 0 { continue }
      if state.withLock({ $0.stopped }) { return }
      let client = accept(descriptor, nil, nil)
      if client < 0 { continue }
      state.withLock { $0.requests += 1 }
      var timeout = timeval(tv_sec: 1, tv_usec: 0)
      var noSignal: Int32 = 1
      _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
      _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
      var bytes = [UInt8](repeating: 0, count: 4_096)
      _ = recv(client, &bytes, bytes.count, 0)
      let response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
      response.withCString { _ = send(client, $0, strlen($0), 0) }
      close(client)
    }
  }
}

/// Complete in-memory TMDb HTTP server with a controllable single request suspension boundary.
actor R12004AcceptanceTransport: NetworkTestTransport {
  /// Alternative endpoint behaviors used by negative provider acceptance scenarios.
  enum Mode: String, CaseIterable, Sendable {
    case normal, missing, nonmovie, ambiguous, malformed, mismatched, disagree
    case authentication, rateLimited, offline, emptySearch, unknownIsEmpty
  }
  /// Selected deterministic server behavior.
  private let mode: Mode
  /// Suffix of the first request to suspend, or no suspension.
  private let hold: String?
  /// Whether the selected suspension has already been consumed.
  private var heldOnce = false
  /// Suspended request, resumed only by its test owner.
  private var heldRequest: CheckedContinuation<Void, Never>?
  /// Observer waiting for the selected provider boundary.
  private var heldObserver: CheckedContinuation<Void, Never>?
  /// Safe request paths observed by this fixture server.
  private(set) var paths: [String] = []
  /// Queries observed at search boundaries, excluding the fake authorization header.
  private(set) var queries: [String] = []

  /// Configures an isolated server without creating URLSession or reading access tokens.
  init(mode: Mode = .normal, hold: String? = .none) {
    self.mode = mode
    self.hold = hold
  }

  /// Routes every fixture request locally, including real client poster-configuration/image decoding.
  func send(_ request: URLRequest) async throws -> NetworkTestResponse {
    let url = try #require(request.url)
    let path = url.path
    paths.append(path)
    await suspendRequestedPathIfNeeded(path)
    if path == "/t/p/w500/fixture.png" {
      let resource = try #require(Bundle.module.url(forResource: "TestPoster", withExtension: "png"))
      let png = try Data(contentsOf: resource)

      return NetworkTestResponse(data: png, statusCode: 200, contentType: "image/png")
    }
    if path == "/3/configuration" {
      return try json(["images": ["secure_base_url": "https://image.tmdb.org/t/p/", "poster_sizes": ["w500"]]])
    }
    if path.hasSuffix("alternative_titles") { return try json(["id": 348, "titles": []]) }
    if path.hasSuffix("release_dates") {
      return try json(["id": 348, "results": [["iso_3166_1": "US", "release_dates": [
        ["release_date": "1979-05-25T00:00:00.000Z", "type": 3],
        ["release_date": "1980-01-01T00:00:00.000Z", "type": 3]
      ]]]])
    }
    if path == "/3/search/movie" {
      let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
        .first { $0.name == "query" }?.value ?? ""
      queries.append(query)
      let results = mode == .emptySearch || (mode == .unknownIsEmpty && query == "Unknown")
        ? [] : [movie(title: query)]

      return try json(["page": 1, "total_pages": 1, "results": results])
    }
    if path.hasPrefix("/3/movie/") || path.hasPrefix("/3/find/") {
      switch mode {
      case .authentication: return NetworkTestResponse(data: Data(), statusCode: 401, contentType: "application/json")
      case .rateLimited:
        return NetworkTestResponse(data: Data(), statusCode: 429, contentType: "application/json", retryAfter: "60")
      case .offline: throw URLError(.notConnectedToInternet)
      case .malformed: return NetworkTestResponse(data: Data("bad-json".utf8), statusCode: 200,
        contentType: "application/json")
      default: break
      }
      if path.hasPrefix("/3/find/") {
        switch mode {
        case .missing: return try json(["movie_results": []])
        case .nonmovie: return try json(["movie_results": [], "tv_results": [["id": 348]]])
        case .ambiguous: return try json(["movie_results": [movie(), movie(id: 349)]])
        case .mismatched, .disagree: return try json(["movie_results": [movie(id: 349)]])
        default: return try json(["movie_results": [movie()]])
        }
      }
      return try json(movie(id: mode == .mismatched ? 349 : 348))
    }

    throw MovieMetadataError.invalidConfiguration
  }

  /// Suspends only the first selected path until its scenario permits the provider response to continue.
  private func suspendRequestedPathIfNeeded(_ path: String) async {
    guard let hold, path.hasSuffix(hold), !heldOnce else { return }

    heldOnce = true
    await withCheckedContinuation { continuation in
      heldRequest = continuation
      heldObserver?.resume()
      heldObserver = .none
    }
  }

  /// Waits for the selected request; the serialized acceptance suite has a bounded test time limit.
  func waitUntilHeld() async {
    if heldRequest != nil { return }
    await withCheckedContinuation { heldObserver = $0 }
  }

  /// Resumes only the one owned request, preserving cancellation for the real client to observe.
  func resume() {
    heldRequest?.resume()
    heldRequest = .none
  }

  /// Builds a complete provider movie record whose release year supports the acceptance fixtures.
  private func movie(id: Int = 348, title: String = "Alien") -> [String: Any] {
    ["id": id, "title": title, "original_title": title,
      "release_date": "1979-05-25", "poster_path": "/fixture.png"]
  }

  /// Encodes JSON exactly as the production TMDb client receives it.
  private func json(_ object: [String: Any]) throws -> NetworkTestResponse {
    NetworkTestResponse(data: try JSONSerialization.data(withJSONObject: object),
      statusCode: 200, contentType: "application/json")
  }
}
