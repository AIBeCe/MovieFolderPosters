import Common
import Testing

/// Guards the distinct reason vocabulary shared by details and activity history.
struct FolderProcessingReasonDescriptionTests {
  /// Every persisted reason has a concise, nonempty and unique user-facing explanation.
  @Test func reasonsHaveDistinctDescriptions() {
    let descriptions = FolderProcessingReason.allCases.map(\.userDescription)
    #expect(Set(descriptions).count == FolderProcessingReason.allCases.count)
    #expect(descriptions.allSatisfy { !$0.isEmpty && $0.count <= 120 && !$0.contains("\n") })
  }

  /// The page budget outcome explicitly offers the requested manual resolution path.
  @Test func pageLimitExplainsTheCauseAndAction() {
    #expect(FolderProcessingReason.incompleteSearch.userDescription
      == "Search page limit reached before matching finished; choose manually")
  }

  /// Activity rendering uses the canonical reason instead of maintaining a second vocabulary.
  @Test(arguments: FolderProcessingReason.allCases)
  func activityUsesCanonicalReason(_ reason: FolderProcessingReason) {
    let event = MovieFolderActivityLogEvent(action: .automaticProcessing, status: .succeeded, reason: reason)
    #expect(event.text.contains(reason.userDescription + "."))
  }
}
