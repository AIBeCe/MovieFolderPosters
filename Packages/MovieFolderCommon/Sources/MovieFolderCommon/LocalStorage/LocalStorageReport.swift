import FileSystem
import Foundation

/// Fixed storage ownership categories; file counts never describe movies or decisions.
public enum LocalStorageCategory: String, CaseIterable, Encodable, Sendable {
  case posters, processingCache, collectionResults, settings, activityHistory, networkHistory
  case recoveryAndCoordination, migrationBackups, hostAuthorization

  /// Native table title for the app-owned storage responsibility.
  public var title: String {
    switch self {
    case .posters: "Posters"
    case .processingCache: "Processing cache"
    case .collectionResults: "Collection results"
    case .settings: "Settings"
    case .activityHistory: "Activity history"
    case .networkHistory: "Network history"
    case .recoveryAndCoordination: "Recovery and coordination"
    case .migrationBackups: "Migration backups"
    case .hostAuthorization: "Host authorization"
    }
  }

  /// Existing nonoverlapping namespaces owned by each category.
  public var namespaces: [String] {
    switch self {
    case .posters: ["Posters"]
    case .processingCache: ["Processing"]
    case .collectionResults: ["CollectionProcessingState", "Outcomes"]
    case .settings: ["Settings"]
    case .activityHistory: ["Activity"]
    case .networkHistory: ["NetworkHistory"]
    case .recoveryAndCoordination: ["ProcessingRecovery", "ProcessingLocks"]
    case .migrationBackups: ["MigrationBackups"]
    case .hostAuthorization: ["MovieFolderPosters/Authorization"]
    }
  }
}

/// One ownership category's metadata estimates and completeness.
public struct LocalStorageCategorySummary: Encodable, Sendable {
  /// Category whose fixed namespaces were inspected.
  public let category: LocalStorageCategory
  /// Individual namespace estimates, preserving incomplete or unavailable evidence.
  public let namespaces: [DirectoryStorage.Usage]
  /// Fixed exported fields contain only category metadata, with no storage locations.
  private enum CodingKeys: String, CodingKey { case category, logicalBytes, fileCount, status, startedAt, finishedAt }

  /// Encodes category totals explicitly; incomplete namespace evidence cannot become a complete category.
  public func encode(to encoder: any Encoder) throws {
    var fields = encoder.container(keyedBy: CodingKeys.self)
    try fields.encode(category, forKey: .category)
    try fields.encode(logicalBytes, forKey: .logicalBytes)
    try fields.encode(fileCount, forKey: .fileCount)
    try fields.encode(status, forKey: .status)
    try fields.encode(namespaces.map(\.startedAt).min(), forKey: .startedAt)
    try fields.encode(namespaces.map(\.finishedAt).max(), forKey: .finishedAt)
  }

  /// Logical lengths, with saturating arithmetic on overflow.
  public var logicalBytes: UInt64 {
    namespaces.reduce(.zero) {
      $0.addingReportingOverflow($1.logicalBytes).overflow
        ? UInt64.max : $0 + $1.logicalBytes
    }
  }
  /// Regular files, independent of application record counts.
  public var fileCount: UInt64 { namespaces.reduce(.zero) { $0 + $1.fileCount } }
  /// Conservative aggregate status; mixed missing and existing namespaces may still be complete.
  public var status: DirectoryStorage.Status {
    if namespaces.allSatisfy({ $0.status == .notCreated }) { return .notCreated }
    if namespaces.allSatisfy({ $0.status == .unavailable }) { return .unavailable }
    if namespaces.contains(where: { $0.status == .partial || $0.status == .unavailable }) { return .partial }
    if logicalBytes == UInt64.max { return .partial }

    return .complete
  }
}

/// Finite read-only report, excluding movie content, icons, Keychain and extension-private authorization.
public struct LocalStorageReport: Encodable, Sendable {
  /// Beginning of the report's measurement interval.
  public let startedAt: Date
  /// End of the report's measurement interval.
  public let finishedAt: Date
  /// All known ownership categories, including missing and unavailable storage.
  public let categories: [LocalStorageCategorySummary]

  /// Measures only fixed known storage locations without initializing application storage.
  /// - Parameters:
  ///   - sharedContainer: Existing app-group location, or absence when resolution failed.
  ///   - hostApplicationSupport: Existing host support location, excluding extension-private storage.
  /// - Returns: A bounded report suitable for local display and allowlisted local data export.
  public static func capture(sharedContainer: URL?, hostApplicationSupport: URL?) -> LocalStorageReport {
    let start = Date()
    let categories = LocalStorageCategory.allCases.map { category in
      let root = category == .hostAuthorization ? hostApplicationSupport : sharedContainer
      let usages = category.namespaces.map { name in
        if let root { return DirectoryStorage().measure(at: root.appendingPathComponent(name)) }
        var usage = DirectoryStorage.Usage()
        usage.status = .unavailable

        return usage
      }

      return LocalStorageCategorySummary(category: category, namespaces: usages)
    }

    return LocalStorageReport(startedAt: start, finishedAt: Date(), categories: categories)
  }
}
