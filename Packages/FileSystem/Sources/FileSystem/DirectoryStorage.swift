import Darwin
import Foundation

/// Read-only logical storage estimates, bounded independently of directory contents.
public struct DirectoryStorage {
  /// Completeness of an estimate; skipped unsafe entries always make an existing directory partial.
  public enum Status: String, Codable, Sendable { case complete, partial, unavailable, notCreated }

  /// Metadata-only evidence captured over a finite interval.
  public struct Usage: Encodable, Sendable, Equatable {
    /// Logical lengths of distinct regular files; never allocated or reclaimable bytes.
    public var logicalBytes: UInt64 = .zero
    /// Distinct regular files, independent of application record semantics.
    public var fileCount: UInt64 = .zero
    /// Whether all eligible metadata could be inspected.
    public var status: Status = .complete
    /// Time before the first filesystem inspection.
    public let startedAt = Date()
    /// Time after the last filesystem inspection.
    public var finishedAt = Date()

    /// Creates an initially empty metadata estimate.
    public init() {}
  }

  /// Total metadata-entry budget, including skipped entries.
  public let maximumEntries: Int
  /// Maximum nested directory depth.
  public let maximumDepth: Int

  /// Creates a storage inspector with finite traversal limits.
  /// - Parameters:
  ///   - maximumEntries: Total metadata-entry budget, including skipped entries.
  ///   - maximumDepth: Maximum nested directory depth.
  public init(maximumEntries: Int = 100_000, maximumDepth: Int = 64) {
    self.maximumEntries = maximumEntries
    self.maximumDepth = maximumDepth
  }

  /// Inspects a fixed directory without following links, crossing devices, or reading file payloads.
  /// - Parameter directory: Absolute, existing directory to inspect; missing storage is never initialized.
  /// - Returns: A conservative estimate whose completeness describes every omission.
  public func measure(at directory: URL) -> Usage {
    var usage = Usage()

    guard !Task.isCancelled else {
      usage.status = .partial
      return finishing(usage)
    }

    guard let descriptor = openRoot(at: directory, usage: &usage) else { return finishing(usage) }

    defer { close(descriptor) }
    var root = stat()

    guard fstat(descriptor, &root) == 0 else {
      usage.status = .unavailable
      return finishing(usage)
    }

    var traversal = Traversal(
      device: root.st_dev, maximumDepth: maximumDepth,
      remainingEntries: max(.zero, maximumEntries), usage: usage)
    traversal.inspect(descriptor, depth: .zero)

    return finishing(traversal.usage)
  }

  /// Opens each path component without following links; inaccessible and absent roots stay distinct.
  /// - Parameters:
  ///   - directory: Absolute target selected for measurement.
  ///   - usage: Estimate updated when the target itself is a regular file or unavailable.
  /// - Returns: The opened root descriptor, or `.none` after the estimate is complete or unavailable.
  private func openRoot(at directory: URL, usage: inout Usage) -> Int32? {
    let components = Array(directory.pathComponents.dropFirst())
    let rootAccess = components.isEmpty ? O_RDONLY : O_SEARCH
    var descriptor = open("/", rootAccess | O_DIRECTORY | O_CLOEXEC)

    guard descriptor >= 0 else {
      usage.status = .unavailable
      return .none
    }

    for (index, component) in components.enumerated() {
      let access = index == components.count - 1 ? O_RDONLY : O_SEARCH
      let next = openat(descriptor, component, access | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      let failure = errno

      if next < 0, index == components.count - 1,
        measureRegularFile(at: component, in: descriptor, usage: &usage) {
        close(descriptor)
        return .none
      }

      close(descriptor)

      guard next >= 0 else {
        usage.status = failure == ENOENT ? .notCreated : .unavailable
        return .none
      }

      descriptor = next
    }

    return descriptor
  }

  /// Counts a single regular-file target without following a symbolic link.
  /// - Parameters:
  ///   - name: Final path component to inspect.
  ///   - descriptor: Open parent directory descriptor.
  ///   - usage: Estimate updated only when the target is eligible.
  /// - Returns: Whether a regular-file target was handled, including a zero-budget omission.
  private func measureRegularFile(at name: String, in descriptor: Int32, usage: inout Usage) -> Bool {
    var info = stat()

    guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
      info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_size >= .zero
    else { return false }

    guard maximumEntries > .zero else {
      usage.status = .partial
      return true
    }

    usage.logicalBytes = UInt64(info.st_size)
    usage.fileCount = 1

    return true
  }

  /// Ends the capture interval on successful and failed inspections alike.
  /// - Parameter usage: Estimate whose final capture time is refreshed.
  /// - Returns: The completed estimate.
  private func finishing(_ usage: Usage) -> Usage {
    var finished = usage
    finished.finishedAt = Date()

    return finished
  }

  /// Owns mutable traversal bounds and results for one metadata-only scan.
  private struct Traversal {
    /// Device identifier that bounds traversal to the root volume.
    let device: dev_t
    /// Maximum permitted nested directory depth.
    let maximumDepth: Int
    /// Remaining metadata entries, including entries that will be skipped.
    var remainingEntries: Int
    /// File identities already counted during this scan.
    var identities = Set<String>()
    /// Estimate being accumulated during traversal.
    var usage: Usage

    /// Traverses one opened directory descriptor and marks every skipped entry partial.
    /// - Parameters:
    ///   - descriptor: Open directory whose children are examined.
    ///   - depth: Current depth below the selected root.
    mutating func inspect(_ descriptor: Int32, depth: Int) {
      let duplicate = dup(descriptor)

      guard duplicate >= 0 else {
        usage.status = .partial
        return
      }

      guard let stream = fdopendir(duplicate) else {
        close(duplicate)
        usage.status = .partial
        return
      }

      defer { closedir(stream) }

      while true {
        guard !Task.isCancelled else {
          usage.status = .partial
          return
        }

        guard let name = nextName(in: stream) else { return }

        if name == "." || name == ".." { continue }

        guard remainingEntries > .zero else {
          usage.status = .partial
          return
        }

        remainingEntries -= 1
        inspectEntry(named: name, in: descriptor, depth: depth)
      }
    }

    /// Reads one directory entry and classifies its metadata without following links.
    /// - Parameters:
    ///   - name: Child entry name returned by `readdir`.
    ///   - descriptor: Open parent directory descriptor.
    ///   - depth: Current depth below the selected root.
    private mutating func inspectEntry(named name: String, in descriptor: Int32, depth: Int) {
      var info = stat()

      guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
        info.st_dev == device
      else {
        usage.status = .partial
        return
      }

      switch info.st_mode & S_IFMT {
      case S_IFDIR:
        inspectDirectory(named: name, in: descriptor, depth: depth, expectedIdentity: info.st_ino)
      case S_IFREG:
        countRegularFile(info)
      default:
        usage.status = .partial
      }
    }

    /// Opens and verifies a child directory before recursively inspecting it.
    /// - Parameters:
    ///   - name: Child directory entry name.
    ///   - descriptor: Open parent directory descriptor.
    ///   - depth: Current parent depth.
    ///   - expectedIdentity: Inode observed in the parent directory entry.
    private mutating func inspectDirectory(
      named name: String, in descriptor: Int32, depth: Int, expectedIdentity: ino_t
    ) {
      guard depth < maximumDepth else {
        usage.status = .partial
        return
      }

      let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)

      guard child >= 0 else {
        usage.status = .partial
        return
      }

      defer { close(child) }
      var opened = stat()

      guard fstat(child, &opened) == 0, opened.st_dev == device, opened.st_ino == expectedIdentity else {
        usage.status = .partial
        return
      }

      inspect(child, depth: depth + 1)
    }

    /// Adds an eligible file's logical size and identity to the estimate.
    /// - Parameter info: No-follow metadata read from the parent directory.
    private mutating func countRegularFile(_ info: stat) {
      guard info.st_nlink == 1, info.st_size >= .zero else {
        usage.status = .partial
        return
      }

      let identity = "\(info.st_dev):\(info.st_ino)"

      guard identities.insert(identity).inserted else {
        usage.status = .partial
        return
      }

      let sum = usage.logicalBytes.addingReportingOverflow(UInt64(info.st_size))

      guard !sum.overflow, usage.fileCount < UInt64.max else {
        usage.status = .partial
        return
      }

      usage.logicalBytes = sum.partialValue
      usage.fileCount += 1
    }

    /// Reads the next child name and records directory-stream errors as incomplete evidence.
    /// - Parameter stream: Directory stream owned by the caller.
    /// - Returns: The next child name, or `.none` at end of stream or after an error.
    private mutating func nextName(in stream: UnsafeMutablePointer<DIR>) -> String? {
      errno = .zero

      guard let entry = readdir(stream) else {
        if errno != .zero { usage.status = .partial }
        return .none
      }

      return withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
      }
    }
  }
}
