import Foundation

extension MovieFolderStorageMigrationError: LocalizedError {
  /// User-facing cause and next action, excluding raw fields, filesystem paths and record identifiers.
  public var errorDescription: String? {
    switch self {
    case .migrationRequired:
      "Your \(recordDescription) use an older data format. Choose Movie Folder Posters → Migrate Saved Data… "
        + "before processing continues."
    case .unsupportedVersion:
      "Your \(recordDescription) use a format this app cannot read. Open them with a newer compatible app. "
        + "The saved record was not replaced."
    case .invalidRecord:
      "Your \(recordDescription) could not be validated. The original record was kept. "
        + "Keep the app data and contact support before resetting anything."
    case .conflictingValues:
      "Your \(recordDescription) contain conflicting saved settings. The original record was kept. "
        + "Contact support before changing or deleting app data."
    case .busy:
      "Your \(recordDescription) are currently in use. Wait for the current operation to finish, then retry migration."
    case .backupUnavailable, .backupConflict:
      "The app could not create or verify a recovery copy of your \(recordDescription). "
        + "That record was not upgraded. Check access to the app's saved data, then retry migration."
    case .storageUnavailable:
      "The app could not read or save your \(recordDescription). Earlier completed upgrades were kept. "
        + "Check access to the app's saved data, then run Migrate Saved Data… again to resume."
    }
  }

  /// Concise alert heading which distinguishes an upgrade requirement from an actual storage failure.
  public var presentationTitle: String {
    switch self {
    case .migrationRequired: "Saved data needs an upgrade"
    case .unsupportedVersion: "Saved data requires a different app version"
    case .invalidRecord, .conflictingValues: "Saved data needs attention"
    case .busy: "Saved data is in use"
    case .backupUnavailable, .backupConflict: "Recovery copy could not be verified"
    case .storageUnavailable: "Saved data could not be accessed"
    }
  }

  /// Describes only the affected kind of app-owned data, never collection names or private identifiers.
  private var recordDescription: String {
    let record: MovieFolderStorageRecordKind
    switch self {
    case .migrationRequired(let kind, _), .unsupportedVersion(let kind, _), .invalidRecord(let kind),
      .conflictingValues(let kind, _), .busy(let kind), .backupUnavailable(let kind), .backupConflict(let kind),
      .storageUnavailable(let kind): record = kind
    }
    switch record {
    case .settings: return "saved application settings"
    case .collectionOutcomes: return "saved collection results"
    }
  }
}
