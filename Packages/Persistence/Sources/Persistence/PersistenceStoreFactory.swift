import Foundation

/// Creates persistence stores using one caller-owned path authorization boundary.
public struct PersistenceStoreFactory: Sendable {
  /// Existing directory anchoring stores opened by this factory, when supplied by the caller.
  private let trustedRoot: URL?

  /// Creates a factory for ordinary filesystem paths or paths beneath a validated trusted root.
  /// - Parameter trustedRoot: Existing caller-validated directory anchoring every created store.
  public init(trustedRoot: URL? = .none) {
    self.trustedRoot = trustedRoot
  }

  /// Opens or creates a store while preserving the factory's path authorization boundary.
  /// - Parameters:
  ///   - directory: Directory containing the store records.
  ///   - maximumRecordBytes: Optional maximum encoded record size.
  /// - Returns: A store pinned to its directory descriptor.
  /// - Throws: An I/O error, an invalid directory, or an invalid-size error.
  public func makeStore(directory: URL, maximumRecordBytes: Int? = .none) throws -> PersistenceStore {
    guard let trustedRoot else {
      return try PersistenceStore(directory: directory, maximumRecordBytes: maximumRecordBytes)
    }

    return try PersistenceStore(
      directory: directory, trustedRoot: trustedRoot, maximumRecordBytes: maximumRecordBytes)
  }
}
