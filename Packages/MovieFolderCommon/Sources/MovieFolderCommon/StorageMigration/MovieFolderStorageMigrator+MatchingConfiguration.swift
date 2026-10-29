import Foundation

extension MovieFolderStorageMigrator {
  /// Supplies established defaults only for recognized old contexts that previously omitted default matching choices.
  func normalizeOutcomeMatching(in object: inout [String: Any], record: MovieFolderStorageRecordKind) throws {
    if object["identificationPolicy"] == nil {
      object["identificationPolicy"] = ["requiresReleaseYearForAutomaticMatching": false,
        "comparesOriginalTitles": true, "searchLanguage": "en-US"]
    }
    try normalizeNestedMatching(in: &object, record: record)
  }

  /// The global outer name changed; both present aliases must describe identical transformed choices.
  /// - Parameters:
  ///   - object: Settings fields to update in place.
  ///   - record: Record identity used in migration errors.
  /// - Throws: A typed migration error for malformed or conflicting matching choices.
  func normalizeGlobalMatching(in object: inout [String: Any], record: MovieFolderStorageRecordKind) throws {
    let legacy = try matchingObject(object["identificationPolicy"], record: record)
    let current = try matchingObject(object["movieMatchingConfiguration"], record: record)
    if let legacy, let current, try encodeObject(legacy, record: record) != encodeObject(current, record: record) {
      throw MovieFolderStorageMigrationError.conflictingValues(record: record, field: "movieMatchingConfiguration")
    }
    object["movieMatchingConfiguration"] = current ?? legacy ?? [
      "requiresReleaseYearForAutomaticMatching": false, "comparesOriginalTitles": true, "searchLanguage": "en-US"
    ]
    object.removeValue(forKey: "identificationPolicy")
  }

  /// Root/context outer CodingKeys stay stable; only the renamed inner matching choice is converted.
  /// - Parameters:
  ///   - object: Nested context fields to update in place.
  ///   - record: Record identity used in migration errors.
  /// - Throws: A typed migration error when the supplied matching choice is malformed.
  func normalizeNestedMatching(in object: inout [String: Any], record: MovieFolderStorageRecordKind) throws {
    if let matching = try matchingObject(object["identificationPolicy"], record: record) {
      object["identificationPolicy"] = matching
    }
  }

  /// Refuses conflicts and malformed policies rather than selecting one value or resetting a supplied choice.
  /// - Parameters:
  ///   - value: Optional matching-policy JSON value.
  ///   - record: Record identity used in migration errors.
  /// - Returns: A validated policy object, or `nil` when the field is absent.
  /// - Throws: A typed migration error for malformed or conflicting supplied values.
  func matchingObject(_ value: Any?, record: MovieFolderStorageRecordKind) throws -> [String: Any]? {
    guard let value else { return .none }

    guard var matching = value as? [String: Any] else {
      throw MovieFolderStorageMigrationError.invalidRecord(record: record)
    }

    let oldKey = "requiresReleaseYearForAutomaticIdentification"
    let newKey = "requiresReleaseYearForAutomaticMatching"
    if let oldValue = matching[oldKey] {
      if let newValue = matching[newKey] {
        let oldData = try JSONSerialization.data(withJSONObject: oldValue, options: [.fragmentsAllowed, .sortedKeys])
        let newData = try JSONSerialization.data(withJSONObject: newValue, options: [.fragmentsAllowed, .sortedKeys])

        guard oldData == newData else {
          throw MovieFolderStorageMigrationError.conflictingValues(record: record, field: newKey)
        }
      }
      matching[newKey] = oldValue
      matching.removeValue(forKey: oldKey)
    }
    if matching["searchLanguage"] == nil { matching["searchLanguage"] = "en-US" }
    do {
      _ = try JSONDecoder().decode(MovieMatchingConfiguration.self, from: encodeObject(matching, record: record))
    } catch {
      throw MovieFolderStorageMigrationError.invalidRecord(record: record)
    }

    return matching
  }
}
