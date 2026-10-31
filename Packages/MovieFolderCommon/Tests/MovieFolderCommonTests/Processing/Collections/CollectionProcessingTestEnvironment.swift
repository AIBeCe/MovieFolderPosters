import FileSystem
import Foundation
import Persistence

@testable import MovieFolderCommon

/// Local collection and current configuration required by the result change fence.
struct CollectionProcessingTestEnvironment {
  /// Root directory holding all disposable test inputs and records.
  let base: URL
  /// Collection containing only test-created child folders.
  let root: URL
  /// Persisted processing context.
  let context: CollectionProcessingContext
  /// Authoritative processing store under test.
  let processingStore: CollectionProcessingStore
  /// Existing processing decision store.
  let processing: PersistenceStore
  /// Cross-generation collection coordination store.
  let coordination: PersistenceStore
  /// Settings repository shared with the authoritative result store.
  let configuration: ConfigurationRepository
  /// Creates a disposable configured collection with the requested immediate-child directories.
  ///
  /// - Parameter names: Child folder names to create in the test collection.
  /// - Throws: Filesystem setup, identity lookup, or persistence errors.
  init(names: [String], matchingConfiguration: MovieMatchingConfiguration = MovieMatchingConfiguration()) throws {
    base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    root = base.appendingPathComponent("Movies")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for name in names {
      try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: false)
    }
    configuration = ConfigurationRepository(
      store: try PersistenceStore(directory: base.appendingPathComponent("Settings")))
    let identity = try FileSystemService().persistentDirectoryIdentity(at: root)
    let directory = MonitoredDirectory(
      id: UUID(), path: root.path, transferBookmark: Data([1]), authorizationVersion: UUID(), identity: identity)
    try configuration.update {
      $0.directories = [directory]
      $0.movieMatchingConfiguration = matchingConfiguration
    }
    let settings = try configuration.read()
    context = CollectionProcessingContext(
      rootID: directory.id, rootIdentity: identity, authorizationVersion: directory.authorizationVersion,
      credentialRevision: settings.credentialRevision, usesStubTMDbResponses: false, appearance: .softFinish,
      movieMatchingConfiguration: settings.effectiveMovieMatchingConfiguration(for: directory),
      processingConfigurationRevision: directory.processingConfiguration.revision)
    processingStore = CollectionProcessingStore(
      store: try PersistenceStore(
        directory: base.appendingPathComponent("Outcomes"), maximumRecordBytes: 8 * 1024 * 1024),
      configuration: configuration)
    processing = try PersistenceStore(directory: base.appendingPathComponent("Processing"))
    coordination = try PersistenceStore(directory: base.appendingPathComponent("Locks"))
  }

  /// Creates the real processing pipeline with a controlled metadata source.
  func processor(provider: any MovieMetadataProvider) -> MovieFolderProcessor {
    MovieFolderProcessor(
      persistence: processing, provider: provider, cacheDirectory: base.appendingPathComponent("Posters"),
      processingLockStore: coordination, processingStore: processingStore,
      credentialRevision: context.credentialRevision,
      movieMatchingConfiguration: context.movieMatchingConfiguration)
  }
}
