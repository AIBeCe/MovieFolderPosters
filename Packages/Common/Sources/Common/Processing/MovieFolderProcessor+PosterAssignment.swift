import FileSystem
import Foundation
import Persistence

extension MovieFolderProcessor {
  /// Holds configuration validation through the final child check and automatic icon assignment.
  ///
  /// - Parameters:
  ///   - data: The encoded record or image bytes consumed by this operation.
  ///   - candidate: The child folder evidence captured before this operation.
  ///   - root: The authorized collection directory containing the immediate child.
  ///   - localInformationReadResultSHA256: Captured digest of selected local sources.
  ///   - searchCorrection: Captured correction record to verify under the settings lock.
  /// - Throws: Persistence, authorization, changed-folder, or icon-operation errors from the required processing step.
  func assign(
    _ data: Data,
    to candidate: MovieFolderCandidate,
    in root: URL,
    localInformationReadResultSHA256: String? = .none,
    searchCorrection: AutomaticSearchCorrection? = .none
  ) throws -> FolderPosterAssignmentResult {
    try Task.checkCancellation()
    let recoveryAccess = try recovery?.acquireProcessingAccess()
    defer { withExtendedLifetime(recoveryAccess) {} }
    let settingsAccess = try checkIconChange(.automaticPosterAssignment, to: candidate, in: root)
    defer { withExtendedLifetime(settingsAccess) {} }
    let current: MovieFolderCandidate
    do {
      current = try inventoryReader.readCurrentFolderCandidate(ofChild: candidate.name, in: root)
    } catch {
      throw AutomaticProcessingIssue.changedIdentity
    }

    guard current.identity == candidate.identity else { throw AutomaticProcessingIssue.changedIdentity }

    if let localInformationReadResultSHA256 {
      try informationContext(candidate, root: root, sha256: localInformationReadResultSHA256).validate()
    }

    try searchCorrection?.validate()

    return try posterAssigner.assignPoster(
      data, toChild: candidate.name, in: root,
      appearance: appearance, expectedIdentity: candidate.identity)
  }

  /// Restyles a cached owned poster when its finish differs and suppression permits change.
  ///
  /// - Parameters:
  ///   - candidate: The child folder evidence captured before this operation.
  ///   - root: The authorized collection directory containing the immediate child.
  ///   - state: The root processing state being inspected or updated.
  /// - Returns: Whether an owned poster was rewritten using the selected finish.
  /// - Throws: Persistence, authorization, changed-folder, or icon-operation errors from the required processing step.
  func restyleOwnedPosterIfPossible(
    _ candidate: MovieFolderCandidate, in root: URL, state: CollectionProcessingCache
  ) throws -> Bool {
    guard try !ownedPosters.isPosterSuppressed(toChild: candidate.name, in: root),
      try ownedPosters.hasAssignedPoster(
        toChild: candidate.name, in: root,
        expectedIdentity: candidate.identity)
    else { return false }

    guard
      try ownedPosters.assignedPosterAppearance(
        toChild: candidate.name, in: root,
        expectedIdentity: candidate.identity) != appearance
    else {
      return false
    }

    guard let record = state.folders[candidate.name], record.fingerprint == candidate.fingerprint,
      record.status == .processed, let posterPath = record.posterPath,
      record.matchedMovieID != .none, case .valid(let data) = cachedPoster(for: posterPath)
    else { return false }

    try Task.checkCancellation()
    let recoveryAccess = try recovery?.acquireProcessingAccess()
    defer { withExtendedLifetime(recoveryAccess) {} }
    let current = try inventoryReader.readCurrentFolderCandidate(ofChild: candidate.name, in: root)

    guard current.identity == candidate.identity else { throw AutomaticProcessingIssue.changedIdentity }

    let settingsAccess = try checkIconChange(.posterRestyle, to: candidate, in: root)
    defer { withExtendedLifetime(settingsAccess) {} }
    let result = try ownedPosters.restyleAssignedPoster(
      data, toChild: candidate.name, in: root, appearance: appearance,
      expectedIdentity: candidate.identity
    )
    if case .assigned = result { return true }

    return false
  }

  /// Checks captured inclusion before retaining the live settings fence through a synchronous icon write.
  func checkIconChange(
    _ change: MovieFolderIconChange, to candidate: MovieFolderCandidate, in root: URL
  ) throws -> PersistenceAccess? {
    if change != .posterRemoval {
      guard !processingConfiguration.isPaused else { throw CollectionProcessingError.configurationChanged }

      guard !processingConfiguration.excludesFolder(identity: candidate.identity) else {
        throw CollectionProcessingError.configurationChanged
      }
    }

    return try processingVerifier?.checkIconChange(change, to: candidate, in: root)
  }
}
