import FileSystem
import Foundation
import Network
import Persistence

extension MovieFolderProcessor {
  /// Holds configuration validation through the final child check and automatic icon assignment.
  ///
  /// - Parameters:
  ///   - data: The encoded record or image bytes consumed by this operation.
  ///   - candidate: The child folder evidence captured before this operation.
  ///   - root: The authorized collection directory containing the immediate child.
  /// - Throws: Persistence, authorization, changed-folder, or icon-operation errors from the required processing step.
  func assign(_ data: Data, to candidate: FolderCandidate, in root: URL) throws -> PosterAssignmentResult {
    try Task.checkCancellation()
    let recoveryLease = try recovery?.acquireMutationLease()
    defer { withExtendedLifetime(recoveryLease) {} }
    let settingsLease = try mutationGuard?.movieFolderProcessor(self, willPerformAutomaticMutationIn: root)
    defer { withExtendedLifetime(settingsLease) {} }
    let current: FolderCandidate
    do {
      current = try fileSystem.readCurrentState(ofChild: candidate.name, in: root)
    } catch {
      throw ProcessingFailure.changedIdentity
    }

    guard current.identity == candidate.identity else { throw ProcessingFailure.changedIdentity }

    return try posterAssigner.assignPoster(
      data, toChild: candidate.name, in: root,
      appearance: appearance, expectedIdentity: candidate.identity)
  }

  /// Restyles a cached owned poster when its finish differs and suppression permits mutation.
  ///
  /// - Parameters:
  ///   - candidate: The child folder evidence captured before this operation.
  ///   - root: The authorized collection directory containing the immediate child.
  ///   - state: The root processing state being inspected or updated.
  /// - Returns: Whether an owned poster was rewritten using the selected finish.
  /// - Throws: Persistence, authorization, changed-folder, or icon-operation errors from the required processing step.
  func restyleOwnedPosterIfPossible(_ candidate: FolderCandidate, in root: URL, state: ProcessingState) throws -> Bool {
    guard try !fileSystem.isPosterSuppressed(toChild: candidate.name, in: root),
      try fileSystem.hasAssignedPoster(
        toChild: candidate.name, in: root,
        expectedIdentity: candidate.identity)
    else { return false }

    guard
      try fileSystem.assignedPosterAppearance(
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
    let recoveryLease = try recovery?.acquireMutationLease()
    defer { withExtendedLifetime(recoveryLease) {} }
    let current = try fileSystem.readCurrentState(ofChild: candidate.name, in: root)

    guard current.identity == candidate.identity else { throw ProcessingFailure.changedIdentity }

    let styleLease = try mutationGuard?.movieFolderProcessorWillPerformManualMutation(self)
    defer { withExtendedLifetime(styleLease) {} }
    let settingsLease = try mutationGuard?.movieFolderProcessor(self, willPerformAutomaticMutationIn: root)
    defer { withExtendedLifetime(settingsLease) {} }
    let result = try fileSystem.restyleAssignedPoster(
      data, toChild: candidate.name, in: root, appearance: appearance,
      expectedIdentity: candidate.identity
    )
    if case .assigned = result { return true }

    return false
  }
}
