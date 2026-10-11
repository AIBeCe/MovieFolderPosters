import CryptoKit
import Darwin
import Foundation

public struct PersistenceStore: Sendable {
    private let directory: DirectoryDescriptor

    public init(directory: URL) throws {
        guard directory.isFileURL else { throw PersistenceError.invalidDirectory }
        self.directory = try DirectoryDescriptor.open(directory.standardizedFileURL.path)
    }

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

    fileprivate static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public final class PersistenceLease: Sendable {
    private let directory: DirectoryDescriptor
    private let keyDigest: String
    private let lockDescriptor: Int32
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

    deinit {
        flock(lockDescriptor, LOCK_UN)
        close(lockDescriptor)
    }

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
              (info.st_mode & S_IFMT) == S_IFREG else {
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
                  (openedInfo.st_mode & S_IFMT) == S_IFREG else {
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

    private var recordName: String {
        keyDigest + ".json"
    }

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
        guard renameat(directory.fileDescriptor, temporaryName, directory.fileDescriptor, name) == 0 else {
            throw PersistenceError.io(errno)
        }
    }

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

private final class DirectoryDescriptor: Sendable {
    let fileDescriptor: Int32

    private init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    deinit { close(fileDescriptor) }

    static func open(_ path: String) throws -> DirectoryDescriptor {
        let canonicalPath = path.hasPrefix("/var/") ? "/private" + path : path
        let root = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard root >= 0 else { throw PersistenceError.io(errno) }
        var current = root

        for component in canonicalPath.split(separator: "/") {
            let name = String(component)
            var next = openat(current, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0, errno == ENOENT {
                guard mkdirat(current, name, S_IRWXU) == 0 || errno == EEXIST else {
                    let code = errno
                    close(current)
                    throw PersistenceError.io(code)
                }
                next = openat(current, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
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

private struct Envelope: Codable {
    let version: Int
    let keyDigest: String
    let payload: Data
}

private enum PersistenceError: Error {
    case invalidDirectory
    case invalidKey
    case invalidRecordFile
    case corruptRecord
    case unsupportedVersion
    case keyMismatch
    case io(Int32)
}
