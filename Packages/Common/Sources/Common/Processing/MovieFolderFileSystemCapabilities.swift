import FileSystem
import Foundation

/// Reads immediate collection members and current folder identity.
nonisolated public protocol CollectionInventoryReading: Sendable {
  func inventory(in directory: URL) throws -> CollectionConfiguredDirectoryInventory
  func candidates(in directory: URL) throws -> [MovieFolderCandidate]
  func readCurrentFolderCandidate(ofChild name: String, in directory: URL) throws -> MovieFolderCandidate
}

/// Reads the selected local sources for an identified movie folder.
nonisolated public protocol MovieFolderInformationReading: Sendable {
  func movieInformation(
    toChild name: String, in directory: URL, expectedIdentity: String,
    options: MovieFolderInformationOptions
  ) throws -> MovieFolderInformationReadResult
}

/// Reads and writes cached poster bytes at a location chosen by the processor.
nonisolated public protocol PosterCacheAccessing: Sendable {
  func readData(named name: String, in directory: URL) throws -> Data?
  func writeData(_ data: Data, named name: String, in directory: URL) throws
}

/// Checks ownership and changes only icons owned by the application.
nonisolated public protocol OwnedPosterAccessing: Sendable {
  func hasAssignedPoster(toChild name: String, in directory: URL, expectedIdentity: String?) throws -> Bool
  func inspectPoster(
    toChild name: String, in directory: URL, expectedIdentity: String?
  ) throws -> FolderPosterInspectionResult
  func assignedPosterAppearance(
    toChild name: String, in directory: URL, expectedIdentity: String?
  ) throws -> PosterAppearance?
  func isPosterSuppressed(toChild name: String, in directory: URL) throws -> Bool
  func replaceAssignedPoster(
    _ imageData: Data, toChild name: String, in directory: URL,
    appearance: PosterAppearance, expectedIdentity: String?
  ) throws -> FolderPosterAssignmentResult
  func restyleAssignedPoster(
    _ imageData: Data, toChild name: String, in directory: URL,
    appearance: PosterAppearance, expectedIdentity: String?
  ) throws -> FolderPosterAssignmentResult
  func removeAssignedPoster(toChild name: String, in directory: URL, expectedIdentity: String?) throws -> Bool
}

extension FileSystemService: CollectionInventoryReading, MovieFolderInformationReading, PosterCacheAccessing,
  OwnedPosterAccessing {}
