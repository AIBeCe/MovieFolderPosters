import Foundation
import Testing
@testable import FileSystem

struct FileSystemTests {
    @Test func rejectsNonFileDirectoryURL() throws {
        let directory = try #require(URL(string: "https://example.com/movies"))
        let document = FileManager.default.temporaryDirectory.appendingPathComponent("authorization")

        do {
            _ = try FileSystemService().makeDirectoryBookmark(for: directory, relativeTo: document)
            Issue.record("Expected a non-file URL to be rejected")
        } catch DirectoryAccessError.invalidDirectory {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func rejectsRegularFileAsDirectory() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("movie.mkv")
        let document = root.appendingPathComponent("scope")
        try Data().write(to: file)

        do {
            _ = try FileSystemService().makeDirectoryBookmark(for: file, relativeTo: document)
            Issue.record("Expected a regular file to be rejected")
        } catch DirectoryAccessError.invalidDirectory {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func rejectsSymbolicLinkToDirectory() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Movies", isDirectory: true)
        let link = root.appendingPathComponent("MoviesLink")
        let document = root.appendingPathComponent("scope")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)

        do {
            _ = try FileSystemService().makeDirectoryBookmark(for: link, relativeTo: document)
            Issue.record("Expected a symbolic-link directory to be rejected")
        } catch DirectoryAccessError.invalidDirectory {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func malformedBookmarkDoesNotRunOperation() {
        var operationRan = false
        let document = FileManager.default.temporaryDirectory.appendingPathComponent("authorization")

        do {
            try FileSystemService().withDirectoryAccess(bookmark: Data([0, 1, 2]), relativeTo: document) { _ in
                operationRan = true
            }
            Issue.record("Expected malformed bookmark data to be rejected")
        } catch {
            #expect(!operationRan)
        }
        #expect(!operationRan)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
}
