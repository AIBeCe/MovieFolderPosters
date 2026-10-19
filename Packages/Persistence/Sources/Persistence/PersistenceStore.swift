import CryptoKit
import Darwin
import Foundation

/// A filesystem-backed store that grants exclusive per-key access to persisted data.
public struct PersistenceStore: Sendable {
  /// The pinned directory descriptor used for every store operation.
  private let directory: DirectoryDescriptor
  /// Maximum encoded JSON envelope size accepted by the store.
  private let maximumRecordBytes: Int?

  /// Opens or creates the store directory without following symlinked path components.
  ///
  /// - Parameters:
  ///   - directory: The directory containing lock and record files.
  ///   - maximumRecordBytes: An optional encoded envelope limit; omitted for unlimited behavior.
  /// - Throws: An I/O error, an invalid-directory error, or an invalid-size error.
  public init(directory: URL, maximumRecordBytes: Int? = nil) throws {
    guard directory.isFileURL else { throw PersistenceError.invalidDirectory }
    if let maximumRecordBytes, maximumRecordBytes <= 0 {
      throw PersistenceError.invalidRecordLimit
    }
    self.directory = try DirectoryDescriptor.open(directory.standardizedFileURL.path)
    self.maximumRecordBytes = maximumRecordBytes
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
      lockDescriptor: descriptor,
      maximumRecordBytes: maximumRecordBytes
    )
  }

  /// Removes obsolete record data while preserving all reusable lock files.
  ///
  /// - Parameter keepingKeys: Opaque keys whose records must remain.
  /// - Returns: Digests whose records could not be removed because their lease was busy.
  /// - Throws: A persistence error when directory enumeration or descriptor operations fail.
  public func pruneRecords(keepingKeys: Set<String>) throws -> Set<String> {
    let retainedDigests = Set(keepingKeys.filter { !$0.isEmpty }.map { Self.digest(Data($0.utf8)) })
    let enumerationDescriptor = openat(
      directory.fileDescriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard enumerationDescriptor >= 0 else { throw PersistenceError.io(errno) }
    guard let stream = fdopendir(enumerationDescriptor) else {
      let code = errno
      close(enumerationDescriptor)
      throw PersistenceError.io(code)
    }
    defer { closedir(stream) }

    var deferredDigests = Set<String>()
    while let entry = readdir(stream) {
      let filename = withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
          String(cString: $0)
        }
      }
      guard let digest = Self.recordDigest(from: filename), !retainedDigests.contains(digest)
      else { continue }

      if try !pruneRecord(named: filename, digest: digest) { deferredDigests.insert(digest) }
    }

    return deferredDigests
  }

  /// Removes one obsolete regular record under its canonical lock, leaving lock files reusable.
  /// - Parameters:
  ///   - filename: Validated record filename relative to the pinned store directory.
  ///   - digest: Digest identifying this record's lock.
  /// - Returns: False only when another owner holds the record lease.
  /// - Throws: Descriptor, enumeration, or removal errors.
  private func pruneRecord(named filename: String, digest: String) throws -> Bool {
    let lockDescriptor = openat(
      directory.fileDescriptor, digest + ".lock",
      O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
    guard lockDescriptor >= 0 else { throw PersistenceError.io(errno) }
    if flock(lockDescriptor, LOCK_EX | LOCK_NB) != 0 {
      let code = errno
      close(lockDescriptor)
      if code == EWOULDBLOCK || code == EAGAIN {
        return false
      }
      throw PersistenceError.io(code)
    }
    defer {
      flock(lockDescriptor, LOCK_UN)
      close(lockDescriptor)
    }

    var info = stat()
    if fstatat(directory.fileDescriptor, filename, &info, AT_SYMLINK_NOFOLLOW) != 0 {
      if errno == ENOENT { return true }
      throw PersistenceError.io(errno)
    }
    guard (info.st_mode & S_IFMT) == S_IFREG else { return true }
    if unlinkat(directory.fileDescriptor, filename, 0) != 0, errno != ENOENT {
      throw PersistenceError.io(errno)
    }

    return true
  }

  /// Produces the stable hexadecimal SHA-256 identifier used by lock and record filenames.
  fileprivate static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// Accepts only record filenames containing a lowercase SHA-256 digest.
  private static func recordDigest(from filename: String) -> String? {
    guard filename.hasSuffix(".json") else { return nil }
    let digest = String(filename.dropLast(5))
    guard digest.utf8.count == 64,
      digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else { return nil }
    return digest
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
  /// Maximum encoded envelope size accepted through this lease.
  private let maximumRecordBytes: Int?
  /// Serializes file access when callers share the lease across threads.
  private let mutex = NSLock()

  fileprivate init(
    directory: DirectoryDescriptor,
    keyDigest: String,
    lockDescriptor: Int32,
    maximumRecordBytes: Int?
  ) {
    self.directory = directory
    self.keyDigest = keyDigest
    self.lockDescriptor = lockDescriptor
    self.maximumRecordBytes = maximumRecordBytes
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

    let data = try readBoundedRecord(from: descriptor, initialSize: info.st_size)

    return try decode(data).payload
  }

  /// Validates and atomically replaces the record payload associated with this lease.
  ///
  /// - Parameter data: The payload bytes to persist.
  /// - Throws: A persistence error if the existing record is unsafe or invalid, or writing fails.
  public func write(_ data: Data) throws {
    mutex.lock()
    defer { mutex.unlock() }

    try validateExistingRecord()
    try validatePayloadSize(data)

    let envelope = Envelope(version: 1, keyDigest: keyDigest, payload: data)
    let encoded: Data
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      encoded = try encoder.encode(envelope)
    } catch {
      throw PersistenceError.corruptRecord
    }
    if let maximumRecordBytes, encoded.count > maximumRecordBytes {
      throw PersistenceError.recordTooLarge
    }

    try atomicWrite(encoded, named: recordName)
  }

  /// Validates the existing record while the caller retains the lease mutex.
  /// - Throws: Unsafe file, envelope, size, or I/O errors before any replacement is attempted.
  private func validateExistingRecord() throws {
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
      do {
        _ = try decode(readBoundedRecord(from: descriptor, initialSize: openedInfo.st_size))
      } catch let error as PersistenceError {
        throw error
      } catch {
        throw PersistenceError.io(errno)
      }
    } else if errno != ENOENT {
      throw PersistenceError.io(errno)
    }
  }

  /// Rejects payloads that cannot fit in the configured encoded envelope limit.
  /// - Parameter data: Candidate payload, before envelope encoding.
  /// - Throws: Invalid envelope or capacity errors.
  private func validatePayloadSize(_ data: Data) throws {
    if let maximumRecordBytes {
      let emptyEnvelope = Envelope(version: 1, keyDigest: keyDigest, payload: Data())
      let emptyEncoding: Data
      do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        emptyEncoding = try encoder.encode(emptyEnvelope)
      } catch {
        throw PersistenceError.corruptRecord
      }
      let remainingBytes = maximumRecordBytes - emptyEncoding.count
      guard remainingBytes >= 0, data.count <= (remainingBytes / 4) * 3 else {
        throw PersistenceError.recordTooLarge
      }
    }
  }

  /// Explicitly removes only the regular record file owned by this held lease.
  ///
  /// Corrupt envelopes may be removed deliberately. The corresponding lock file remains in place.
  /// - Throws: A persistence error if the record is not a regular file or removal fails.
  public func removeRecord() throws {
    mutex.lock()
    defer { mutex.unlock() }

    var info = stat()
    if fstatat(directory.fileDescriptor, recordName, &info, AT_SYMLINK_NOFOLLOW) != 0 {
      if errno == ENOENT { return }
      throw PersistenceError.io(errno)
    }
    guard (info.st_mode & S_IFMT) == S_IFREG else { throw PersistenceError.invalidRecordFile }
    if unlinkat(directory.fileDescriptor, recordName, 0) != 0, errno != ENOENT {
      throw PersistenceError.io(errno)
    }
  }

  /// Reads at most the configured envelope limit and detects files that grow during the read.
  private func readBoundedRecord(from descriptor: Int32, initialSize: off_t) throws -> Data {
    guard initialSize >= 0 else { throw PersistenceError.invalidRecordFile }
    if let maximumRecordBytes, initialSize > maximumRecordBytes {
      throw PersistenceError.recordTooLarge
    }
    var result = Data()
    result.reserveCapacity(Int(initialSize))
    let bufferSize = maximumRecordBytes.map { min(64 * 1024, $0) } ?? 64 * 1024
    var buffer = [UInt8](repeating: 0, count: bufferSize)
    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count == 0 { break }
      if count < 0 {
        if errno == EINTR { continue }
        throw PersistenceError.io(errno)
      }
      if let maximumRecordBytes, result.count + count > maximumRecordBytes {
        throw PersistenceError.recordTooLarge
      }
      result.append(contentsOf: buffer[0..<count])
    }
    return result
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
  case invalidRecordLimit
  case recordTooLarge
  case io(Int32)
}
