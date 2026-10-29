import Foundation

extension MovieFolderStorageMigrator {
  /// Converts only recognized legacy settings fields in memory, preserving all generation values and unknown fields.
  /// - Parameter payload: Encoded settings record to inspect and convert.
  /// - Returns: Converted bytes, whether the schema was legacy, and its validated configuration.
  /// - Throws: A typed migration error for malformed, conflicting, or unsupported settings.
  func convertSettings(_ payload: Data) throws
    -> (payload: Data, wasLegacy: Bool, configuration: DirectoryConfiguration) {
    let record = MovieFolderStorageRecordKind.settings
    var object = try recordObject(payload, record: record)
    let version = try recordVersion(object, field: "version", record: record)

    guard (1...6).contains(version) else {
      throw MovieFolderStorageMigrationError.unsupportedVersion(record: record, version: version)
    }

    if version < 6 {
      if version == 5 {
        guard object["movieMatchingConfiguration"] is [String: Any], object["identificationPolicy"] == nil else {
          throw MovieFolderStorageMigrationError.invalidRecord(record: record)
        }
        for field in ["processingCacheRevision", "retainsNetworkHistory", "historyRevision", "posterAppearance"] {
          _ = try requiredValue(object, field: field, record: record)
        }
      }
      let credentialRevision = try requiredValue(object, field: "credentialRevision", record: record)
      if object["processingCacheRevision"] == nil {
        guard version == 1 else { throw MovieFolderStorageMigrationError.invalidRecord(record: record) }

        object["processingCacheRevision"] = credentialRevision
      }
      if object["retainsNetworkHistory"] == nil { object["retainsNetworkHistory"] = false }
      if object["historyRevision"] == nil { object["historyRevision"] = credentialRevision }
      if object["posterAppearance"] == nil { object["posterAppearance"] = "softFinish" }
      try normalizeGlobalMatching(in: &object, record: record)

      guard var directories = object["directories"] as? [[String: Any]] else {
        throw MovieFolderStorageMigrationError.invalidRecord(record: record)
      }

      for index in directories.indices {
        if version == 5 {
          _ = try requiredValue(directories[index], field: "isPrivate", record: record)
          _ = try requiredValue(directories[index], field: "participationPolicy", record: record)
        }
        if directories[index]["isPrivate"] == nil { directories[index]["isPrivate"] = false }
        if directories[index]["participationPolicy"] == nil {
          directories[index]["participationPolicy"] = [
            "revision": "00000000-0000-0000-0000-000000000000", "isPaused": false, "excludedFolders": []
          ] as [String: Any]
        }
        try normalizeNestedMatching(in: &directories[index], record: record)
      }
      object["directories"] = directories
      object["version"] = 6
    }
    let converted = version < 6 ? try encodeObject(object, record: record) : payload
    let configuration: DirectoryConfiguration
    do {
      configuration = try JSONDecoder().decode(DirectoryConfiguration.self, from: converted)
      try ConfigurationRepository.validate(configuration)
    } catch {
      throw MovieFolderStorageMigrationError.invalidRecord(record: record)
    }

    return (converted, version < 6, configuration)
  }

  /// Converts matching keys in both live and historical outcome contexts, without revising outcome facts.
  /// - Parameters:
  ///   - payload: Encoded collection outcome record to inspect and convert.
  ///   - rootID: Expected configured root identity for the outcome.
  /// - Returns: Converted bytes and whether the schema was legacy.
  /// - Throws: A typed migration error for malformed, mismatched, or unsupported outcomes.
  func convertOutcomes(_ payload: Data, rootID: UUID) throws -> (payload: Data, wasLegacy: Bool) {
    let record = MovieFolderStorageRecordKind.collectionOutcomes(rootID)
    var object = try recordObject(payload, record: record)
    let version = try recordVersion(object, field: "schemaVersion", record: record)

    guard (1...3).contains(version) else {
      throw MovieFolderStorageMigrationError.unsupportedVersion(record: record, version: version)
    }

    if version < 3 {
      guard var context = object["context"] as? [String: Any] else {
        throw MovieFolderStorageMigrationError.invalidRecord(record: record)
      }

      try normalizeOutcomeMatching(in: &context, record: record)
      object["context"] = context
      if let historical = object["lastCompletedRunContext"], !(historical is NSNull) {
        guard var historicalContext = historical as? [String: Any] else {
          throw MovieFolderStorageMigrationError.invalidRecord(record: record)
        }

        try normalizeOutcomeMatching(in: &historicalContext, record: record)
        object["lastCompletedRunContext"] = historicalContext
      }
      object["schemaVersion"] = 3
    }
    let converted = version < 3 ? try encodeObject(object, record: record) : payload
    do {
      let state = try JSONDecoder().decode(CollectionProcessingState.self, from: converted)

      guard state.context.rootID == rootID else { throw MovieFolderStorageMigrationError.invalidRecord(record: record) }

      try state.validate()
    } catch {
      throw MovieFolderStorageMigrationError.invalidRecord(record: record)
    }

    return (converted, version < 3)
  }
  /// Converts only unversioned operational state, preserving every folder decision and retry field.
  func convertOperational(_ payload: Data, rootID: UUID) throws -> (payload: Data, wasLegacy: Bool) {
    let record = MovieFolderStorageRecordKind.operationalProcessing(rootID)
    var object = try recordObject(payload, record: record)
    let legacy = object["schemaVersion"] == nil
    if legacy {
      if let matching = try matchingObject(object["movieMatchingConfiguration"], record: record) {
        object["movieMatchingConfiguration"] = matching
      } else {
        object["movieMatchingConfiguration"] = ["requiresReleaseYearForAutomaticMatching": false,
          "comparesOriginalTitles": true, "searchLanguage": "en-US"]
      }
      object["schemaVersion"] = 1
      // Legacy query keys do not carry language, credential, category, or fixture provenance.
      object["queries"] = [String: Any]()
      object["alternativeTitles"] = [String: Any]()
    } else {
      let version = try recordVersion(object, field: "schemaVersion", record: record)

      guard version == 1 else {
        throw MovieFolderStorageMigrationError.unsupportedVersion(record: record, version: version)
      }
    }
    let converted = legacy ? try encodeObject(object, record: record) : payload
    do { _ = try JSONDecoder().decode(ProcessingState.self, from: converted) } catch {
      throw MovieFolderStorageMigrationError.invalidRecord(record: record)
    }

    return (converted, legacy)
  }

}

extension MovieFolderStorageMigrator {
  /// Parses a complete object without accepting fragments or manufacturing missing fields.
  /// - Parameters:
  ///   - payload: Encoded record bytes.
  ///   - record: Record identity used in migration errors.
  /// - Returns: The decoded top-level JSON object.
  /// - Throws: An invalid-record migration error when the payload is not a JSON object.
  func recordObject(_ payload: Data, record: MovieFolderStorageRecordKind) throws -> [String: Any] {
    do {
      guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
        throw MovieFolderStorageMigrationError.invalidRecord(record: record)
      }

      return object
    } catch {
      throw MovieFolderStorageMigrationError.invalidRecord(record: record)
    }
  }

  /// Uses the typed decoder to reject Boolean and malformed version values before conversion.
  /// - Parameters:
  ///   - object: Decoded record fields.
  ///   - field: Name of the schema-version field.
  ///   - record: Record identity used in migration errors.
  /// - Returns: The integer schema version.
  /// - Throws: An invalid-record migration error when the field is missing or malformed.
  func recordVersion(_ object: [String: Any], field: String, record: MovieFolderStorageRecordKind) throws -> Int {
    let value = try requiredValue(object, field: field, record: record)
    do {
      let data = try JSONSerialization.data(withJSONObject: [field: value])

      guard let version = try JSONDecoder().decode([String: Int].self, from: data)[field] else {
        throw MovieFolderStorageMigrationError.invalidRecord(record: record)
      }

      return version
    } catch {
      throw MovieFolderStorageMigrationError.invalidRecord(record: record)
    }
  }

  /// Returns a genuinely present field, rejecting explicit null rather than treating it as an absent default.
  /// - Parameters:
  ///   - object: Decoded record fields.
  ///   - field: Required field name.
  ///   - record: Record identity used in migration errors.
  /// - Returns: The field's non-null JSON value.
  /// - Throws: An invalid-record migration error when the field is absent or null.
  func requiredValue(_ object: [String: Any], field: String, record: MovieFolderStorageRecordKind) throws -> Any {
    guard let value = object[field], !(value is NSNull) else {
      throw MovieFolderStorageMigrationError.invalidRecord(record: record)
    }

    return value
  }

  /// Encodes transformed objects without discarding fields unknown to current model projections.
  /// - Parameters:
  ///   - object: JSON object to encode.
  ///   - record: Record identity used in migration errors.
  /// - Returns: Sorted-key JSON bytes for the object.
  /// - Throws: An invalid-record migration error when the object cannot be encoded.
  func encodeObject(_ object: [String: Any], record: MovieFolderStorageRecordKind) throws -> Data {
    do { return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) } catch {
      throw MovieFolderStorageMigrationError.invalidRecord(record: record)
    }
  }

}
