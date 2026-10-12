import Foundation
import Testing
@testable import FileSystem

struct DirectoryAuthorizationTests {
    @Test func implicitBookmarkResolvesToReadableLease() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("existing content".utf8).write(to: directory.appendingPathComponent("movie.mkv"))
        let service = FileSystemService()

        let bookmark = try service.makeTransferBookmark(for: directory)
        let lease = try service.acquireDirectoryAccess(bookmark: bookmark, securityScoped: false)

        #expect(lease.url.standardizedFileURL == directory.standardizedFileURL)
        #expect(try FileManager.default.contentsOfDirectory(atPath: lease.url.path) == ["movie.mkv"])
    }

    @Test func transferBookmarkRejectsFileAndSymbolicLink() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Movies", isDirectory: true)
        let file = root.appendingPathComponent("movie.mkv")
        let link = root.appendingPathComponent("MoviesLink")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data().write(to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)

        #expect(throws: DirectoryAccessError.self) {
            try FileSystemService().makeTransferBookmark(for: file)
        }
        #expect(throws: DirectoryAccessError.self) {
            try FileSystemService().makeTransferBookmark(for: link)
        }
    }

    @Test func malformedBookmarkIsRejected() {
        #expect(throws: DirectoryAccessError.self) {
            try FileSystemService().acquireDirectoryAccess(bookmark: Data([0, 1, 2]), securityScoped: false)
        }
    }

    @Test func movedDirectoryBookmarkIsRejectedAsStale() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("Movies", isDirectory: true)
        let moved = root.appendingPathComponent("RenamedMovies", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
        let bookmark = try FileSystemService().makeTransferBookmark(for: original)
        try FileManager.default.moveItem(at: original, to: moved)

        do {
            _ = try FileSystemService().acquireDirectoryAccess(
                bookmark: bookmark,
                securityScoped: false
            )
            Issue.record("Expected a moved directory bookmark to be rejected as stale")
        } catch DirectoryAccessError.staleBookmark {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func leaseCanBeHeldAcrossSuspension() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bookmark = try FileSystemService().makeTransferBookmark(for: directory)
        let lease = try FileSystemService().acquireDirectoryAccess(bookmark: bookmark, securityScoped: false)

        let names = await Task.detached {
            await Task.yield()
            return try? FileManager.default.contentsOfDirectory(atPath: lease.url.path)
        }.value

        #expect(names != nil)
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("FileSystemAuthorization-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory
}
