import FileSystem
import Foundation
import Testing
@testable import MovieFolderPosters

struct CollectionProcessingModelTests {
  private let context = CollectionProcessingContext(
    rootID: UUID(), rootIdentity: "root-identity", authorizationVersion: UUID(),
    credentialRevision: UUID(), developmentFixtures: false, appearance: .softFinish
  )

  @Test func doneRequiresOwnedPosterAndVerifiedIdentity() throws {
    var processingState = CollectionProcessingState(context: context, folders: [
      FolderProcessingRecord(name: "Film", identity: "child", state: .done, movieID: 42,
                             ownership: .owned, assessedAt: Date())
    ], isInventoryComplete: true, inspectedAt: Date())
    try processingState.validate()

    processingState.folders[0].ownership = .unowned
    #expect(throws: CollectionProcessingError.invalidState) { try processingState.validate() }
  }

  @Test func incompleteInventoryLeavesTotalAndCountsUnavailable() {
    let processingState = CollectionProcessingState(
      context: context,
      folders: [FolderProcessingRecord(name: "Film", state: .notFound)],
      isInventoryComplete: false,
      inspectedAt: Date()
    )

    #expect(processingState.calculateCounts().total == nil)
    #expect(processingState.calculateCounts().notFound == nil)
  }

  @Test func completeInventoryKnowsTotalBeforeAssessmentButNotHeadlineCounts() {
    let processingState = CollectionProcessingState(
      context: context,
      folders: [FolderProcessingRecord(name: "Film")],
      isInventoryComplete: true,
      inspectedAt: Date()
    )

    #expect(processingState.calculateCounts().total == 1)
    #expect(processingState.calculateCounts().done == nil)
  }

  @Test func inspectedEmptyInventoryHasZeroCounts() {
    let processingState = CollectionProcessingState(context: context, isInventoryComplete: true, inspectedAt: Date())
    let expected = CollectionProcessingCounts(done: 0, notFound: 0, severalMatches: 0, total: 0)
    #expect(processingState.calculateCounts() == expected)
  }

  @Test func projectionSeparatesStaleBusyAndInterruptedStates() {
    let operation = CollectionProcessingOperation(
      action: .automatic, startedAt: Date(), endedAt: Date(), state: .interrupted)
    let processingState = CollectionProcessingState(context: context, operation: operation)

    #expect(CollectionProcessingPresentation(processingState: processingState).state == .interrupted)
    #expect(CollectionProcessingPresentation(processingState: processingState, isStale: true).state == .stale)
    #expect(CollectionProcessingPresentation(processingState: processingState, isBusy: true).state == .busy)

    var runningProcessingState = processingState
    runningProcessingState.operation?.state = .running
    #expect(CollectionProcessingPresentation(
      processingState: runningProcessingState, stateOverride: .interrupted
    ).state == .interrupted)
  }

  @Test func unknownSchemaAndDuplicateMembershipAreRejected() {
    var processingState = CollectionProcessingState(schemaVersion: 99, context: context)
    #expect(throws: CollectionProcessingError.unsupportedSchema) { try processingState.validate() }
    processingState.schemaVersion = 1
    processingState.folders = [FolderProcessingRecord(name: "Film"), FolderProcessingRecord(name: "Film")]
    #expect(throws: CollectionProcessingError.invalidState) { try processingState.validate() }
  }

  @Test func legacyJSONKeepsRenamedFieldsAndOperationValues() throws {
    let legacyJSON = #"""
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
    let processingState = try JSONDecoder().decode(CollectionProcessingState.self, from: Data(legacyJSON.utf8))
    try processingState.validate()

    #expect(processingState.folders.first?.lastFailure?.reason == .storage)
    #expect(processingState.operation?.action == .selection)
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
