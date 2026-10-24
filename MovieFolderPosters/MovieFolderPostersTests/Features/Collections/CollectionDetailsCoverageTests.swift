import AppKit
import FileSystem
import Foundation
import MovieFolderCommon
import Testing

@testable import MovieFolderPosters

/// Verifies that recovery evidence stays readable and privacy-safe in the actual read-only report.
@MainActor
struct CollectionDetailsCoverageTests {
  /// An unfinished inventory and manual failure must never read as a completed successful collection run.
  @Test func interruptedManualReportKeepsUnknownEvidenceExplicit() throws {
    let context = CollectionProcessingContext(rootID: UUID(), rootIdentity: "private-root-identity",
      authorizationVersion: UUID(), credentialRevision: UUID(), usesStubTMDbResponses: false, appearance: .softFinish)
    let run = CollectionProcessingRun(action: .removal, startedAt: Date(), state: .running)
    let records = [
      FolderProcessingRecord(name: "Folder 10", state: .uncertain, reason: .ownershipChanged,
        movieID: 7, movieIdentitySource: .savedDecision, ownership: .changed,
        lastFailure: FolderProcessingFailure(reason: .ownershipChanged, stage: .validateIdentity, occurredAt: Date())),
      FolderProcessingRecord(name: "Folder 2", state: .suppressed, reason: .policySuppressed,
        movieIdentitySource: .explicitSelection, ownership: .unowned),
      FolderProcessingRecord(name: "Folder 1", state: .deferred, reason: .rateLimited, ownership: .none,
        lastFailure: FolderProcessingFailure(reason: .rateLimited, stage: .artwork, occurredAt: Date()))
    ]
    let savedState = CollectionProcessingState(context: context, currentRun: run, folders: records,
      isInventoryComplete: false, inventoryIssue: .inspectionFailure)
    let text = try report(savedState, displayState: .interrupted)
    #expect(text.contains("Result state at last inspection: Interrupted"))
    #expect(text.contains("In progress or awaiting verification"))
    #expect(text.contains("Inventory: incomplete"))
    #expect(text.contains("Inventory issue: Folder inspection failed"))
    #expect(text.contains("Last completed collection run: Not recorded"))
    #expect(text.contains("Movie: Untitled, ID 7"))
    #expect(text.contains("Movie: Not recorded"))
    #expect(text.contains("Poster ownership: Changed since ownership proof"))
    #expect(text.contains("Poster ownership: Not app-owned"))
    #expect(text.contains("Poster ownership: No custom poster"))
    #expect(text.contains("Movie identity evidence: Saved decision"))
    #expect(text.contains("Movie identity evidence: Explicitly selected"))
    #expect(text.contains("Folder identity evidence: Unavailable"))
    #expect(text.contains("Last failure: Rate limited during poster artwork retrieval"))
    #expect(!text.contains(context.rootIdentity))
    let first = try #require(text.range(of: "Folder 1\n"))
    let second = try #require(text.range(of: "Folder 2\n"))
    let tenth = try #require(text.range(of: "Folder 10\n"))
    #expect(first.lowerBound < second.lowerBound)
    #expect(second.lowerBound < tenth.lowerBound)
  }

  /// Safe categories replace raw errors while distinguishing provider, persistence, and filesystem failures.
  @Test(arguments: [
    FailureReportCase(reason: .authentication, stage: .search, expected: "Authentication failed during movie search"),
    FailureReportCase(reason: .invalidResponse, stage: .parse,
      expected: "Invalid service response during folder-name parsing"),
    FailureReportCase(reason: .filesystem, stage: .assignPoster, expected: "Filesystem error during poster assignment"),
    FailureReportCase(reason: .storage, stage: .persist, expected: "Storage error during saving results"),
    FailureReportCase(reason: .cancelled, stage: .inventory, expected: "Cancelled during inventory"),
    FailureReportCase(reason: .unavailable, stage: .unknown, expected: "Unavailable during an unknown stage"),
    FailureReportCase(reason: .capacity, stage: .persist, expected: "Capacity reached during saving results"),
    FailureReportCase(reason: .unknown, stage: .unknown, expected: "Unclassified attempt during an unknown stage")
  ])
  func failureReportUsesSafeCategories(_ scenario: FailureReportCase) throws {
    let context = CollectionProcessingContext(rootID: UUID(), rootIdentity: "identity",
      authorizationVersion: UUID(), credentialRevision: UUID(), usesStubTMDbResponses: false, appearance: .softFinish)
    let savedState = CollectionProcessingState(context: context, folders: [
      FolderProcessingRecord(name: "Failed Movie", state: .failed, reason: .processingFailure,
        lastFailure: FolderProcessingFailure(reason: scenario.reason, stage: scenario.stage, occurredAt: Date()))
    ])
    let text = try report(savedState, displayState: .failed)
    #expect(text.contains("State: Failed"))
    #expect(text.contains("Reason: Processing failed"))
    #expect(text.contains("Last failure: " + scenario.expected))
  }

  /// Loads the actual AppKit text view and checks its read-only contract.
  private func report(
    _ savedState: CollectionProcessingState, displayState: CollectionProcessingDisplayState
  ) throws -> String {
    let summary = CollectionProcessingSummary(processingState: savedState,
      presentation: CollectionProcessingPresentation(processingState: savedState), counts: savedState.calculateCounts(),
      displayState: displayState)
    let controller = CollectionProcessingDetailsViewController(collectionName: "Movies", summary: summary)
    let scroll = try #require(controller.view.subviews.compactMap { $0 as? NSScrollView }.first)
    let text = try #require(scroll.documentView as? NSTextView)
    #expect(!text.isEditable)
    #expect(text.isSelectable)

    return text.string
  }
}

/// One safe latest-attempt category and its independently expected user-facing wording.
struct FailureReportCase: Sendable {
  /// Persisted failure category.
  let reason: FolderProcessingFailureReason
  /// Stage where the attempt failed.
  let stage: FolderProcessingStage
  /// Literal wording required by the recovery report contract.
  let expected: String
}
