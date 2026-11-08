import Foundation
import Testing

@testable import HTTPTransport

/// Makes a known-valid URL available to synchronous URLProtocol fixtures.
private func requiredURL(_ string: String) -> URL {
  guard let url = URL(string: string) else { preconditionFailure("Invalid test URL: \(string)") }

  return url
}

/// Provides deterministic URLSession responses and signals for transport behavior tests.
private final class ControlledURLProtocol: URLProtocol, @unchecked Sendable {
  /// Paths observed by URLSession during this test process.
  nonisolated(unsafe) private static var paths: [String] = []
  /// Paths for which URLSession called `stopLoading()`.
  nonisolated(unsafe) private static var stoppedPaths: [String] = []
  /// Semaphores signaling that a response reached the protocol for each path.
  nonisolated(unsafe) private static var responseSignals: [String: DispatchSemaphore] = [:]
  /// Semaphores signaling cancellation cleanup for each path.
  nonisolated(unsafe) private static var stopSignals: [String: DispatchSemaphore] = [:]
  /// Protects the protocol's shared test observations and signal maps.
  private static let lock = NSLock()

  /// Handles only requests sent to the transport test host.
  override static func canInit(with request: URLRequest) -> Bool { request.url?.host == "transport.test" }

  /// Preserves the request URL because the test protocol does not canonicalize requests.
  override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  /// Produces deterministic responses, redirects, oversized bodies, or a held request.
  override func startLoading() {
    guard let url = request.url else { return }
    let path = url.path
    Self.lock.lock()
    Self.paths.append(path)
    Self.lock.unlock()

    if path == "/offline" {
      client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
      return
    }
    if path == "/non-http" {
      let response = URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocolDidFinishLoading(self)
      return
    }

    let status = path == "/redirect" ? 302 : 200
    var headers = ["Content-Type": "application/json", "Retry-After": "12"]
    if path == "/redirect" { headers["Location"] = "https://transport.test/followed" }
    if path == "/oversized-header" { headers["Content-Length"] = "10485761" }
    guard
      let response = HTTPURLResponse(
        url: url, statusCode: status, httpVersion: "HTTP/1.1",
        headerFields: headers)
    else { preconditionFailure("Invalid test response") }
    if path == "/redirect" {
      let redirectedRequest = URLRequest(url: requiredURL("https://transport.test/followed"))
      client?.urlProtocol(self, wasRedirectedTo: redirectedRequest, redirectResponse: response)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data("redirect body".utf8))
      client?.urlProtocolDidFinishLoading(self)
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    Self.responseSignal(path).signal()
    if path == "/hang" || path == "/oversized-header" { return }
    if path == "/at-limit" {
      client?.urlProtocol(self, didLoad: Data(repeating: 0x61, count: 10_485_760))
      client?.urlProtocolDidFinishLoading(self)
      return
    }
    if path == "/oversized" {
      client?.urlProtocol(self, didLoad: Data(repeating: 0x61, count: 10 * 1_024 * 1024 + 1))
      return
    }
    client?.urlProtocol(self, didLoad: Data("{}".utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  /// Signals URL loading cancellation and records the stopped path.
  override func stopLoading() {
    guard let path = request.url?.path else { return }
    Self.lock.lock()
    Self.stoppedPaths.append(path)
    Self.lock.unlock()
    Self.stopSignal(path).signal()
  }

  /// Returns all request paths observed by this protocol.
  static func recordedPaths() -> [String] {
    lock.lock()
    defer { lock.unlock() }

    return paths
  }

  /// Returns all paths for which loading was stopped.
  static func recordedStoppedPaths() -> [String] {
    lock.lock()
    defer { lock.unlock() }

    return stoppedPaths
  }

  /// Blocks until the test protocol has delivered the response for a path.
  static func waitForResponse(path: String) { responseSignal(path).wait() }
  /// Blocks until URLSession has stopped loading the requested path.
  static func waitForStop(path: String) { stopSignal(path).wait() }

  /// Returns or creates the response-arrival signal for a request path.
  private static func responseSignal(_ path: String) -> DispatchSemaphore {
    lock.lock()
    defer { lock.unlock() }
    if let semaphore = responseSignals[path] { return semaphore }
    let semaphore = DispatchSemaphore(value: 0)
    responseSignals[path] = semaphore

    return semaphore
  }

  /// Returns or creates the cancellation signal for a request path.
  private static func stopSignal(_ path: String) -> DispatchSemaphore {
    lock.lock()
    defer { lock.unlock() }
    if let semaphore = stopSignals[path] { return semaphore }
    let semaphore = DispatchSemaphore(value: 0)
    stopSignals[path] = semaphore

    return semaphore
  }
}

/// Creates a URLSession transport configured to use the controlled protocol.
private func controlledTransport() -> URLSessionTransport {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [ControlledURLProtocol.self]

  return URLSessionTransport(configuration: configuration)
}

/// Scenario: url session transport preserves response headers.
@Test func urlSessionTransportPreservesResponseHeaders() async throws {
  let transport = controlledTransport()
  let result = try await transport.send(
    URLRequest(url: requiredURL("https://transport.test/headers")))
  #expect(result.statusCode == 200)
  #expect(result.contentType == "application/json")
  #expect(result.retryAfter == "12")
}

/// Scenario: url session transport bounds response and stops task.
@Test func urlSessionTransportBoundsResponseAndStopsTask() async throws {
  let transport = controlledTransport()
  let request = URLRequest(url: requiredURL("https://transport.test/oversized"))
  await #expect(throws: HTTPTransportError.responseTooLarge) { try await transport.send(request) }
  ControlledURLProtocol.waitForStop(path: "/oversized")
  #expect(ControlledURLProtocol.recordedStoppedPaths().contains("/oversized"))
}

/// Reports generic failures for responses that cannot be read as HTTP.
@Test(arguments: [
  ("/non-http", HTTPTransportError.nonHTTPResponse),
  ("/offline", .transport(code: URLError.notConnectedToInternet.rawValue))
])
func urlSessionTransportReportsGenericFailures(path: String, expectedError: HTTPTransportError) async throws {
  let transport = controlledTransport()
  let request = URLRequest(url: requiredURL("https://transport.test" + path))

  await #expect(throws: expectedError) { try await transport.send(request) }
}

/// Rejects an oversized declared body before the protocol delivers any body bytes.
@Test func urlSessionTransportRejectsOversizedContentLength() async throws {
  let transport = controlledTransport()
  let request = URLRequest(url: requiredURL("https://transport.test/oversized-header"))

  await #expect(throws: HTTPTransportError.responseTooLarge) { try await transport.send(request) }
}

/// Allows a streamed response that exactly meets the size limit.
@Test func urlSessionTransportAcceptsBodyAtLimit() async throws {
  let transport = controlledTransport()
  let request = URLRequest(url: requiredURL("https://transport.test/at-limit"))

  let result = try await transport.send(request)

  #expect(result.data.count == 10_485_760)
}

/// Scenario: url session transport does not follow redirects.
@Test func urlSessionTransportDoesNotFollowRedirects() async throws {
  let transport = controlledTransport()
  let request = URLRequest(url: requiredURL("https://transport.test/redirect"))
  let response = try await transport.send(request)
  #expect(response.statusCode == 302)
  #expect(!ControlledURLProtocol.recordedPaths().contains { $0 == "/followed" })
}

/// Scenario: url session transport cancels an in flight request.
@Test func urlSessionTransportCancelsAnInFlightRequest() async throws {
  let transport = controlledTransport()
  let request = URLRequest(url: requiredURL("https://transport.test/hang"))
  let task = Task { try await transport.send(request) }
  ControlledURLProtocol.waitForResponse(path: "/hang")
  task.cancel()
  await #expect(throws: CancellationError.self) { try await task.value }
  ControlledURLProtocol.waitForStop(path: "/hang")
  #expect(ControlledURLProtocol.recordedStoppedPaths().contains("/hang"))
}
