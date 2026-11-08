import Foundation
import Common

@testable import MovieFolderPosters

/// Test doubles reject unsupported operations unless a scenario supplies its own implementation.
nonisolated protocol TestConfigurationServicing: CollectionConfigurationServicing, ConfigurationPreferencesWriting,
  AccessTokenManaging, CollectionSetupServicing, CollectionEditing, CollectionInclusionApplying {}

extension TestConfigurationServicing {
  /// Rejects setup when an older service does not provide transactional collection preparation.
  func prepareCollection(_ directory: URL) throws -> PreparedCollection {
    throw ConfigurationError.invalidConfiguration
  }
  /// Rejects services that cannot persist a privacy choice atomically.
  func commitCollection(
    _ candidate: PreparedCollection, displayName: String?,
    movieMatchingConfiguration: MovieMatchingConfiguration?, usesPrivateHistory: Bool
  ) throws {
    throw ConfigurationError.invalidConfiguration
  }
  /// Rejects unsupported rename instead of reporting an unpersisted change.
  func renameCollection(_ identifier: UUID, displayName: String) throws {
    throw ConfigurationError.invalidConfiguration
  }
  /// Rejects unsupported configuration persistence rather than silently changing presentation.
  func setMovieMatchingConfiguration(_ configuration: MovieMatchingConfiguration) throws {
    throw ConfigurationError.invalidConfiguration
  }
  /// Rejects services that cannot persist the global page budget.
  func setSearchPageLimit(_ limit: Int) throws { throw ConfigurationError.invalidConfiguration }
  /// Rejects Finder-originated edits when an older service lacks host-side validation.
  func applyInclusionRequest(_ request: MovieFolderInclusionRequest) throws {
    throw ConfigurationError.configurationChanged
  }
  /// Rejects collection editing when an older service lacks revision-checked updates.
  func savedCollectionState(_ identifier: UUID) throws -> SavedCollectionState {
    throw ConfigurationError.configurationChanged
  }
  /// Rejects services that cannot persist collection choices atomically.
  func updateCollection(
    _ identifier: UUID, update: CollectionConfigurationUpdate, expected: SavedCollectionState
  ) throws {
    throw ConfigurationError.configurationChanged
  }
}

@MainActor
extension ConfigurationViewModel {
  /// Uses one test double for the three presentation capabilities.
  convenience init(
    service: any CollectionConfigurationServicing & ConfigurationPreferencesWriting & AccessTokenManaging,
    activity: any MovieFolderActivityRecording, recovery: ProcessingRecoveryService? = .none
  ) {
    self.init(collections: service, preferences: service, accessTokens: service, activity: activity, recovery: recovery)
  }
}
