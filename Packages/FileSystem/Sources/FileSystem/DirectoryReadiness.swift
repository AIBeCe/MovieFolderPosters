import Darwin
import Foundation

public enum DirectoryReadinessState: Sendable, Equatable {
    case accessible
    case disconnected
    case missing
    case accessDenied
    case readOnly
    case unsupported
    case identityChanged
    case unknown
}

public struct DirectoryReadiness: Sendable, Equatable {
    public let state: DirectoryReadinessState
    public let identity: String?
    public let volumePath: String?

    public init(state: DirectoryReadinessState, identity: String? = nil, volumePath: String? = nil) {
        self.state = state
        self.identity = identity
        self.volumePath = volumePath
    }
}

public extension FileSystemService {
    /// Returns an identity suitable for persisting the same directory across volume reattachment.
    func persistentDirectoryIdentity(at directory: URL) throws -> String {
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
    func inspectDirectory(
        at directory: URL,
        expectedIdentity: String? = nil,
        expectedVolumePath: String? = nil
    ) -> DirectoryReadiness {
        guard directory.isFileURL else { return DirectoryReadiness(state: .unsupported) }

        var pathInfo = stat()
        guard lstat(directory.path, &pathInfo) == 0 else {
            if errno == ENOENT || errno == ENOTDIR {
                return DirectoryReadiness(state: missingPathState(expectedVolumePath: expectedVolumePath))
            }
            return DirectoryReadiness(state: errno == EACCES || errno == EPERM ? .accessDenied : .unknown)
        }
        guard (pathInfo.st_mode & S_IFMT) == S_IFDIR else {
            return DirectoryReadiness(state: .unsupported)
        }

        let pathIdentity = volatileIdentity(from: pathInfo)

        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            let state: DirectoryReadinessState
            switch errno {
            case EACCES, EPERM: state = .accessDenied
            case ENOENT, ENOTDIR:
                state = missingPathState(expectedVolumePath: expectedVolumePath)
            default: state = .unknown
            }
            return DirectoryReadiness(state: state)
        }
        defer { _ = close(descriptor) }

        var descriptorInfo = stat()
        guard fstat(descriptor, &descriptorInfo) == 0 else {
            return DirectoryReadiness(state: .unknown)
        }
        let openedObjectIdentity = volatileIdentity(from: descriptorInfo)
        guard (descriptorInfo.st_mode & S_IFMT) == S_IFDIR, openedObjectIdentity == pathIdentity else {
            return DirectoryReadiness(state: .identityChanged)
        }

        var filesystem = statfs()
        guard fstatfs(descriptor, &filesystem) == 0 else {
            return DirectoryReadiness(state: .unknown)
        }
        let volumePath = cString(filesystem.f_mntonname)
        let identity: String
        do {
            identity = try persistentIdentity(at: directory, descriptor: descriptor, service: self)
        } catch DirectoryAccessError.identityChanged {
            return DirectoryReadiness(state: .identityChanged, volumePath: volumePath)
        } catch {
            return DirectoryReadiness(state: .unknown, volumePath: volumePath)
        }
        guard expectedIdentity == nil || expectedIdentity == identity else {
            return DirectoryReadiness(state: .identityChanged, identity: identity, volumePath: volumePath)
        }
        if (filesystem.f_flags & UInt32(MNT_RDONLY)) != 0 {
            return DirectoryReadiness(state: .readOnly, identity: identity, volumePath: volumePath)
        }

        guard faccessat(descriptor, ".", W_OK, AT_EACCESS) == 0 else {
            return DirectoryReadiness(state: errno == EACCES || errno == EPERM || errno == EROFS
                ? .readOnly : .unknown, identity: identity, volumePath: volumePath)
        }

        errno = 0
        let attributeCount = flistxattr(descriptor, nil, 0, 0)
        if attributeCount < 0, errno == ENOTSUP {
            return DirectoryReadiness(state: .unsupported, identity: identity, volumePath: volumePath)
        }
        guard attributeCount >= 0 else {
            return DirectoryReadiness(state: .unknown, identity: identity, volumePath: volumePath)
        }

        let filesystemName = cString(filesystem.f_fstypename).lowercased()
        guard filesystemName == "apfs" || filesystemName == "hfs" else {
            return DirectoryReadiness(state: .unknown, identity: identity, volumePath: volumePath)
        }
        return DirectoryReadiness(state: .accessible, identity: identity, volumePath: volumePath)
    }
}

private func volatileIdentity(from info: stat) -> String {
    "\(info.st_dev):\(info.st_ino):\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec)"
}

func persistentIdentity(at directory: URL, descriptor: Int32, service: FileSystemService) throws -> String {
    var before = stat()
    guard fstat(descriptor, &before) == 0 else { throw posixDirectoryIdentityError() }
    let openedBefore = volatileIdentity(from: before)
    let pathBefore = try service.fileIdentity(at: directory)
    guard openedBefore == pathBefore else { throw DirectoryAccessError.identityChanged }

    let values = try directory.resourceValues(forKeys: [.volumeUUIDStringKey])
    guard let volumeUUID = values.volumeUUIDString, !volumeUUID.isEmpty else {
        throw DirectoryIdentityUnavailable()
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

struct DirectoryIdentityUnavailable: Error {}

private func directoryIdentityOpenError() -> Error {
    switch errno {
    case EACCES, EPERM: return DirectoryAccessError.accessDenied
    case ELOOP: return DirectoryAccessError.invalidDirectory
    default: return posixDirectoryIdentityError()
    }
}

private func posixDirectoryIdentityError() -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
}

private func isKnownUnmountedVolumePath(_ path: String) -> Bool? {
    var info = statfs()
    guard statfs(path, &info) == 0 else {
        return errno == ENOENT || errno == ENOTDIR ? true : nil
    }
    let resolvedMountPath = URL(fileURLWithPath: cString(info.f_mntonname)).standardizedFileURL.path
    let expectedPath = URL(fileURLWithPath: path).standardizedFileURL.path
    return resolvedMountPath != expectedPath
}

private func missingPathState(expectedVolumePath: String?) -> DirectoryReadinessState {
    guard let expectedVolumePath else { return .missing }
    switch isKnownUnmountedVolumePath(expectedVolumePath) {
    case true: return .disconnected
    case false: return .missing
    case nil: return .unknown
    }
}

private func cString<Value>(_ value: Value) -> String {
    withUnsafeBytes(of: value) { bytes in
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
}
