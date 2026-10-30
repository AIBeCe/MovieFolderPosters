import FileSystem
import FinderSync
import MovieFolderCommon
import Network
import Persistence

/// Supplies signed-process boundaries while the runtime retains authorization and processing configuration.
nonisolated protocol FinderRuntimeEnvironment: Sendable {
  /// Best-effort activity service retained independently of authorization.
  var activity: any MovieFolderActivityServicing { get }
  /// Optional signed build evidence written on activation.
  var buildVersion: (String, String)? { get }
  /// Opens the current settings source.
  func configurationRepository() throws -> ConfigurationRepository
  /// Opens extension-private persistent grants.
  func authorizationStore() throws -> PersistenceStore
  /// Resolves the process's shared storage location.
  func containerURL() throws -> URL
  /// Reads the shared credential without exposing it to diagnostics.
  func credential() throws -> String?
  /// Builds the metadata provider using the same captured settings generation.
  func movieMetadataProvider(token: String, configuration: DirectoryConfiguration) throws -> any MovieMetadataProvider
  /// Builds a provider whose optional HTTP history is scoped to exactly one configured collection.
  /// - Parameters:
  ///   - token: Saved credential used only by the provider.
  ///   - configuration: Settings captured for this processing generation.
  ///   - collectionID: Stable root identity used for current history eligibility.
  func movieMetadataProvider(
    token: String, configuration: DirectoryConfiguration, collectionID: UUID
  ) throws -> any MovieMetadataProvider
  /// Opens authoritative collection outcomes.
  func processingStore() throws -> CollectionProcessingStore
  /// Opens the durable processing gate within this environment's shared storage.
  func processingRecoveryService() throws -> ProcessingRecoveryService
  /// Resolves and retains authorization for a transferred or extension-owned bookmark.
  func acquireDirectoryAccess(bookmark: Data, securityScoped: Bool, expectedIdentity: String?) throws
    -> DirectoryAccess
  /// Creates the extension's persistent grant after transferred access succeeds.
  func makeDirectoryBookmark(for url: URL) throws -> Data
  /// Publishes the currently authorized roots to Finder.
  @MainActor func register(_ roots: Set<URL>)
}

/// Keeps test and production admission state in the same container as their existing runtime stores.
extension FinderRuntimeEnvironment {
  /// Preserves explicitly injected providers that perform no production HTTP recording.
  func movieMetadataProvider(
    token: String, configuration: DirectoryConfiguration, collectionID: UUID
  ) throws -> any MovieMetadataProvider {
    try movieMetadataProvider(token: token, configuration: configuration)
  }

  func processingRecoveryService() throws -> ProcessingRecoveryService {
    ProcessingRecoveryService(store: try PersistenceStore(
      directory: containerURL().appendingPathComponent("ProcessingRecovery"), maximumRecordBytes: 8_192))
  }
}

/// Adapts the signed extension's system services without adding processing configuration.
nonisolated struct SystemFinderRuntimeEnvironment: FinderRuntimeEnvironment {
  /// Shared recorder used by Finder configuration and processing events.
  var activity: any MovieFolderActivityServicing { MovieFolderEnvironment.makeActivityRecorder() }
  /// Host version and build recorded with activation evidence when both are available.
  var buildVersion: (String, String)? {
    guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
      let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String else { return .none }

    return (version, build)
  }

  func configurationRepository() throws -> ConfigurationRepository {
    try MovieFolderEnvironment.makeConfigurationRepository()
  }

  func authorizationStore() throws -> PersistenceStore { try MovieFolderEnvironment.makePrivateAuthorizationStore() }
  func containerURL() throws -> URL { try MovieFolderEnvironment.appGroupContainerURL() }
  func credential() throws -> String? {
    try MovieFolderEnvironment.makeCredentialStore().read()
  }

  func movieMetadataProvider(token: String, configuration: DirectoryConfiguration) throws -> any MovieMetadataProvider {
    try makeMovieMetadataProvider(token: token, configuration: configuration, collectionID: .none)
  }

  func movieMetadataProvider(
    token: String, configuration: DirectoryConfiguration, collectionID: UUID
  ) throws -> any MovieMetadataProvider {
    try makeMovieMetadataProvider(token: token, configuration: configuration, collectionID: collectionID)
  }

  /// Keeps fixture traffic outside history while binding live requests to the caller's root.
  private func makeMovieMetadataProvider(
    token: String, configuration: DirectoryConfiguration, collectionID: UUID?
  ) throws -> any MovieMetadataProvider {
    #if DEBUG
      if configuration.usesStubTMDbResponses {
        guard let image = Bundle.main.url(forResource: "TestPoster", withExtension: "png") else {
          throw FolderPosterError.invalidImage
        }

        return TMDbClient(token: try TMDbAccessToken(token), transport: StubTMDbTransport(
          posterData: try Data(contentsOf: image)))
      }
    #endif

    let requestDelegate = collectionID.map {
      MovieFolderNetworkRequestRecorder(
        networkHistoryService: MovieFolderEnvironment.makeNetworkHistoryService(), collectionID: $0)
    }

    return TMDbClient(token: try TMDbAccessToken(token), requestDelegate: requestDelegate)
  }

  func processingStore() throws -> CollectionProcessingStore {
    try MovieFolderEnvironment.makeCollectionProcessingStore()
  }
  func processingRecoveryService() throws -> ProcessingRecoveryService {
    try MovieFolderEnvironment.makeProcessingRecoveryService()
  }
  func acquireDirectoryAccess(
    bookmark: Data, securityScoped: Bool, expectedIdentity: String?
  ) throws -> DirectoryAccess {
    try FileSystemService().acquireDirectoryAccess(
      bookmark: bookmark, securityScoped: securityScoped, expectedIdentity: expectedIdentity)
  }

  func makeDirectoryBookmark(for url: URL) throws -> Data { try FileSystemService().makeDirectoryBookmark(for: url) }
  @MainActor func register(_ roots: Set<URL>) { FIFinderSyncController.default().directoryURLs = roots }
}
