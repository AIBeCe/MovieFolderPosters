import Foundation
import Testing

@testable import MovieFolderCommon

/// Current settings preserve the global budget independently of collection overrides.
@Test func searchPageLimitDefaultsAndRoundTrips() throws {
  var configuration = DirectoryConfiguration()
  #expect(configuration.searchPageLimit == 3)
  for limit in 1...5 {
    configuration.searchPageLimit = limit
    let decoded = try JSONDecoder().decode(DirectoryConfiguration.self, from: JSONEncoder().encode(configuration))
    #expect(decoded.searchPageLimit == limit)
  }
}

/// Invalid current-schema budgets cannot be serialized or decoded as usable settings.
@Test(arguments: [0, 6, -1]) func searchPageLimitRejectsInvalidValues(limit: Int) throws {
  var configuration = DirectoryConfiguration()
  configuration.searchPageLimit = limit
  #expect(throws: ConfigurationError.invalidConfiguration) { try JSONEncoder().encode(configuration) }
  #expect(throws: ConfigurationError.invalidConfiguration) { try ConfigurationRepository.validate(configuration) }
}

/// Schema six upgrades explicitly while preserving every other decoded setting and generation.
@Test func searchPageLimitMigratesSchemaSixWithoutChangingOtherSettings() throws {
  var current = DirectoryConfiguration()
  current.isNetworkHistoryRecordingEnabled = true
  current.usesStubTMDbResponses = true
  current.movieMatchingConfiguration.comparesOriginalTitles = false
  var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
  object["version"] = 6
  object.removeValue(forKey: "searchPageLimit")
  let legacy = try JSONSerialization.data(withJSONObject: object)
  #expect(throws: MovieFolderStorageMigrationError.migrationRequired(record: .settings, version: 6)) {
    try JSONDecoder().decode(DirectoryConfiguration.self, from: legacy)
  }
  #expect(try convertLegacySettingsFixture(legacy) == current)
  object["searchPageLimit"] = 4
  let conflicting = try JSONSerialization.data(withJSONObject: object)
  #expect(throws: MovieFolderStorageMigrationError.conflictingValues(record: .settings, field: "searchPageLimit")) {
    try convertLegacySettingsFixture(conflicting)
  }
}

/// Current-schema missing and out-of-range limits fail closed without decoder defaults.
@Test func searchPageLimitCurrentSchemaRequiresValidField() throws {
  let configuration = DirectoryConfiguration()
  var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as? [String: Any])
  object.removeValue(forKey: "searchPageLimit")
  let missing = try JSONSerialization.data(withJSONObject: object)
  #expect(throws: (any Error).self) { try JSONDecoder().decode(DirectoryConfiguration.self, from: missing) }
  object["searchPageLimit"] = 6
  let invalid = try JSONSerialization.data(withJSONObject: object)
  #expect(throws: (any Error).self) { try JSONDecoder().decode(DirectoryConfiguration.self, from: invalid) }
}
