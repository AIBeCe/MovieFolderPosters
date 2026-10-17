import Darwin
import Foundation

/// Retains a resolved directory URL and its security-scoped access for the lease's lifetime.
public final class DirectoryAccessLease: Sendable {
  /// The resolved directory URL whose access is held for this lease's lifetime.
  public let url: URL

  /// Whether releasing this lease must stop security-scoped access.
  private let isAccessingSecurityScopedResource: Bool

  /// Creates a lease for a resolved URL and transfers responsibility for scoped access cleanup.
  fileprivate init(url: URL, isAccessingSecurityScopedResource: Bool) {
    self.url = url
    self.isAccessingSecurityScopedResource = isAccessingSecurityScopedResource
  }

  deinit {
    if isAccessingSecurityScopedResource {
      url.stopAccessingSecurityScopedResource()
    }
  }
}

extension FileSystemService {
  /// Creates bookmark data suitable for transferring directory authorization to another process.
  ///
  /// - Parameter directory: The validated directory to authorize.
  /// - Returns: Bookmark data for resolving the same directory later.
  /// - Throws: ``DirectoryAccessError`` or a Foundation error if validation or bookmark creation fails.
  public func makeTransferBookmark(for directory: URL) throws -> Data {
    try validateDirectory(directory)
    return try directory.bookmarkData(
      options: [],
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    )
  }

  /// Resolves a bookmark and holds its security-scoped access until the returned lease is released.
  ///
  /// - Parameters:
  ///   - bookmark: Bookmark data previously created for a directory.
  ///   - securityScoped: Whether bookmark resolution and access require security scope.
  ///   - expectedIdentity: An optional identity that must match the resolved directory.
  /// - Returns: A lease retaining access to the validated directory.
  /// - Throws: ``DirectoryAccessError`` when access, bookmark validity, or identity checks fail.
  public func acquireDirectoryAccess(
    bookmark: Data,
    securityScoped: Bool,
    expectedIdentity: String? = nil
  ) throws -> DirectoryAccessLease {
    var resolutionOptions: URL.BookmarkResolutionOptions = [.withoutUI, .withoutMounting]
    if securityScoped {
      resolutionOptions.insert(.withSecurityScope)
    }

    var isStale = false
    let directory: URL
    do {
      directory = try URL(
        resolvingBookmarkData: bookmark,
        options: resolutionOptions,
        relativeTo: nil,
        bookmarkDataIsStale: &isStale
      )
    } catch {
      throw DirectoryAccessError.invalidDirectory
    }

    guard !isStale || expectedIdentity != nil else {
      throw DirectoryAccessError.staleBookmark
    }

    let startedAccessing = directory.startAccessingSecurityScopedResource()
    if securityScoped, !startedAccessing {
      throw DirectoryAccessError.accessDenied
    }
    var transferAccessToLease = false
    defer {
      if startedAccessing, !transferAccessToLease {
        directory.stopAccessingSecurityScopedResource()
      }
    }

    try validateDirectory(directory)
    try validateDirectoryDescriptorAccess(
      directory, service: self, expectedIdentity: expectedIdentity)

    transferAccessToLease = startedAccessing
    return DirectoryAccessLease(
      url: directory,
      isAccessingSecurityScopedResource: startedAccessing
    )
  }
}

/// Verifies that the opened directory and the bookmark's current path still identify the same object.
private func validateDirectoryDescriptorAccess(
  _ directory: URL,
  service: FileSystemService,
  expectedIdentity: String?
) throws {
  let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
  guard descriptor >= 0 else {
    switch errno {
    case EACCES, EPERM:
      throw DirectoryAccessError.accessDenied
    case ELOOP:
      throw DirectoryAccessError.invalidDirectory
    default:
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
  }
  defer { _ = close(descriptor) }

  var openedInfo = stat()
  guard fstat(descriptor, &openedInfo) == 0 else {
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
  }
  guard (openedInfo.st_mode & S_IFMT) == S_IFDIR else {
    throw DirectoryAccessError.invalidDirectory
  }

  let openedObjectIdentity =
    "\(openedInfo.st_dev):\(openedInfo.st_ino):"
    + "\(openedInfo.st_birthtimespec.tv_sec):\(openedInfo.st_birthtimespec.tv_nsec)"
  let currentPathObjectIdentity = try service.fileIdentity(at: directory)
  try validateDirectoryObjectIdentity(
    openedIdentity: openedObjectIdentity,
    currentPathIdentity: currentPathObjectIdentity
  )
  do {
    let openedPersistentIdentity = try persistentIdentity(
      at: directory,
      descriptor: descriptor,
      service: service
    )
    try validateDirectoryIdentity(
      openedIdentity: openedPersistentIdentity,
      currentPathIdentity: openedPersistentIdentity,
      expectedIdentity: expectedIdentity
    )
  } catch is DirectoryIdentityUnavailable where expectedIdentity == nil {
    // The descriptor and current path already match; durable identity is optional for this lease.
  }
}

/// Rejects a directory when its open descriptor no longer matches its current path.
func validateDirectoryObjectIdentity(openedIdentity: String, currentPathIdentity: String) throws {
  guard openedIdentity == currentPathIdentity else {
    throw DirectoryAccessError.identityChanged
  }
}

/// Checks both descriptor/path agreement and an optional identity supplied by the caller.
func validateDirectoryIdentity(
  openedIdentity: String,
  currentPathIdentity: String,
  expectedIdentity: String?
) throws {
  guard openedIdentity == currentPathIdentity,
    expectedIdentity == nil || expectedIdentity == openedIdentity
  else {
    throw DirectoryAccessError.identityChanged
  }
}
