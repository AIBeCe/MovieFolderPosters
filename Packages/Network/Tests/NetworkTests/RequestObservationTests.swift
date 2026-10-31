import Foundation
import Testing

@testable import Network

/// Records request observations and can suspend ticket preparation for cancellation tests.
actor TMDbRequestObservationRecorderDelegate: TMDbClientRequestDelegate {
  /// The ticket returned by preparation.
  private let recordingTicket: UUID?
  /// Whether preparation should wait until the test resumes it.
  private let shouldSuspendPreparation: Bool
  /// Continuation resumed when preparation is allowed to finish.
  private var preparationContinuation: CheckedContinuation<Void, Never>?
  /// Indicates that preparation reached its suspension point.
  private var preparationStartedContinuation: CheckedContinuation<Void, Never>?
  /// Whether the suspended preparation point has been reached.
  private var hasStartedPreparation = false
  /// Purposes whose preparation was requested.
  private(set) var preparedPurposes: [TMDbRequestCategory] = []
  /// Completed observations in callback order.
  private(set) var completions: [(TMDbRequestCategory, TMDbRequestCompletionResult, UUID)] = []

  /// Creates a recorder with the requested optional ticket and preparation behavior.
  init(recordingTicket: UUID? = UUID(), shouldSuspendPreparation: Bool = false) {
    self.recordingTicket = recordingTicket
    self.shouldSuspendPreparation = shouldSuspendPreparation
  }

  /// Records preparation and optionally waits for cancellation to be requested by the test.
  func tmdbClientWillSendRequest(purpose: TMDbRequestCategory) async -> UUID? {
    preparedPurposes.append(purpose)

    if shouldSuspendPreparation {
      hasStartedPreparation = true
      preparationStartedContinuation?.resume()
      preparationStartedContinuation = .none
      await withCheckedContinuation { continuation in
        preparationContinuation = continuation
      }
    }

    return recordingTicket
  }

  /// Records safe, bounded completion metadata.
  func tmdbClientDidCompleteRequest(
    purpose: TMDbRequestCategory,
    result: TMDbRequestCompletionResult,
    completedAt: Date,
    recordingTicket: UUID
  ) {
    completions.append((purpose, result, recordingTicket))
  }

  /// Waits until suspended preparation has started.
  func waitUntilPreparationStarts() async {
    if shouldSuspendPreparation, !hasStartedPreparation {
      await withCheckedContinuation { continuation in
        preparationStartedContinuation = continuation
      }
    }
  }

  /// Allows suspended preparation to return its ticket.
  func resumePreparation() {
    preparationContinuation?.resume()
    preparationContinuation = .none
  }

  /// Returns the observations collected so far.
  func captured() -> (prepared: [TMDbRequestCategory], completed: [(TMDbRequestCategory, TMDbRequestCompletionResult, UUID)]) {
    (preparedPurposes, completions)
  }
}

/// Observes an HTTP response independently of later response decoding.
@Test func observesMalformedSuccessfulResponseOnlyOnce() async throws {
  let delegate = TMDbRequestObservationRecorderDelegate()
  let transport = ScriptedHTTPTransport([.success(response("not-json"))])
  let tmdbClient = try TMDbClient(
    token: TMDbAccessToken("token"), transport: transport, requestDelegate: delegate)

  await #expect(throws: TMDbError.malformedResponse) {
    try await tmdbClient.searchMovies(title: "private title", year: 1979)
  }

  let observations = await delegate.captured()
  #expect(observations.prepared == [.movieSearch])
  #expect(observations.completed.count == 1)
  #expect(observations.completed.first?.0 == .movieSearch)
  #expect(observations.completed.first?.1 == .response(statusCode: 200))
}

/// Observes HTTP failures and transport failures without retaining their private details.
@Test(arguments: [
  (
    Result<HTTPTransportResponse, Error>.success(response("private body", status: 503)),
    TMDbRequestCompletionResult.response(statusCode: 503)
  ),
  (.failure(URLError(.notConnectedToInternet)), .transportFailure)
])
func observesHTTPAndTransportFailures(
  result: Result<HTTPTransportResponse, Error>, expected: TMDbRequestCompletionResult
) async throws {
  let delegate = TMDbRequestObservationRecorderDelegate()
  let transport = ScriptedHTTPTransport([result])
  let tmdbClient = try TMDbClient(
    token: TMDbAccessToken("token"), transport: transport, requestDelegate: delegate)

  do {
    try await tmdbClient.validateCredential()
  } catch { }

  let observations = await delegate.captured()
  #expect(observations.completed.count == 1)
  #expect(observations.completed.first?.0 == .credentialValidation)
  #expect(observations.completed.first?.1 == expected)
}

/// Records response-size rejection at the HTTP boundary.
@Test func observesOversizedResponse() async throws {
  let delegate = TMDbRequestObservationRecorderDelegate()
  let oversized = Data(repeating: 0x61, count: 10 * 1_024 * 1_024 + 1)
  let transport = ScriptedHTTPTransport([.success(HTTPTransportResponse(
    data: oversized, statusCode: 200, contentType: "application/json"))])
  let tmdbClient = try TMDbClient(
    token: TMDbAccessToken("token"), transport: transport, requestDelegate: delegate)

  await #expect(throws: TMDbError.responseTooLarge) { try await tmdbClient.validateCredential() }

  let observations = await delegate.captured()
  #expect(observations.completed.map(\.1) == [.responseTooLarge])
}

/// A cancelled preparation never dispatches or completes a request observation.
@Test func cancellationDuringPreparationPreventsDispatchAndCompletion() async throws {
  let delegate = TMDbRequestObservationRecorderDelegate(shouldSuspendPreparation: true)
  let transport = ScriptedHTTPTransport([])
  let tmdbClient = try TMDbClient(
    token: TMDbAccessToken("token"), transport: transport, requestDelegate: delegate)
  let task = Task { try await tmdbClient.validateCredential() }
  await delegate.waitUntilPreparationStarts()
  task.cancel()
  await delegate.resumePreparation()

  await #expect(throws: CancellationError.self) { try await task.value }
  #expect(await transport.capturedRequests().isEmpty)
  #expect(await delegate.captured().completed.isEmpty)
}

/// A missing ticket does not prevent normal request dispatch.
@Test func missingTicketStillSendsRequestWithoutCompletion() async throws {
  let delegate = TMDbRequestObservationRecorderDelegate(recordingTicket: .none)
  let transport = ScriptedHTTPTransport([.success(response("{\"success\":true}"))])
  let tmdbClient = try TMDbClient(
    token: TMDbAccessToken("token"), transport: transport, requestDelegate: delegate)

  try await tmdbClient.validateCredential()

  #expect(await transport.capturedRequests().count == 1)
  #expect(await delegate.captured().completed.isEmpty)
}

/// Assigns separate purposes to poster configuration and image HTTP requests.
@Test func posterRequestsHaveSeparatePurposes() async throws {
  let delegate = TMDbRequestObservationRecorderDelegate()
  let configuration = HTTPTransportResponse(
    data: Data(
      """
      {"images":{"secure_base_url":"https://image.tmdb.org/t/p/","poster_sizes":["w500"]}}
      """.utf8),
    statusCode: 200,
    contentType: "application/json")
  let image = HTTPTransportResponse(data: Data("not an image".utf8), statusCode: 200, contentType: "image/png")
  let transport = ScriptedHTTPTransport([.success(configuration), .success(image)])
  let tmdbClient = try TMDbClient(
    token: TMDbAccessToken("token"), transport: transport, requestDelegate: delegate)

  await #expect(throws: TMDbError.invalidImage) {
    try await tmdbClient.downloadPoster(path: "/poster.png")
  }

  let observations = await delegate.captured()
  #expect(observations.prepared == [.posterConfiguration, .posterDownload])
  #expect(observations.completed.map(\.0) == [.posterConfiguration, .posterDownload])
  #expect(observations.completed.map(\.1) == [.response(statusCode: 200), .response(statusCode: 200)])
}

/// Reports cancellation after a request was dispatched exactly once.
@Test func cancellationDuringTransportCompletesOnceAsCancelled() async throws {
  let delegate = TMDbRequestObservationRecorderDelegate()
  let transport = SuspendedHTTPTransport()
  let tmdbClient = try TMDbClient(
    token: TMDbAccessToken("token"), transport: transport, requestDelegate: delegate)
  let task = Task { try await tmdbClient.validateCredential() }
  await transport.waitUntilStarted()
  task.cancel()
  await transport.resume(with: response("{\"success\":true}"))

  await #expect(throws: CancellationError.self) { try await task.value }
  let observations = await delegate.captured()
  #expect(observations.completed.count == 1)
  #expect(observations.completed.first?.1 == .cancelled)
}
