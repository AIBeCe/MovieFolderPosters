import Darwin
import Foundation

/// The result of checking whether a configured directory can be used now.
public enum DirectoryAvailability: Sendable, Equatable {
  case accessible
  case disconnected
  case missing
  case accessDenied
  case readOnly
  case unsupported
  case identityChanged
  case unknown
}

/// A directory's current availability together with identities useful for detecting replacement.
public struct DirectoryAvailabilityResult: Sendable, Equatable {
  /// The availability or failure category observed during inspection.
  public let state: DirectoryAvailability
  /// The persistent identity, when the mounted volume provides one.
  public let identity: String?
  /// The mounted volume path, when it could be determined.
  public let volumePath: String?

  /// Creates a readiness result with optional directory and volume identity details.
  public init(state: DirectoryAvailability, identity: String? = .none, volumePath: String? = .none) {
    self.state = state
    self.identity = identity
    self.volumePath = volumePath
  }
}

extension FileSystemService {
  /// Returns an identity suitable for recognizing the same directory after volume reattachment.
  ///
  /// - Parameter directory: The directory whose mounted-volume identity is requested.
  /// - Returns: A stable volume and directory identity.
  /// - Throws: ``DirectoryAccessError`` or a system error when identity cannot be established.
  public func persistentDirectoryIdentity(at directory: URL) throws -> String {
    guard directory.isFileURL else { throw DirectoryAccessError.invalidDirectory }
    let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw directoryIdentityOpenError() }
    defer { _ = close(descriptor) }

    var info = stat()
    guard fstat(descriptor, &info) == 0 else { throw posixDirectoryIdentityError() }
    guard (info.st_mode & S_IFMT) == S_IFDIR else {
      throw DirectoryAccessError.invalidDirectory
    }

    return try persistentIdentity(at: directory, descriptor: descriptor, service: self)
  }

  /// Inspects one directory without listing its children or modifying filesystem state.
  ///
  /// - Parameters:
  ///   - directory: The directory to inspect.
  ///   - expectedIdentity: An optional persistent identity required for the directory.
  ///   - expectedVolumePath: The expected mount path, used to distinguish disconnection from removal.
  /// - Returns: The observed readiness state and any identities that could be read.
  public func inspectDirectory(
    at directory: URL,
    expectedIdentity: String? = .none,
    expectedVolumePath: String? = .none
  ) -> DirectoryAvailabilityResult {
    guard directory.isFileURL else { return DirectoryAvailabilityResult(state: .unsupported) }

    var pathInfo = stat()
    guard lstat(directory.path, &pathInfo) == 0 else {
      if errno == ENOENT || errno == ENOTDIR {
        return DirectoryAvailabilityResult(state: missingPathState(expectedVolumePath: expectedVolumePath))
      }
      return DirectoryAvailabilityResult(state: errno == EACCES || errno == EPERM ? .accessDenied : .unknown)
    }
    guard (pathInfo.st_mode & S_IFMT) == S_IFDIR else {
      return DirectoryAvailabilityResult(state: .unsupported)
    }

    let pathIdentity = volatileIdentity(from: pathInfo)

    let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      let state: DirectoryAvailability
      switch errno {
      case EACCES, EPERM: state = .accessDenied
      case ENOENT, ENOTDIR:
        state = missingPathState(expectedVolumePath: expectedVolumePath)
      default: state = .unknown
      }
      return DirectoryAvailabilityResult(state: state)
    }
    defer { _ = close(descriptor) }

    var descriptorInfo = stat()
    guard fstat(descriptor, &descriptorInfo) == 0 else {
      return DirectoryAvailabilityResult(state: .unknown)
    }
    let openedObjectIdentity = volatileIdentity(from: descriptorInfo)
    guard (descriptorInfo.st_mode & S_IFMT) == S_IFDIR, openedObjectIdentity == pathIdentity else {
      return DirectoryAvailabilityResult(state: .identityChanged)
    }

    return inspectOpenedDirectory(at: directory, descriptor: descriptor, expectedIdentity: expectedIdentity)
  }

  /// Assesses the pinned directory's volume, permissions, and metadata support without releasing its descriptor.
  /// - Parameters:
  ///   - directory: Path whose identity must continue matching the opened directory.
  ///   - descriptor: Borrowed descriptor retained and closed by the caller.
  ///   - expectedIdentity: Optional saved directory identity.
  /// - Returns: Readiness evidence collected from the same open directory.
  private func inspectOpenedDirectory(
    at directory: URL, descriptor: Int32, expectedIdentity: String?
  ) -> DirectoryAvailabilityResult {
    var filesystem = statfs()
    guard fstatfs(descriptor, &filesystem) == 0 else {
      return DirectoryAvailabilityResult(state: .unknown)
    }
    let volumePath = cString(filesystem.f_mntonname)
    let identity: String
    do {
      identity = try persistentIdentity(at: directory, descriptor: descriptor, service: self)
    } catch DirectoryAccessError.identityChanged {
      return DirectoryAvailabilityResult(state: .identityChanged, volumePath: volumePath)
    } catch {
      return DirectoryAvailabilityResult(state: .unknown, volumePath: volumePath)
    }
    guard expectedIdentity == .none || expectedIdentity == identity else {
      return DirectoryAvailabilityResult(state: .identityChanged, identity: identity, volumePath: volumePath)
    }
    if (filesystem.f_flags & UInt32(MNT_RDONLY)) != 0 {
      return DirectoryAvailabilityResult(state: .readOnly, identity: identity, volumePath: volumePath)
    }

    guard faccessat(descriptor, ".", W_OK, AT_EACCESS) == 0 else {
      return DirectoryAvailabilityResult(
        state: errno == EACCES || errno == EPERM || errno == EROFS
          ? .readOnly : .unknown, identity: identity, volumePath: volumePath)
    }

    errno = 0
    let attributeCount = flistxattr(descriptor, nil, 0, 0)
    if attributeCount < 0, errno == ENOTSUP {
      return DirectoryAvailabilityResult(state: .unsupported, identity: identity, volumePath: volumePath)
    }
    guard attributeCount >= 0 else {
      return DirectoryAvailabilityResult(state: .unknown, identity: identity, volumePath: volumePath)
    }

    let filesystemName = cString(filesystem.f_fstypename).lowercased()
    guard filesystemName == "apfs" || filesystemName == "hfs" else {
      return DirectoryAvailabilityResult(state: .unknown, identity: identity, volumePath: volumePath)
    }

    return DirectoryAvailabilityResult(state: .accessible, identity: identity, volumePath: volumePath)
  }
}

/// Builds an identity from the current device, inode, and creation timestamp.
private func volatileIdentity(from info: stat) -> String {
  "\(info.st_dev):\(info.st_ino):\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec)"
}

/// Reads a volume-stable identity while checking that the path does not change during the read.
func persistentIdentity(at directory: URL, descriptor: Int32, service: FileSystemService) throws -> String {
  var before = stat()
  guard fstat(descriptor, &before) == 0 else { throw posixDirectoryIdentityError() }
  let openedBefore = volatileIdentity(from: before)
  let pathBefore = try service.fileIdentity(at: directory)
  guard openedBefore == pathBefore else { throw DirectoryAccessError.identityChanged }

  let values = try directory.resourceValues(forKeys: [.volumeUUIDStringKey])
  guard let volumeUUID = values.volumeUUIDString, !volumeUUID.isEmpty else {
    throw DirectoryIdentityUnavailableError()
  }

  var after = stat()
  guard fstat(descriptor, &after) == 0 else { throw posixDirectoryIdentityError() }
  let openedAfter = volatileIdentity(from: after)
  let pathAfter = try service.fileIdentity(at: directory)
  guard openedBefore == openedAfter, openedAfter == pathAfter else {
    throw DirectoryAccessError.identityChanged
  }

  return "\(volumeUUID.lowercased()):\(after.st_ino):"
    + "\(after.st_birthtimespec.tv_sec):\(after.st_birthtimespec.tv_nsec)"
}

/// Indicates that the mounted volume does not provide a persistent UUID.
struct DirectoryIdentityUnavailableError: Error {}

/// Converts the current open failure into the directory-specific error model.
private func directoryIdentityOpenError() -> Error {
  switch errno {
  case EACCES, EPERM: return DirectoryAccessError.accessDenied
  case ELOOP: return DirectoryAccessError.invalidDirectory
  default: return posixDirectoryIdentityError()
  }
}

/// Captures the current POSIX failure as an NSError.
private func posixDirectoryIdentityError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }

/// Determines whether a missing path corresponds to an unmounted volume.
private func isKnownUnmountedVolumePath(_ path: String) -> Bool? {
  var info = statfs()
  guard statfs(path, &info) == 0 else {
    return errno == ENOENT || errno == ENOTDIR ? true : .none
  }
  let resolvedMountPath = URL(fileURLWithPath: cString(info.f_mntonname)).standardizedFileURL.path
  let expectedPath = URL(fileURLWithPath: path).standardizedFileURL.path

  return resolvedMountPath != expectedPath
}

/// Maps a missing directory path to removal, disconnection, or an unknown state.
private func missingPathState(expectedVolumePath: String?) -> DirectoryAvailability {
  guard let expectedVolumePath else { return .missing }
  switch isKnownUnmountedVolumePath(expectedVolumePath) {
  case true: return .disconnected
  case false: return .missing
  case .none: return .unknown
  }
}

/// Decodes a fixed-size POSIX C string without reading beyond its value.
private func cString<Value>(_ value: Value) -> String {
  withUnsafeBytes(of: value) { bytes in
    let terminated = Array(bytes.prefix { $0 != 0 }) + [UInt8.zero]

    return terminated.withUnsafeBufferPointer { buffer in
      guard let address = buffer.baseAddress else { return "" }

      return String(decodingCString: address, as: UTF8.self)
    }
  }
}
