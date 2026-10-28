import Foundation
import MovieFolderCommon
import Persistence

/// Read-only local data export sources captured independently of UI lifetime.
nonisolated struct LocalDataExportSources: Sendable {
  /// Retained source entries; absence means unavailable rather than empty.
  let activity: [MovieFolderActivityLogEntry]?
  /// Retained terminal HTTP entries in source commit order; absence means unavailable.
  let network: [MovieFolderNetworkHistoryEntry]?
  /// In-memory configuration fingerprint, never exported.
  let privacy: Data?
}

/// Narrow read boundary retained by the finite local data export flow.
nonisolated protocol LocalDataExportServicing: Sendable {
  /// Loads retained evidence and the relevant current configuration.
  func load() async -> LocalDataExportSources
  /// Captures known app storage without creating any namespace.
  func storage() async -> LocalStorageReport
}

/// Reads histories and configuration away from UI callbacks; never records new events.
actor LocalDataExportService: LocalDataExportServicing {
  /// Required sources retained for the service lifetime.
  private let activity: any MovieFolderActivityServicing
  /// Retained HTTP history service used to load committed entries.
  private let network: any MovieFolderNetworkHistoryServicing

  /// Composes existing bounded histories without changing their recording choices.
  /// - Parameters:
  ///   - activity: Retained Activity history service.
  ///   - network: Retained HTTP history service used to load committed entries.
  init(
    activity: any MovieFolderActivityServicing,
    network: any MovieFolderNetworkHistoryServicing = MovieFolderEnvironment.makeNetworkHistoryService()
  ) {
    self.activity = activity
    self.network = network
  }

  /// Loads current retained histories and memory-only privacy evidence.
  /// - Returns: Available histories and the current privacy fingerprint.
  func load() async -> LocalDataExportSources {
    let activityEntries = try? await activity.entries()
    let networkEntries = try? await network.entries()
    let privacy = try? Self.historyPrivacyFingerprint(in: MovieFolderEnvironment.makeConfigurationRepository())

    return LocalDataExportSources(activity: activityEntries, network: networkEntries, privacy: privacy)
  }

  /// Projects only relevant history choices; exported documents never include this memory-only fingerprint.
  /// - Parameter repository: Existing settings repository, also injectable for isolated persistence regression tests.
  /// - Returns: Deterministic current privacy evidence.
  /// - Throws: Busy, corrupt or unavailable settings rather than treating failed reads as absent settings.
  nonisolated static func historyPrivacyFingerprint(in repository: ConfigurationRepository) throws -> Data {
    let (configuration, access) = try repository.readIfPresentHoldingAccess()
    let privacyConfiguration = LocalDataHistoryPrivacy(
      revision: configuration?.networkHistoryConfigurationRevision,
      recordsNetwork: configuration?.isNetworkHistoryRecordingEnabled ?? false,
      privateCollections: Dictionary(
        uniqueKeysWithValues: (configuration?.directories ?? []).map {
          ($0.id.uuidString, $0.usesPrivateHistory)
        }))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]

    return try withExtendedLifetime(access) { try encoder.encode(privacyConfiguration) }
  }

  /// Captures app-owned storage estimates without creating a namespace.
  /// - Returns: Bounded metadata estimates and completeness for each category.
  func storage() -> LocalStorageReport {
    LocalStorageReport.capture(
      sharedContainer: try? MovieFolderEnvironment.appGroupContainerURL(),
      hostApplicationSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
  }
}

/// Memory-only revalidation evidence containing no paths, bookmarks, grants or unrelated settings.
nonisolated private struct LocalDataHistoryPrivacy: Encodable {
  /// Existing history generation, or stable absence when no settings record has been saved.
  let revision: UUID?
  /// Global optional HTTP recording choice.
  let recordsNetwork: Bool
  /// Opaque configured identities with their explicit privacy choices; never included in exports.
  let privateCollections: [String: Bool]
}
