import FileSystem
import Foundation
import MovieFolderCommon
import Testing

@testable import MovieFolderPosters

/// Verifies that unresolved results preserve saved evidence for manual review.
struct CollectionUnresolvedResultsTests {
  /// Mixed outcomes retain outstanding work and omit intentional terminal results.
  @Test func mixedResultsPreserveOutstandingEvidence() {
    let assessedAt = Date(timeIntervalSince1970: 1_000)
    let notFound = FolderProcessingRecord(
      name: "Movie 2", identity: "missing-movie", state: .notFound,
      reason: .noSuitableMovie, retryAt: assessedAt.addingTimeInterval(3_600))
    let ambiguous = FolderProcessingRecord(
      name: "Movie 1", identity: "ambiguous-movie", state: .severalMatches,
      reason: .ambiguousMovie)
    let failed = FolderProcessingRecord(
      name: "Movie 10", state: .failed, reason: .connectivity)
    let folders = [
      failed,
      FolderProcessingRecord(
        name: "Completed", identity: "completed-movie", state: .done,
        movieID: 42, ownership: .owned, assessedAt: assessedAt),
      notFound,
      FolderProcessingRecord(name: "Preserved", state: .preserved),
      ambiguous,
      FolderProcessingRecord(name: "Suppressed", state: .suppressed)
    ]

    #expect(summary(folders: folders).unresolvedFolders() == [
      ambiguous, notFound, failed
    ])
  }

  /// Unknown freshness does not erase evidence needed to explain remaining work.
  /// - Parameter displayState: Saved lifecycle state whose evidence remains readable.
  @Test(arguments: [
    CollectionProcessingDisplayState.stale, .partial, .interrupted
  ])
  func incompleteResultsRemainVisible(_ displayState: CollectionProcessingDisplayState) {
    let folders = [
      FolderProcessingRecord(name: "Pending", state: .pending),
      FolderProcessingRecord(name: "Uncertain", state: .uncertain)
    ]
    let result = summary(folders: folders, displayState: displayState)

    #expect(result.unresolvedFolders() == folders)
    #expect(result.displayState == displayState)
  }

  /// Missing saved evidence differs from a saved inventory with no unresolved work.
  @Test func unavailableAndEmptyResultsRemainDistinct() {
    #expect(summary(folders: .none).unresolvedFolders() == .none)
    #expect(summary(folders: []).unresolvedFolders() == [])
  }

  /// Builds an isolated saved projection without services or filesystem access.
  /// - Parameters:
  ///   - folders: Saved folder evidence, or `.none` when unavailable.
  ///   - displayState: Lifecycle state represented by the summary.
  /// - Returns: An isolated collection summary for projection tests.
  private func summary(
    folders: [FolderProcessingRecord]?,
    displayState: CollectionProcessingDisplayState = .current
  ) -> CollectionProcessingSummary {
    let context = CollectionProcessingContext(
      rootID: UUID(), rootIdentity: "root", authorizationVersion: UUID(),
      credentialRevision: UUID(), usesStubTMDbResponses: false,
      appearance: .softFinish)
    let processingState = folders.map {
      CollectionProcessingState(context: context, folders: $0)
    }

    return CollectionProcessingSummary(
      processingState: processingState,
      presentation: CollectionProcessingPresentation(
        processingState: processingState, isStale: displayState == .stale),
      counts: CollectionProcessingCounts(
        done: .none, notFound: .none, severalMatches: .none, total: .none),
      displayState: displayState)
  }
}
