import Darwin
import Foundation
import Persistence

/// Opens the app-owned processing-state namespace and performs its explicit offline migration.
///
/// The caller supplies the trusted App Group root. Only the fixed immediate children are inspected. A permanent
/// regular-file marker occupies `Outcomes` after initialization, so older stores cannot reopen that directory.
/// Existing open descriptors survive a rename: migration therefore requires the operator to stop older app and
/// Finder extension processes and prevent their relaunch before calling the migration entrypoint.
public enum CollectionProcessingStorageNamespace {
  /// On-disk names and the exact marker format owned by this migration version.
  private enum Constants {
    /// Directory used by the older app and extension.
    static let legacyName = "Outcomes"
    /// Directory used by current app and extension processes.
    static let currentName = "CollectionProcessingState"
    /// Reusable container-wide advisory lock; never unlinked.
    static let leaseName = ".collection-processing-namespace.lock"
    /// Recognizable payload distinguishing our marker from unrelated regular files.
    static let marker = Data("MovieFolderPosters.CollectionProcessingState.namespace.v1\n".utf8)
    /// Existing processing-state envelope limit, retained across the namespace change.
    static let maximumRecordBytes = 8 * 1024 * 1024
  }

  /// Opens current storage, or initializes a fresh container while blocking older namespace creation.
  ///
  /// An existing legacy directory is never migrated implicitly. Initialization and inspection hold a shared
  /// container-wide exclusive lease, released after the persistence store has pinned its directory descriptor.
  /// - Parameter containerURL: An existing trusted App Group directory, never a movie collection directory.
  /// - Returns: The current store with the existing eight-mebibyte record-envelope limit.
  /// - Throws: ``CollectionProcessingStorageNamespaceError/legacyMigrationRequired`` for old storage,
  ///   namespace validation or lease errors, or a persistence error when the current store cannot open.
  public static func open(in containerURL: URL) throws -> PersistenceStore {
    let container = try ContainerLease(containerURL)
    let legacy = try container.entry(named: Constants.legacyName)
    let current = try container.entry(named: Constants.currentName)
    try validate(legacy: legacy, current: current)
    if legacy == .directory { throw CollectionProcessingStorageNamespaceError.legacyMigrationRequired }
    try initializeIfNeeded(container, legacy: legacy, current: current)

    return try withExtendedLifetime(container) {
      try PersistenceStore(
        directory: containerURL.appendingPathComponent(Constants.currentName, isDirectory: true),
        maximumRecordBytes: Constants.maximumRecordBytes)
    }
  }

  /// Atomically moves the original legacy directory into the current namespace during offline maintenance.
  ///
  /// The operator must first stop older app and Finder extension processes and prevent their relaunch. This API
  /// cannot prove that condition. It does not stop processes, register extensions, copy records, change keys, or
  /// unlink reusable locks. A directory/marker exchange preserves directory, record, and lock inode identities.
  /// If exchange is unsupported, the original directory remains intact with a recognizable prepared marker at
  /// the current name. Retrying this API resumes preparation; normal opening still requires explicit migration.
  /// - Parameter containerURL: The existing trusted App Group directory whose older processes are stopped.
  /// - Throws: ``CollectionProcessingStorageNamespaceError`` on conflicts, unsafe entries, a busy migration lease,
  ///   unsupported atomic exchange, or filesystem failures. Existing records are never merged or removed.
  public static func migrateStoppedInstallation(in containerURL: URL) throws {
    let container = try ContainerLease(containerURL)
    let legacy = try container.entry(named: Constants.legacyName)
    let current = try container.entry(named: Constants.currentName)
    try validate(legacy: legacy, current: current)
    guard legacy == .directory else {
      try initializeIfNeeded(container, legacy: legacy, current: current)
      return
    }
    if current == .missing { try container.createMarker(named: Constants.currentName) }
    guard renameatx_np(container.descriptor, Constants.legacyName,
                       container.descriptor, Constants.currentName, UInt32(RENAME_SWAP)) == 0 else {
      let code = errno
      if code == ENOTSUP || code == EINVAL || code == EXDEV {
        throw CollectionProcessingStorageNamespaceError.unsupportedFilesystem
      }
      throw CollectionProcessingStorageNamespaceError.io(code)
    }
    try container.synchronize()
  }

  /// Rejects split stores and incomplete layouts that do not belong to this migration protocol.
  private static func validate(legacy: Entry, current: Entry) throws {
    if legacy == .directory, current == .directory {
      throw CollectionProcessingStorageNamespaceError.conflictingStorage
    }
    if legacy == .missing, current != .missing {
      throw CollectionProcessingStorageNamespaceError.conflictingStorage
    }
    if legacy == .marker, current == .marker {
      throw CollectionProcessingStorageNamespaceError.conflictingStorage
    }
  }

  /// Creates the old-path blocker before the new writable directory, resuming marker-only initialization.
  private static func initializeIfNeeded(_ container: ContainerLease, legacy: Entry, current: Entry) throws {
    if legacy == .missing { try container.createMarker(named: Constants.legacyName) }
    if current == .missing {
      guard mkdirat(container.descriptor, Constants.currentName, S_IRWXU) == 0 else {
        throw CollectionProcessingStorageNamespaceError.io(errno)
      }
      try container.synchronize()
    }
  }

  /// Recognized states of the two fixed namespace entries.
  private enum Entry {
    /// No entry exists at this name.
    case missing
    /// A real directory exists without a followed symlink.
    case directory
    /// A regular file contains the exact owned marker payload.
    case marker
  }

  /// Pins the trusted parent and holds a nonblocking, process-shared initialization/migration lease.
  private final class ContainerLease {
    /// Parent descriptor anchoring every namespace inspection and mutation.
    let descriptor: Int32
    /// Permanent regular-file descriptor whose flock serializes new namespace entrypoints.
    private let lockDescriptor: Int32

    /// Opens the existing trusted parent and acquires its reusable migration lock.
    init(_ url: URL) throws {
      guard url.isFileURL else { throw CollectionProcessingStorageNamespaceError.invalidStorageEntry }
      descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard descriptor >= 0 else { throw CollectionProcessingStorageNamespaceError.io(errno) }
      let lock = openat(descriptor, Constants.leaseName,
                        O_CREAT | O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
      guard lock >= 0 else {
        let code = errno
        close(descriptor)
        throw CollectionProcessingStorageNamespaceError.io(code)
      }
      var info = stat()
      guard fstat(lock, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else {
        close(lock)
        close(descriptor)
        throw CollectionProcessingStorageNamespaceError.invalidStorageEntry
      }
      guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
        let code = errno
        close(lock)
        close(descriptor)
        if code == EWOULDBLOCK || code == EAGAIN { throw CollectionProcessingStorageNamespaceError.busy }
        throw CollectionProcessingStorageNamespaceError.io(code)
      }
      lockDescriptor = lock
    }

    /// Releases the namespace lease without deleting the reusable lock file.
    deinit {
      flock(lockDescriptor, LOCK_UN)
      close(lockDescriptor)
      close(descriptor)
    }

    /// Classifies a fixed child without following symlinks or reading special files.
    func entry(named name: String) throws -> Entry {
      var info = stat()
      guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
        if errno == ENOENT { return .missing }
        throw CollectionProcessingStorageNamespaceError.io(errno)
      }
      if (info.st_mode & S_IFMT) == S_IFDIR { return .directory }
      guard (info.st_mode & S_IFMT) == S_IFREG, info.st_size == Constants.marker.count,
        info.st_nlink == 1 else { throw CollectionProcessingStorageNamespaceError.invalidStorageEntry }
      let markerDescriptor = openat(descriptor, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
      guard markerDescriptor >= 0 else { throw CollectionProcessingStorageNamespaceError.io(errno) }
      defer { close(markerDescriptor) }
      var openedInfo = stat()
      guard fstat(markerDescriptor, &openedInfo) == 0, openedInfo.st_dev == info.st_dev,
        openedInfo.st_ino == info.st_ino, openedInfo.st_size == Constants.marker.count,
        (openedInfo.st_mode & S_IFMT) == S_IFREG else {
        throw CollectionProcessingStorageNamespaceError.invalidStorageEntry
      }
      var bytes = [UInt8](repeating: 0, count: Constants.marker.count + 1)
      let count = Darwin.read(markerDescriptor, &bytes, bytes.count)
      guard count == Constants.marker.count, Data(bytes.prefix(count)) == Constants.marker else {
        throw CollectionProcessingStorageNamespaceError.invalidStorageEntry
      }

      return .marker
    }

    /// Exclusively creates, writes, and synchronizes the recognizable regular-file namespace blocker.
    func createMarker(named name: String) throws {
      let markerDescriptor = openat(descriptor, name,
                                    O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
      guard markerDescriptor >= 0 else { throw CollectionProcessingStorageNamespaceError.io(errno) }
      defer { close(markerDescriptor) }
      try Constants.marker.withUnsafeBytes { bytes in
        guard let address = bytes.baseAddress else { return }
        var offset = 0
        while offset < bytes.count {
          let count = Darwin.write(markerDescriptor, address.advanced(by: offset), bytes.count - offset)
          if count < 0 {
            if errno == EINTR { continue }
            throw CollectionProcessingStorageNamespaceError.io(errno)
          }
          guard count > 0 else { throw CollectionProcessingStorageNamespaceError.io(EIO) }
          offset += count
        }
      }
      guard fsync(markerDescriptor) == 0 else { throw CollectionProcessingStorageNamespaceError.io(errno) }
      try synchronize()
    }

    /// Persists namespace metadata after preparing or exchanging entries.
    func synchronize() throws {
      guard fsync(descriptor) == 0 else { throw CollectionProcessingStorageNamespaceError.io(errno) }
    }
  }
}

/// Failures opening or explicitly migrating the app-owned collection-processing namespace.
public enum CollectionProcessingStorageNamespaceError: Error, Sendable, Equatable {
  /// A legacy directory must be migrated after older processes have been stopped and prevented from relaunching.
  case legacyMigrationRequired
  /// Multiple directories or an incomplete foreign layout prevent choosing one authoritative store.
  case conflictingStorage
  /// A namespace entry is a symlink, special file, hard-linked marker, or unrecognized regular file.
  case invalidStorageEntry
  /// Another current process holds the shared initialization/migration lease; the caller may retry later.
  case busy
  /// The filesystem cannot perform the required atomic directory/marker exchange; no fallback move is attempted.
  case unsupportedFilesystem
  /// A filesystem operation failed with the captured POSIX error code.
  case io(Int32)
}
