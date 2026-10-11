import Foundation

public enum DirectoryAccessError: Error {
    case invalidDirectory
    case staleBookmark
    case accessDenied
}

public struct FileSystemService: Sendable {
    public init() {}

    public func makeDirectoryBookmark(for directory: URL) throws -> Data {
        try validateDirectory(directory)

        return try directory.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    public func withDirectoryAccess<Result>(
        bookmark: Data,
        operation: (URL) throws -> Result
    ) throws -> Result {
        var isStale = false
        let directory = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
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

    public func verifyReadWriteAccess(in directory: URL) throws {
        try Task.checkCancellation()
        try validateDirectory(directory)
        do {
            try Task.checkCancellation()
            _ = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            let probe = directory.appendingPathComponent(".MovieFolderPostersAccess-\(UUID().uuidString)")
            let expected = Data("MovieFolderPosters access check".utf8)
            try Task.checkCancellation()
            try expected.write(to: probe, options: [.withoutOverwriting])
            let actual: Data
            do {
                actual = try Data(contentsOf: probe)
            } catch {
                try FileManager.default.removeItem(at: probe)
                throw error
            }
            // Finish cleanup even if observation ends while the synchronous operation is running.
            try FileManager.default.removeItem(at: probe)
            guard actual == expected else { throw CocoaError(.fileReadCorruptFile) }
        }
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
