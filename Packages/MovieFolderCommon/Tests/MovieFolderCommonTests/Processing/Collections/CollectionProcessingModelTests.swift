import FileSystem
import Foundation
@testable import MovieFolderCommon
import Testing

/// Regression coverage for conservative processing counts and persisted model compatibility.
struct CollectionProcessingModelTests {
  /// Historical serialized field names retained as a compatibility fixture.
  private static let legacyJSONFixture = #"""
  {
    "context": {
      "appearance": "softFinish",
      "authorizationVersion": "22222222-2222-2222-2222-222222222222",
      "credentialRevision": "33333333-3333-3333-3333-333333333333",
      "developmentFixtures": false,
      "rootID": "11111111-1111-1111-1111-111111111111",
      "rootIdentity": "root-identity"
    },
    "folders": [{
      "assessedAt": 200,
      "fingerprint": "folder-identity:Movie (2021)",
      "identity": "folder-identity",
      "latestAttempt": {"code": "storage", "occurredAt": 200, "stage": "persist"},
      "movieID": 7,
      "movieIdentitySource": "explicitSelection",
      "movieTitle": "Movie",
      "movieYear": 2021,
      "name": "Movie (2021)",
      "ownership": "owned",
      "reason": "cachePersistenceFailure",
      "retryAt": 300,
      "state": "done"
    }],
    "inspectedAt": 100,
    "inventoryComplete": true,
    "lastCompletedRun": {
      "endedAt": 200,
      "id": "44444444-4444-4444-4444-444444444444",
      "kind": "automatic",
      "startedAt": 100,
      "state": "completed"
    },
    "lastCompletedRunContext": {
      "appearance": "softFinish",
      "authorizationVersion": "22222222-2222-2222-2222-222222222222",
      "credentialRevision": "33333333-3333-3333-3333-333333333333",
      "developmentFixtures": false,
      "rootID": "11111111-1111-1111-1111-111111111111",
      "rootIdentity": "root-identity"
    },
    "operation": {
      "endedAt": 200,
      "id": "44444444-4444-4444-4444-444444444444",
      "kind": "selection",
      "startedAt": 100,
      "state": "completed"
    },
    "revision": 7,
    "schemaVersion": 1
  }
  """#

  /// Stable generation shared by the collection projection regressions.
  private let context = CollectionProcessingContext(
    rootID: UUID(), rootIdentity: "root-identity", authorizationVersion: UUID(),
    credentialRevision: UUID(), usesStubTMDbResponses: false, appearance: .softFinish
  )

  /// Checks that Done requires verified identity and an application-owned poster.
  @Test func doneRequiresOwnedPosterAndVerifiedIdentity() throws {
    var processingState = CollectionProcessingState(context: context, folders: [
      FolderProcessingRecord(name: "Film", identity: "child", state: .done, movieID: 42,
                             ownership: .owned, assessedAt: Date())
    ], isInventoryComplete: true, inspectedAt: Date())
    try processingState.validate()

    processingState.folders[0].ownership = .unowned
    #expect(throws: CollectionProcessingError.invalidState) { try processingState.validate() }
  }

  /// Checks that an incomplete inventory cannot expose authoritative counts.
  @Test func incompleteInventoryLeavesTotalAndCountsUnavailable() {
    let processingState = CollectionProcessingState(
      context: context,
      folders: [FolderProcessingRecord(name: "Film", state: .notFound)],
      isInventoryComplete: false,
      inspectedAt: Date()
    )

    #expect(processingState.calculateCounts().total == .none)
    #expect(processingState.calculateCounts().notFound == .none)
  }

  /// Checks that complete membership establishes Total before assessments establish headline counts.
  @Test func completeInventoryKnowsTotalBeforeAssessmentButNotHeadlineCounts() {
    let processingState = CollectionProcessingState(
      context: context,
      folders: [FolderProcessingRecord(name: "Film")],
      isInventoryComplete: true,
      inspectedAt: Date()
    )

    #expect(processingState.calculateCounts().total == 1)
    #expect(processingState.calculateCounts().done == .none)
  }

  /// Checks that an inspected empty collection has known zero counts.
  @Test func inspectedEmptyInventoryHasZeroCounts() {
    let processingState = CollectionProcessingState(context: context, isInventoryComplete: true, inspectedAt: Date())
    let expected = CollectionProcessingCounts(done: 0, notFound: 0, severalMatches: 0, total: 0)
    #expect(processingState.calculateCounts() == expected)
  }

  /// Checks that projections distinguish stale generations, active work, and interrupted runs.
  @Test func projectionSeparatesStaleBusyAndInterruptedStates() {
    let operation = CollectionProcessingRun(
      action: .automatic, startedAt: Date(), endedAt: Date(), state: .interrupted)
    let processingState = CollectionProcessingState(context: context, currentRun: operation)

    #expect(CollectionProcessingPresentation(processingState: processingState).state == .interrupted)
    #expect(CollectionProcessingPresentation(processingState: processingState, isStale: true).state == .stale)
    #expect(CollectionProcessingPresentation(processingState: processingState, isBusy: true).state == .busy)

    var runningProcessingState = processingState
    runningProcessingState.currentRun?.state = .running
    #expect(CollectionProcessingPresentation(
      processingState: runningProcessingState, stateOverride: .interrupted
    ).state == .interrupted)
  }

  /// Checks that unsupported schemas and duplicate folder membership fail validation.
  @Test func unknownSchemaAndDuplicateMembershipAreRejected() {
    var processingState = CollectionProcessingState(schemaVersion: 99, context: context)
    #expect(throws: MovieFolderStorageMigrationError.unsupportedVersion(
      record: .collectionOutcomes(context.rootID), version: 99)) { try processingState.validate() }
    processingState.schemaVersion = 2
    processingState.folders = [FolderProcessingRecord(name: "Film"), FolderProcessingRecord(name: "Film")]
    #expect(throws: CollectionProcessingError.invalidState) { try processingState.validate() }
  }

  /// Checks that renamed Swift declarations retain their historical persisted keys and values.
  @Test func legacyJSONKeepsRenamedFieldsAndRunValues() throws {

    let processingState = try convertLegacyOutcomeFixture(Data(Self.legacyJSONFixture.utf8))
    try processingState.validate()

    #expect(processingState.folders.first?.lastFailure?.reason == .storage)
    #expect(processingState.currentRun?.action == .selection)
    #expect(processingState.isInventoryComplete)

    let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(processingState)) as? [String: Any]
    let operation = encoded?["operation"] as? [String: Any]
    let folder = (encoded?["folders"] as? [[String: Any]])?.first
    let failure = folder?["latestAttempt"] as? [String: Any]
    #expect(encoded?["inventoryComplete"] as? Bool == true)
    #expect(operation?["kind"] as? String == "selection")
    #expect(operation?["action"] == nil)
    #expect(folder?["lastFailure"] == nil)
    #expect(failure?["code"] as? String == "storage")
  }
}
