import Foundation

public enum DirectoryAccessError: Error {
    case invalidDirectory
    case staleBookmark
    case accessDenied
}

public struct FileSystemService {
    public init() {}

    public func makeDirectoryBookmark(for directory: URL, relativeTo document: URL) throws -> Data {
        try validateDirectory(directory)

        return try directory.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: document
        )
    }

    public func withDirectoryAccess<Result>(
        bookmark: Data,
        relativeTo document: URL,
        operation: (URL) throws -> Result
    ) throws -> Result {
        var isStale = false
        let directory = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: document,
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

    private func validateDirectory(_ directory: URL) throws {
        guard directory.isFileURL else {
            throw DirectoryAccessError.invalidDirectory
        }

        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw DirectoryAccessError.invalidDirectory
        }
    }
}
