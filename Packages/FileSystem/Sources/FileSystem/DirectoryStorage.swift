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
  /// - Parameters:
  ///   - directory: Absolute, existing directory to inspect; missing storage is never initialized.
  /// - Returns: A conservative estimate whose completeness describes every omission.
  public func measure(at directory: URL) -> Usage {
    var usage = Usage()

    guard !Task.isCancelled else {
      usage.status = .partial
      usage.finishedAt = Date()
      return finishing(usage)
    }
    let components = Array(directory.pathComponents.dropFirst())
    let rootAccess = components.isEmpty ? O_RDONLY : O_SEARCH
    var descriptor = open("/", rootAccess | O_DIRECTORY | O_CLOEXEC)

    guard descriptor >= 0 else {
      usage.status = .unavailable
      return finishing(usage)
    }

    for (index, component) in components.enumerated() {
      let access = index == components.count - 1 ? O_RDONLY : O_SEARCH
      let next = openat(descriptor, component, access | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      let failure = errno
      if next < 0, index == components.count - 1 {
        var info = stat()
        if fstatat(descriptor, component, &info, AT_SYMLINK_NOFOLLOW) == 0,
          info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_size >= .zero
        {
          guard maximumEntries > .zero else {
            usage.status = .partial
            close(descriptor)
            return finishing(usage)
          }

          usage.logicalBytes = UInt64(info.st_size)
          usage.fileCount = 1
          usage.finishedAt = Date()
          close(descriptor)

          return finishing(usage)
        }
      }
      close(descriptor)

      guard next >= 0 else {
        usage.status = failure == ENOENT ? .notCreated : .unavailable
        usage.finishedAt = Date()
        return finishing(usage)
      }
      descriptor = next
    }
    defer { close(descriptor) }
    var root = stat()

    guard fstat(descriptor, &root) == 0 else {
      usage.status = .unavailable
      return finishing(usage)
    }

    var remaining = max(.zero, maximumEntries)
    var identities = Set<String>()
    inspect(
      descriptor, device: root.st_dev, depth: .zero, maximumDepth: maximumDepth,
      remaining: &remaining, identities: &identities, usage: &usage)
    usage.finishedAt = Date()

    return finishing(usage)
  }

  /// Ends the capture interval on successful and failed inspections alike.
  private func finishing(_ usage: Usage) -> Usage {
    var finished = usage
    finished.finishedAt = Date()

    return finished
  }

  /// Traverses opened directory descriptors, treating races and unsafe metadata as incomplete evidence.
  private func inspect(
    _ descriptor: Int32, device: dev_t, depth: Int, maximumDepth: Int,
    remaining: inout Int, identities: inout Set<String>, usage: inout Usage
  ) {
    let duplicate = dup(descriptor)

    guard duplicate >= 0, let stream = fdopendir(duplicate) else {
      if duplicate >= 0 { close(duplicate) }
      usage.status = .partial
      return
    }
    defer { closedir(stream) }
    while true {
      guard !Task.isCancelled else {
        usage.status = .partial
        return
      }

      errno = .zero
      let next = readdir(stream)

      guard let next else {
        if errno != .zero { usage.status = .partial }
        return
      }
      let name = withUnsafePointer(to: &next.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
      }
      if name == "." || name == ".." { continue }

      guard !Task.isCancelled, remaining > .zero else {
        usage.status = .partial
        return
      }

      remaining -= 1
      var info = stat()

      guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
        info.st_dev == device
      else {
        usage.status = .partial
        continue
      }

      let kind = info.st_mode & S_IFMT
      if kind == S_IFDIR {
        guard depth < maximumDepth else {
          usage.status = .partial
          continue
        }

        let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        var opened = stat()

        guard child >= 0 else {
          usage.status = .partial
          continue
        }

        if fstat(child, &opened) == 0, opened.st_dev == device, opened.st_ino == info.st_ino {
          inspect(
            child, device: device, depth: depth + 1, maximumDepth: maximumDepth,
            remaining: &remaining, identities: &identities, usage: &usage)
        } else {
          usage.status = .partial
        }
        close(child)
      } else if kind == S_IFREG {
        // Hard links can refer to content outside the namespace; do not count them.
        guard info.st_nlink == 1, info.st_size >= .zero else {
          usage.status = .partial
          continue
        }

        let identity = "\(info.st_dev):\(info.st_ino)"
        if !identities.insert(identity).inserted {
          usage.status = .partial
          continue
        }
        let sum = usage.logicalBytes.addingReportingOverflow(UInt64(info.st_size))

        guard !sum.overflow, usage.fileCount < UInt64.max else {
          usage.status = .partial
          return
        }

        usage.logicalBytes = sum.partialValue
        usage.fileCount += 1
      } else {
        usage.status = .partial
      }
    }
  }
}
