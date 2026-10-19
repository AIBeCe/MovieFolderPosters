import Darwin
import Foundation

/// A direct child directory and the identity information used to detect replacement.
public struct FolderCandidate: Equatable, Sendable {
  /// The child's file-system name.
  public let name: String
  /// The current device, inode, and creation-time identity.
  public let identity: String
  /// A value that changes when the child identity or name changes.
  public let fingerprint: String
  /// Whether Finder currently reports a custom icon for the child.
  public let hasCustomIcon: Bool

  /// Creates a candidate snapshot from the child's name and observed metadata.
  public init(name: String, identity: String, fingerprint: String, hasCustomIcon: Bool) {
    self.name = name
    self.identity = identity
    self.fingerprint = fingerprint
    self.hasCustomIcon = hasCustomIcon
  }
}

/// Explains why a known directory could not produce a complete candidate snapshot.
public enum DirectoryInventoryIssue: Equatable, Sendable {
  /// The directory's current identity could not be confirmed after classification.
  case identityInspectionFailed
  /// The directory's Finder icon state could not be read.
  case iconInspectionFailed
}

/// One visible immediate directory and any successfully inspected candidate state.
public struct DirectoryInventoryEntry: Equatable, Sendable {
  /// The direct child's filesystem name.
  public let name: String
  /// The identity captured while confirming that the child is a real directory.
  public let identity: String?
  /// Complete identity and icon state, when both were inspected successfully.
  public let candidate: FolderCandidate?
  /// The inspection failure for a known directory, if any.
  public let issue: DirectoryInventoryIssue?

  /// Creates one inventory entry.
  public init(
    name: String, identity: String?, candidate: FolderCandidate?, issue: DirectoryInventoryIssue?
  ) {
    self.name = name
    self.identity = identity
    self.candidate = candidate
    self.issue = issue
  }
}

/// A caller-owned snapshot of visible immediate directory membership.
public struct DirectoryInventory: Equatable, Sendable {
  /// Known visible immediate directories, sorted by localized standard name order.
  public let members: [DirectoryInventoryEntry]
  /// Whether every visible immediate entry could be classified safely.
  public let isComplete: Bool

  /// Creates an inventory snapshot.
  public init(members: [DirectoryInventoryEntry], isComplete: Bool) {
    self.members = members
    self.isComplete = isComplete
  }
}

/// Failures raised while validating or accessing an authorized directory.
public enum DirectoryAccessError: Error {
  case invalidDirectory
  case staleBookmark
  case accessDenied
  case identityChanged
}

/// Performs bounded reads and writes in explicitly authorized movie directories.
public struct FileSystemService: Sendable {
  /// Creates a stateless filesystem service.
  public init() {}

  /// Creates a security-scoped bookmark for a validated directory.
  ///
  /// - Parameter directory: The directory to authorize.
  /// - Returns: Bookmark data suitable for later access.
  /// - Throws: ``DirectoryAccessError`` or a Foundation error when validation or bookmark creation fails.
  public func makeDirectoryBookmark(for directory: URL) throws -> Data {
    try validateDirectory(directory)

    return try directory.bookmarkData(
      options: [.withSecurityScope],
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    )
  }

  /// Resolves a bookmark, runs an operation while access is active, then releases the access.
  ///
  /// - Parameters:
  ///   - bookmark: Security-scoped bookmark data.
  ///   - operation: Synchronous work to perform with the resolved directory URL.
  /// - Returns: The operation's result.
  /// - Throws: ``DirectoryAccessError`` or an error thrown by the operation.
  public func withDirectoryAccess<Result>(
    bookmark: Data,
    operation: (URL) throws -> Result
  ) throws -> Result {
    var isStale = false
    let directory = try URL(
      resolvingBookmarkData: bookmark,
      options: [.withSecurityScope, .withoutUI],
      relativeTo: nil,
      bookmarkDataIsStale: &isStale
    )

    guard !isStale else {
      throw DirectoryAccessError.staleBookmark
    }

    guard directory.startAccessingSecurityScopedResource() else {
      throw DirectoryAccessError.accessDenied
    }
    defer { directory.stopAccessingSecurityScopedResource() }

    try validateDirectory(directory)
    return try operation(directory)
  }

  /// Confirms the directory can be listed, written to, read back, and cleaned up.
  ///
  /// - Parameter directory: The authorized directory to probe.
  /// - Throws: Cancellation, access, or filesystem errors if any required operation fails.
  public func verifyReadWriteAccess(in directory: URL) throws {
    try Task.checkCancellation()
    try validateDirectory(directory)
    do {
      try Task.checkCancellation()
      _ = try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
      let probe = directory.appendingPathComponent(".MovieFolderPostersAccess-\(UUID().uuidString)")
      let expected = Data("MovieFolderPosters access check".utf8)
      try Task.checkCancellation()
      try expected.write(to: probe, options: [.withoutOverwriting])
      let actual: Data
      do {
        actual = try Data(contentsOf: probe)
      } catch {
        try FileManager.default.removeItem(at: probe)
        throw error
      }
      // Finish cleanup even if observation ends while the synchronous operation is running.
      try FileManager.default.removeItem(at: probe)
      guard actual == expected else { throw CocoaError(.fileReadCorruptFile) }
    }
  }

  /// Lists visible immediate children and captures their identities and custom-icon state.
  ///
  /// - Parameter directory: The directory whose immediate children are inspected.
  /// - Returns: Candidates sorted by localized standard name order.
  /// - Throws: ``DirectoryAccessError`` or a filesystem error if listing or inspection fails.
  public func candidates(in directory: URL) throws -> [FolderCandidate] {
    try validateDirectory(directory)
    let children = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
    )
    return try children.compactMap { child in
      guard let identity = try? fileIdentity(at: child) else { return nil }
      return FolderCandidate(
        name: child.lastPathComponent, identity: identity,
        fingerprint: "\(identity):\(child.lastPathComponent)",
        hasCustomIcon: try hasCustomIcon(at: child))
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  /// Inventories known visible immediate directories without descending into their contents.
  ///
  /// - Parameter directory: The authorized parent directory.
  /// - Returns: Known directory members and whether all visible entries were classified.
  /// - Throws: ``DirectoryAccessError`` or a filesystem error if the parent cannot be listed.
  public func inventory(in directory: URL) throws -> DirectoryInventory {
    try validateDirectory(directory)
    let children = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
    )
    var members = [DirectoryInventoryEntry]()
    var isComplete = true

    for child in children {
      var info = stat()
      guard lstat(child.path, &info) == 0 else {
        isComplete = false
        continue
      }
      guard (info.st_mode & S_IFMT) == S_IFDIR else { continue }

      let name = child.lastPathComponent
      let identity =
        "\(info.st_dev):\(info.st_ino):\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec)"
      guard (try? fileIdentity(at: child)) == identity else {
        members.append(.init(
          name: name, identity: identity, candidate: nil, issue: .identityInspectionFailed))
        continue
      }
      do {
        let hasCustomIcon = try self.hasCustomIcon(at: child)
        let candidate = FolderCandidate(
          name: name, identity: identity, fingerprint: "\(identity):\(name)",
          hasCustomIcon: hasCustomIcon)
        members.append(.init(name: name, identity: identity, candidate: candidate, issue: nil))
      } catch {
        members.append(.init(name: name, identity: identity, candidate: nil, issue: .iconInspectionFailed))
      }
    }

    members.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    return DirectoryInventory(members: members, isComplete: isComplete)
  }

  /// Reads the current identity and icon state for one named child.
  ///
  /// - Parameters:
  ///   - name: A valid immediate child name.
  ///   - directory: The parent directory.
  /// - Returns: A current candidate snapshot for the child.
  /// - Throws: ``DirectoryAccessError`` or a filesystem error when the child cannot be inspected.
  public func readCurrentState(ofChild name: String, in directory: URL) throws -> FolderCandidate {
    try validateDirectory(directory)
    guard isValidChildName(name) else { throw DirectoryAccessError.invalidDirectory }
    let child = directory.appendingPathComponent(name, isDirectory: true)
    let identity = try fileIdentity(at: child)
    return FolderCandidate(
      name: name, identity: identity, fingerprint: "\(identity):\(name)",
      hasCustomIcon: try hasCustomIcon(at: child))
  }

  /// Reads a regular cache file without following symlinks.
  ///
  /// - Parameters:
  ///   - name: A supported cache filename.
  ///   - directory: The cache directory, created only by write operations.
  /// - Returns: The file contents, or `nil` when the directory or file is absent.
  /// - Throws: ``DirectoryAccessError`` or a filesystem error for invalid paths or failed reads.
  public func readData(named name: String, in directory: URL) throws -> Data? {
    try validateCacheName(name)
    let directoryDescriptor: Int32
    do {
      directoryDescriptor = try openCacheDirectory(directory, create: false)
    } catch let error as NSError
      where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
      return nil
    }
    defer { _ = close(directoryDescriptor) }
    let descriptor = name.withCString {
      openat(directoryDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    }
    if descriptor < 0, errno == ENOENT { return nil }
    guard descriptor >= 0 else { throw posixError() }
    defer { _ = close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0 else { throw posixError() }
    guard (info.st_mode & S_IFMT) == S_IFREG else { throw DirectoryAccessError.invalidDirectory }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
      let count = read(descriptor, &buffer, buffer.count)
      if count == 0 { break }
      if count < 0 {
        if errno == EINTR { continue }
        throw posixError()
      }
      result.append(contentsOf: buffer[0..<count])
    }
    return result
  }

  /// Atomically replaces a cache file using a private temporary file in the cache directory.
  ///
  /// - Parameters:
  ///   - data: The bytes to persist.
  ///   - name: A supported cache filename.
  ///   - directory: The cache directory, created with owner-only permissions when needed.
  /// - Throws: ``DirectoryAccessError`` or a filesystem error if validation or writing fails.
  public func writeData(_ data: Data, named name: String, in directory: URL) throws {
    try validateCacheName(name)
    let directoryDescriptor = try openCacheDirectory(directory, create: true)
    defer { _ = close(directoryDescriptor) }
    try validateCacheFile(name, in: directoryDescriptor)

    let temporaryName = ".mfp-\(UUID().uuidString)"
    let temporaryDescriptor = temporaryName.withCString {
      openat(directoryDescriptor, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
    }
    guard temporaryDescriptor >= 0 else { throw posixError() }
    var shouldRemoveTemporary = true
    defer {
      _ = close(temporaryDescriptor)
      if shouldRemoveTemporary {
        temporaryName.withCString { _ = unlinkat(directoryDescriptor, $0, 0) }
      }
    }
    try data.withUnsafeBytes { bytes in
      guard let base = bytes.baseAddress else { return }
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(
          temporaryDescriptor, base.advanced(by: offset), bytes.count - offset)
        if count < 0 {
          if errno == EINTR { continue }
          throw posixError()
        }
        guard count > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }
        offset += count
      }
    }
    guard fsync(temporaryDescriptor) == 0 else { throw posixError() }
    let result = temporaryName.withCString { temporary in
      name.withCString { destination in
        renameat(directoryDescriptor, temporary, directoryDescriptor, destination)
      }
    }
    guard result == 0 else { throw posixError() }
    shouldRemoveTemporary = false
  }

  /// Verifies the URL is a file URL to an existing directory.
  func validateDirectory(_ directory: URL) throws {
    guard directory.isFileURL else {
      throw DirectoryAccessError.invalidDirectory
    }

    guard (try? fileIdentity(at: directory)) != nil else {
      throw DirectoryAccessError.invalidDirectory
    }
  }

  /// Returns a volatile identity for an existing directory without following its final symlink.
  func fileIdentity(at url: URL) throws -> String {
    guard url.isFileURL else { throw DirectoryAccessError.invalidDirectory }
    var info = stat()
    guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
      throw DirectoryAccessError.invalidDirectory
    }
    return
      "\(info.st_dev):\(info.st_ino):\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec)"
  }

  /// Accepts only a single visible path component suitable for a direct child lookup.
  func isValidChildName(_ name: String) -> Bool {
    !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\\")
      && name != "." && name != ".."
  }

  /// Restricts cache names to visible ASCII-safe components supported by the cache format.
  private func validateCacheName(_ name: String) throws {
    guard !name.isEmpty, !name.hasPrefix("."),
      name.unicodeScalars.allSatisfy({
        CharacterSet.alphanumerics.contains($0) || "_-".unicodeScalars.contains($0)
      })
    else { throw DirectoryAccessError.invalidDirectory }
  }

  /// Opens each directory component without following symlinks, optionally creating missing components.
  private func openCacheDirectory(_ directory: URL, create: Bool) throws -> Int32 {
    guard directory.isFileURL else { throw DirectoryAccessError.invalidDirectory }
    let path = directory.standardizedFileURL.path
    guard path.hasPrefix("/") else { throw DirectoryAccessError.invalidDirectory }
    var descriptor = open("/", O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw posixError() }
    let components = path.split(separator: "/").map(String.init)
    if components.isEmpty {
      _ = close(descriptor)
      descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard descriptor >= 0 else { throw posixError() }
      return descriptor
    }

    for (index, component) in components.enumerated() {
      let names = try cacheTraversalComponents(component, index: index)
      for (nameIndex, name) in names.enumerated() {
        let isFinalDirectory = index == components.count - 1 && nameIndex == names.count - 1
        let directoryFlags =
          isFinalDirectory
          ? O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
          : O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var child = name.withCString {
          openat(descriptor, $0, directoryFlags)
        }
        if child < 0, create, errno == ENOENT {
          let made = name.withCString { mkdirat(descriptor, $0, mode_t(0o700)) }
          if made != 0, errno != EEXIST {
            let error = cachePathError(for: posixError())
            _ = close(descriptor)
            throw error
          }
          child = name.withCString {
            openat(descriptor, $0, directoryFlags)
          }
        }
        guard child >= 0 else {
          let error = cachePathError(for: posixError())
          _ = close(descriptor)
          throw error
        }
        _ = close(descriptor)
        descriptor = child
      }
    }
    return descriptor
  }

  /// Expands macOS's `/var` alias only after confirming it resolves to `/private/var`.
  private func cacheTraversalComponents(_ component: String, index: Int) throws -> [String] {
    guard index == 0, component == "var" else { return [component] }
    var info = stat()
    guard lstat("/var", &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK else { return [component] }
    guard let resolvedPath = realpath("/var", nil) else { throw posixError() }
    let resolved = String(cString: resolvedPath)
    free(resolvedPath)
    guard resolved == "/private/var" else { throw DirectoryAccessError.invalidDirectory }
    return ["private", "var"]
  }

  /// Rejects an existing cache destination unless it is a regular file.
  private func validateCacheFile(_ name: String, in directoryDescriptor: Int32) throws {
    let descriptor = name.withCString {
      openat(directoryDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    }
    if descriptor < 0 {
      if errno == ENOENT { return }
      throw posixError()
    }
    defer { _ = close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0 else { throw posixError() }
    guard (info.st_mode & S_IFMT) == S_IFREG else { throw DirectoryAccessError.invalidDirectory }
  }

  /// Captures the current POSIX error code.
  private func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }

  /// Normalizes symlink and non-directory traversal errors to the service's invalid-directory case.
  private func cachePathError(for error: Error) -> Error {
    let error = error as NSError
    guard error.domain == NSPOSIXErrorDomain,
      error.code == Int(ENOTDIR) || error.code == Int(ELOOP)
    else { return error }
    return DirectoryAccessError.invalidDirectory
  }
}
