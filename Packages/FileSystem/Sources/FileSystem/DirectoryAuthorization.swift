import Darwin
import Foundation

public final class DirectoryAccessLease: Sendable {
    public let url: URL

    private let isAccessingSecurityScopedResource: Bool

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

public extension FileSystemService {
    func makeTransferBookmark(for directory: URL) throws -> Data {
        try validateDirectory(directory)
        return try directory.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    func acquireDirectoryAccess(
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
        try validateDirectoryDescriptorAccess(directory, service: self, expectedIdentity: expectedIdentity)

        transferAccessToLease = startedAccessing
        return DirectoryAccessLease(
            url: directory,
            isAccessingSecurityScopedResource: startedAccessing
        )
    }
}

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

    let openedObjectIdentity = "\(openedInfo.st_dev):\(openedInfo.st_ino):"
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

func validateDirectoryObjectIdentity(openedIdentity: String, currentPathIdentity: String) throws {
    guard openedIdentity == currentPathIdentity else {
        throw DirectoryAccessError.identityChanged
    }
}

func validateDirectoryIdentity(
    openedIdentity: String,
    currentPathIdentity: String,
    expectedIdentity: String?
) throws {
    guard openedIdentity == currentPathIdentity,
          expectedIdentity == nil || expectedIdentity == openedIdentity else {
        throw DirectoryAccessError.identityChanged
    }
}
