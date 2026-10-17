import CryptoKit
import Darwin
import Foundation

/// A filesystem-backed store that grants exclusive per-key access to persisted data.
public struct PersistenceStore: Sendable {
  /// The pinned directory descriptor used for every store operation.
  private let directory: DirectoryDescriptor

  /// Opens or creates the store directory without following symlinked path components.
  ///
  /// - Parameter directory: The directory containing lock and record files.
  /// - Throws: An I/O error or ``PersistenceError/invalidDirectory`` for a non-file URL.
  public init(directory: URL) throws {
    guard directory.isFileURL else { throw PersistenceError.invalidDirectory }
    self.directory = try DirectoryDescriptor.open(directory.standardizedFileURL.path)
  }

  /// Attempts to hold an exclusive lease for an opaque key.
  ///
  /// - Parameter key: A nonempty key; only its SHA-256 digest is used for filenames.
  /// - Returns: A lease when acquired, or `nil` when another process holds the key.
  /// - Throws: ``PersistenceError/invalidKey`` or an I/O error if acquisition fails.
  public func acquireLease(for key: String) throws -> PersistenceLease? {
    guard !key.isEmpty else { throw PersistenceError.invalidKey }

    let digest = Self.digest(Data(key.utf8))
    let descriptor = openat(
      directory.fileDescriptor,
      digest + ".lock",
      O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
      S_IRUSR | S_IWUSR
    )
    guard descriptor >= 0 else { throw PersistenceError.io(errno) }

    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      let code = errno
      close(descriptor)
      if code == EWOULDBLOCK || code == EAGAIN { return nil }
      throw PersistenceError.io(code)
    }

    return PersistenceLease(
      directory: directory,
      keyDigest: digest,
      lockDescriptor: descriptor
    )
  }

  /// Produces the stable hexadecimal SHA-256 identifier used by lock and record filenames.
  fileprivate static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

/// Holds the exclusive lock for one key and reads or atomically updates its payload.
public final class PersistenceLease: Sendable {
  /// The pinned directory used for all reads and writes through this lease.
  private let directory: DirectoryDescriptor
  /// The digest binding this lease to its record and lock filenames.
  private let keyDigest: String
  /// The open lock file whose advisory lock represents this lease.
  private let lockDescriptor: Int32
  /// Serializes file access when callers share the lease across threads.
  private let mutex = NSLock()

  fileprivate init(
    directory: DirectoryDescriptor,
    keyDigest: String,
    lockDescriptor: Int32
  ) {
    self.directory = directory
    self.keyDigest = keyDigest
    self.lockDescriptor = lockDescriptor
  }

  /// Releases the per-key advisory lock and closes its descriptor.
  deinit {
    flock(lockDescriptor, LOCK_UN)
    close(lockDescriptor)
  }

  /// Reads and validates the record currently associated with this lease.
  ///
  /// - Returns: The stored payload, or `nil` when no record exists.
  /// - Throws: A persistence error for invalid, corrupt, mismatched, or unreadable records.
  public func read() throws -> Data? {
    mutex.lock()
    defer { mutex.unlock() }

    let descriptor = openat(
      directory.fileDescriptor,
      recordName,
      O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else {
      if errno == ENOENT { return nil }
      throw PersistenceError.io(errno)
    }
    defer { close(descriptor) }

    var info = stat()
    guard fstat(descriptor, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFREG
    else {
      throw PersistenceError.invalidRecordFile
    }

    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    let data: Data
    do {
      data = try file.readToEnd() ?? Data()
    } catch {
      throw PersistenceError.io(errno)
    }

    return try decode(data).payload
  }

  /// Validates and atomically replaces the record payload associated with this lease.
  ///
  /// - Parameter data: The payload bytes to persist.
  /// - Throws: A persistence error if the existing record is unsafe or invalid, or writing fails.
  public func write(_ data: Data) throws {
    mutex.lock()
    defer { mutex.unlock() }

    var info = stat()
    if fstatat(directory.fileDescriptor, recordName, &info, AT_SYMLINK_NOFOLLOW) == 0 {
      guard (info.st_mode & S_IFMT) == S_IFREG else {
        throw PersistenceError.invalidRecordFile
      }
      let descriptor = openat(
        directory.fileDescriptor,
        recordName,
        O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
      )
      guard descriptor >= 0 else { throw PersistenceError.io(errno) }
      defer { close(descriptor) }
      var openedInfo = stat()
      guard fstat(descriptor, &openedInfo) == 0,
        (openedInfo.st_mode & S_IFMT) == S_IFREG
      else {
        throw PersistenceError.invalidRecordFile
      }
      let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
      do {
        _ = try decode(file.readToEnd() ?? Data())
      } catch let error as PersistenceError {
        throw error
      } catch {
        throw PersistenceError.io(errno)
      }
    } else if errno != ENOENT {
      throw PersistenceError.io(errno)
    }

    let envelope = Envelope(version: 1, keyDigest: keyDigest, payload: data)
    let encoded: Data
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      encoded = try encoder.encode(envelope)
    } catch {
      throw PersistenceError.corruptRecord
    }

    try atomicWrite(encoded, named: recordName)
  }

  /// The deterministic JSON filename associated with this key digest.
  private var recordName: String {
    keyDigest + ".json"
  }

  /// Writes a complete temporary record, synchronizes it, and renames it into place.
  private func atomicWrite(_ data: Data, named name: String) throws {
    let temporaryName = "." + UUID().uuidString + ".tmp"
    let descriptor = openat(
      directory.fileDescriptor,
      temporaryName,
      O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC,
      S_IRUSR | S_IWUSR
    )
    guard descriptor >= 0 else { throw PersistenceError.io(errno) }
    defer {
      close(descriptor)
      unlinkat(directory.fileDescriptor, temporaryName, 0)
    }

    var offset = 0
    try data.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else { return }
      while offset < bytes.count {
        let written = Darwin.write(
          descriptor,
          baseAddress.advanced(by: offset),
          bytes.count - offset
        )
        if written < 0 {
          if errno == EINTR { continue }
          throw PersistenceError.io(errno)
        }
        guard written > 0 else { throw PersistenceError.io(EIO) }
        offset += written
      }
    }
    guard fsync(descriptor) == 0 else { throw PersistenceError.io(errno) }
    guard renameat(directory.fileDescriptor, temporaryName, directory.fileDescriptor, name) == 0
    else {
      throw PersistenceError.io(errno)
    }
  }

  /// Decodes a record and verifies its format version and key binding.
  private func decode(_ data: Data) throws -> Envelope {
    let envelope: Envelope
    do {
      envelope = try JSONDecoder().decode(Envelope.self, from: data)
    } catch {
      throw PersistenceError.corruptRecord
    }
    guard envelope.version == 1 else { throw PersistenceError.unsupportedVersion }
    guard envelope.keyDigest == keyDigest else { throw PersistenceError.keyMismatch }
    return envelope
  }
}

/// Owns a directory descriptor so path replacement cannot redirect later store operations.
private final class DirectoryDescriptor: Sendable {
  /// The open descriptor pinned to the validated directory object.
  let fileDescriptor: Int32

  private init(fileDescriptor: Int32) {
    self.fileDescriptor = fileDescriptor
  }

  /// Closes the pinned directory descriptor when its owner is released.
  deinit { close(fileDescriptor) }

  /// Opens or creates every path component while rejecting symlinks.
  static func open(_ path: String) throws -> DirectoryDescriptor {
    let canonicalPath = path.hasPrefix("/var/") ? "/private" + path : path
    let components = canonicalPath.split(separator: "/")
    let rootAccess = components.isEmpty ? O_RDONLY : O_SEARCH
    let root = Darwin.open("/", rootAccess | O_DIRECTORY | O_CLOEXEC)
    guard root >= 0 else { throw PersistenceError.io(errno) }
    var current = root

    for (index, component) in components.enumerated() {
      let name = String(component)
      let access = index == components.count - 1 ? O_RDONLY : O_SEARCH
      let flags = access | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
      var next = openat(current, name, flags)
      if next < 0, errno == ENOENT {
        guard mkdirat(current, name, S_IRWXU) == 0 || errno == EEXIST else {
          let code = errno
          close(current)
          throw PersistenceError.io(code)
        }
        next = openat(current, name, flags)
      }
      guard next >= 0 else {
        let code = errno
        close(current)
        throw PersistenceError.io(code)
      }
      close(current)
      current = next
    }

    return DirectoryDescriptor(fileDescriptor: current)
  }
}

/// The versioned on-disk record envelope that binds a payload to its key digest.
private struct Envelope: Codable {
  /// The record schema version.
  let version: Int
  /// The digest of the key whose lease owns this record.
  let keyDigest: String
  /// The opaque bytes stored for the key.
  let payload: Data
}

/// Internal failures used to reject unsafe or inconsistent records.
private enum PersistenceError: Error {
  case invalidDirectory
  case invalidKey
  case invalidRecordFile
  case corruptRecord
  case unsupportedVersion
  case keyMismatch
  case io(Int32)
}
