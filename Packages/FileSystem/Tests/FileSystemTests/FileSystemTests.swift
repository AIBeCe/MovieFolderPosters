import Foundation
import Testing
@testable import FileSystem

struct FileSystemTests {
    @Test func rejectsNonFileDirectoryURL() throws {
        let directory = try #require(URL(string: "https://example.com/movies"))

        do {
            _ = try FileSystemService().makeDirectoryBookmark(for: directory)
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
        try Data().write(to: file)

        do {
            _ = try FileSystemService().makeDirectoryBookmark(for: file)
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
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)

        do {
            _ = try FileSystemService().makeDirectoryBookmark(for: link)
            Issue.record("Expected a symbolic-link directory to be rejected")
        } catch DirectoryAccessError.invalidDirectory {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func malformedBookmarkDoesNotRunOperation() {
        var operationRan = false

        do {
            try FileSystemService().withDirectoryAccess(bookmark: Data([0, 1, 2])) { _ in
                operationRan = true
            }
            Issue.record("Expected malformed bookmark data to be rejected")
        } catch {
            #expect(!operationRan)
        }
        #expect(!operationRan)
    }

    @Test func accessProbePreservesExistingContents() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let movie = root.appendingPathComponent("movie.mkv")
        let expected = Data("Unchanged movie fixture".utf8)
        try expected.write(to: movie)

        try FileSystemService().verifyReadWriteAccess(in: root)

        #expect(try Data(contentsOf: movie) == expected)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["movie.mkv"])
    }

    @Test func accessProbeRejectsRegularFileWithoutModifyingIt() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let movie = root.appendingPathComponent("movie.mkv")
        let expected = Data("Unchanged movie fixture".utf8)
        try expected.write(to: movie)

        #expect(throws: DirectoryAccessError.self) {
            try FileSystemService().verifyReadWriteAccess(in: movie)
        }
        #expect(try Data(contentsOf: movie) == expected)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["movie.mkv"])
    }

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
}
