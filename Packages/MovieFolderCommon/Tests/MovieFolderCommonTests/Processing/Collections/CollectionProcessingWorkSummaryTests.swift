import Foundation
@testable import MovieFolderCommon
import Testing

/// Keeps work eligibility separate from snapshot freshness and historical outcome counts.
struct CollectionProcessingWorkSummaryTests {
  /// Missing release-year configuration outcomes require manual matching rather than automatic retry.
  @Test func missingReleaseYearIsManualWork() {
    let snapshot = state(folders: [
      FolderProcessingRecord(name: "Dune", state: .unresolved, reason: .manualMatchingRequired)
    ])
    let work = CollectionProcessingWorkSummary(processingState: snapshot, now: now)
    #expect(work.needsManualResolution == 1)
    #expect(work.needsProcessing == .zero)
    #expect(work.waitingToRetry == .zero)
  }
  /// Captured inspection time used by retry eligibility tests.
  private let now = Date(timeIntervalSince1970: 1_000)

  /// Mixed conditions remain independently visible, including preserved and suppressed outcomes.
  @Test func mixedWorkRemainsVisible() {
    let snapshot = state(folders: [
      FolderProcessingRecord(name: "Pending"),
      FolderProcessingRecord(name: "Retry", state: .unresolved, reason: .incompleteSearch,
                             retryAt: now.addingTimeInterval(60)),
      FolderProcessingRecord(name: "Manual", state: .notFound, reason: .noSuitableMovie),
      FolderProcessingRecord(name: "Legacy", state: .unresolved),
      FolderProcessingRecord(name: "Preserved", state: .preserved),
      FolderProcessingRecord(name: "Suppressed", state: .suppressed)
    ])
    let work = CollectionProcessingWorkSummary(processingState: snapshot, now: now)

    #expect(work.needsProcessing == 1)
    #expect(work.waitingToRetry == 1)
    #expect(work.needsManualResolution == 1)
    #expect(work.needsReassessment == 1)
    #expect(work.preserved == 1)
    #expect(work.suppressed == 1)
    #expect(!work.isComplete)
  }

  /// Only a complete current inventory may establish that no processing work remains.
  @Test func unknownIncompleteAndStaleEvidenceCannotClaimComplete() {
    #expect(!CollectionProcessingWorkSummary(processingState: .none, now: now).isComplete)
    #expect(!CollectionProcessingWorkSummary(processingState: state(folders: [], complete: false), now: now).isComplete)
    #expect(!CollectionProcessingWorkSummary(processingState: state(folders: []), isStale: true, now: now).isComplete)
    #expect(CollectionProcessingWorkSummary(processingState: state(folders: []), now: now).isComplete)
  }

  /// Partial and stale inventories keep observed mixed work visible without asserting current eligibility.
  @Test func incompleteAndStaleWorkRemainQualified() {
    let folders = [
      FolderProcessingRecord(name: "Pending"),
      FolderProcessingRecord(name: "Manual", state: .notFound, reason: .noSuitableMovie)
    ]
    let incomplete = CollectionProcessingWorkSummary(
      processingState: state(folders: folders, complete: false), now: now)
    let stale = CollectionProcessingWorkSummary(processingState: state(folders: folders), isStale: true, now: now)

    #expect(incomplete.description.contains("Needs processing: 1"))
    #expect(incomplete.description.contains("Needs manual resolution: 1"))
    #expect(incomplete.description.contains("Unverified"))
    #expect(stale.description.contains("Needs processing: 1"))
    #expect(stale.description.contains("Unverified"))
    #expect(!incomplete.isComplete)
    #expect(!stale.isComplete)
  }

  /// Incomplete searches become eligible later while conclusive and parsing outcomes remain manual.
  @Test func reasonControlsWorkDespiteObsoleteRetryDates() {
    let snapshot = state(folders: [
      FolderProcessingRecord(name: "Incomplete", state: .unresolved, reason: .incompleteSearch,
                             retryAt: now.addingTimeInterval(-1)),
      FolderProcessingRecord(name: "Parsing", state: .unresolved, reason: .parsingProblem,
                             retryAt: now.addingTimeInterval(-1)),
      FolderProcessingRecord(name: "Artwork", state: .unresolved, reason: .missingArtwork),
      FolderProcessingRecord(name: "Legacy", state: .notFound, retryAt: now.addingTimeInterval(600))
    ])
    let work = CollectionProcessingWorkSummary(processingState: snapshot, now: now)

    #expect(work.needsProcessing == 1)
    #expect(work.needsManualResolution == 2)
    #expect(work.needsReassessment == 1)
    #expect(work.waitingToRetry == .zero)
  }

  /// Builds one complete isolated collection without accessing App Group storage.
  private func state(folders: [FolderProcessingRecord], complete: Bool = true) -> CollectionProcessingState {
    CollectionProcessingState(context: CollectionProcessingContext(
      rootID: UUID(), rootIdentity: "root", authorizationVersion: UUID(), credentialRevision: UUID(),
      usesStubTMDbResponses: false, appearance: .softFinish), folders: folders,
      isInventoryComplete: complete, inspectedAt: now)
  }
}
