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
        securityScoped: Bool
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

        guard !isStale else {
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
        do {
            _ = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            )
        } catch {
            throw DirectoryAccessError.accessDenied
        }

        transferAccessToLease = startedAccessing
        return DirectoryAccessLease(
            url: directory,
            isAccessingSecurityScopedResource: startedAccessing
        )
    }
}
