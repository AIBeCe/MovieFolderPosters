import FileSystem
import FinderSync
import MovieFolderCommon
import Network
import Persistence

/// Supplies signed-process boundaries while the runtime retains authorization and processing policy.
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
  func provider(token: String, configuration: DirectoryConfiguration) throws -> any MovieMetadataProvider
  /// Opens authoritative collection outcomes.
  func processingStore() throws -> CollectionProcessingStore
  /// Resolves and retains authorization for a transferred or extension-owned bookmark.
  func acquireDirectoryAccess(bookmark: Data, securityScoped: Bool, expectedIdentity: String?) throws
    -> DirectoryAccessLease
  /// Creates the extension's persistent grant after transferred access succeeds.
  func makeDirectoryBookmark(for url: URL) throws -> Data
  /// Publishes the currently authorized roots to Finder.
  @MainActor func register(_ roots: Set<URL>)
}

/// Adapts the signed extension's system services without adding processing policy.
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
    try KeychainCredentialStore(accessGroup: MovieFolderEnvironment.groupIdentifier).read()
  }

  func provider(token: String, configuration: DirectoryConfiguration) throws -> any MovieMetadataProvider {
    #if DEBUG
      if configuration.usesStubTMDbResponses {
        guard let image = Bundle.main.url(forResource: "TestPoster", withExtension: "png") else {
          throw FolderPosterError.invalidImage
        }

        return TMDbClient(token: try TMDbAccessToken(token), transport: StubTMDbTransport(
          posterData: try Data(contentsOf: image)))
      }
    #endif

    return TMDbClient(token: try TMDbAccessToken(token))
  }

  func processingStore() throws -> CollectionProcessingStore {
    try MovieFolderEnvironment.makeCollectionProcessingStore()
  }
  func acquireDirectoryAccess(
    bookmark: Data, securityScoped: Bool, expectedIdentity: String?
  ) throws -> DirectoryAccessLease {
    try FileSystemService().acquireDirectoryAccess(
      bookmark: bookmark, securityScoped: securityScoped, expectedIdentity: expectedIdentity)
  }

  func makeDirectoryBookmark(for url: URL) throws -> Data { try FileSystemService().makeDirectoryBookmark(for: url) }
  @MainActor func register(_ roots: Set<URL>) { FIFinderSyncController.default().directoryURLs = roots }
}
