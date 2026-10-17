import AppKit
import Darwin
import ImageIO
import Testing
@testable import FileSystem

@Suite(.serialized)
struct FolderPostersTests {
    private let service = FileSystemService()

    @Test func portraitImageKeepsProportionsAndIsCentered() throws {
        let bounds = try service.posterBounds(for: CGSize(width: 200, height: 300))
        #expect(abs(bounds.width - 512 * 2 / 3) < 0.001)
        #expect(bounds.height == 512)
        #expect(abs(bounds.midX - 256) < 0.001)
        #expect(bounds.midY == 256)
    }

    @Test func landscapeImageKeepsProportionsAndIsCentered() throws {
        let bounds = try service.posterBounds(for: CGSize(width: 400, height: 200))
        #expect(bounds == CGRect(x: 0, y: 128, width: 512, height: 256))
    }

    @Test func invalidImageDimensionsAreRejected() {
        #expect(throws: FolderPosterError.self) { try service.posterBounds(for: .zero) }
        #expect(throws: FolderPosterError.self) {
            try service.posterBounds(for: CGSize(width: CGFloat.infinity, height: 200))
        }
    }

    @Test func nestedAndHiddenChildNamesAreRejected() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["..", "Movie/Subfolder", ".Hidden", ""] {
            #expect(throws: FolderPosterError.self) { try service.assignPoster(Data(), toChild: name, in: root) }
        }
    }

    @Test func missingChildIsRejected() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: FolderPosterError.self) { try service.assignPoster(Data(), toChild: "Missing", in: root) }
    }

    @Test func staleCandidateCannotAssignToReplacementDirectory() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let movie = root.appendingPathComponent("Movie", isDirectory: true)
        try FileManager.default.createDirectory(at: movie, withIntermediateDirectories: false)
        let identity = try service.readCurrentState(ofChild: "Movie", in: root).identity
        try FileManager.default.removeItem(at: movie)
        try FileManager.default.createDirectory(at: movie, withIntermediateDirectories: false)

        #expect(throws: FolderPosterError.self) {
            try service.assignPoster(Data(), toChild: "Movie", in: root, expectedIdentity: identity)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: movie.path).isEmpty)
    }

    @Test func regularFileIsRejectedWithoutChangingContents() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let movie = root.appendingPathComponent("Movie.mkv")
        let original = Data("Untouched movie".utf8)
        try original.write(to: movie)
        #expect(throws: FolderPosterError.self) {
            try service.assignPoster(Data(), toChild: "Movie.mkv", in: root)
        }
        #expect(try Data(contentsOf: movie) == original)
    }

    @Test func symbolicLinkChildIsRejected() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Real", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Link"), withDestinationURL: target)
        #expect(throws: FolderPosterError.self) {
            try service.assignPoster(Data(), toChild: "Link", in: root)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    @Test func malformedPosterDoesNotWriteIconMetadata() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let movie = root.appendingPathComponent("Movie", isDirectory: true)
        try FileManager.default.createDirectory(at: movie, withIntermediateDirectories: false)
        #expect(throws: FolderPosterError.self) {
            try service.assignPoster(Data([0, 1, 2]), toChild: "Movie", in: root)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: movie.path).isEmpty)
    }

    @Test func customIconIsAssignedOnceAndMovieContentsStayIntact() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let movie = root.appendingPathComponent("Movie", isDirectory: true)
        try FileManager.default.createDirectory(at: movie, withIntermediateDirectories: false)
        let file = movie.appendingPathComponent("movie.mkv")
        let original = Data("Untouched movie fixture".utf8)
        try original.write(to: file)

        #expect(try service.assignPoster(makePoster(), toChild: "Movie", in: root) == .assigned)
        #expect(try service.assignPoster(Data(), toChild: "Movie", in: root) == .existingIconPreserved)
        #expect(try Data(contentsOf: file) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["Movie"])
    }

    @Test func assignmentRecordsOwnershipAndReplacementRemainsOwned() throws {
        let (root, movie) = try makeMovieDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(try service.assignPoster(makePoster(), toChild: "Movie", in: root) == .assigned)
        #expect(try service.hasAssignedPoster(toChild: "Movie", in: root))
        #expect(try service.replaceAssignedPoster(makePoster(color: .blue), toChild: "Movie", in: root) == .assigned)
        #expect(try service.hasAssignedPoster(toChild: "Movie", in: root))
        #expect(try FileManager.default.contentsOfDirectory(atPath: movie.path) == ["Icon\r"])
    }

    @Test func legacyAssignmentRecordsRawAppearanceAndStyledReplacementUpdatesIt() throws {
        let (root, movie) = try makeMovieDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(try service.assignPoster(makePoster(), toChild: "Movie", in: root) == .assigned)
        #expect(try service.assignedPosterAppearance(toChild: "Movie", in: root) == .raw)
        #expect(try service.replaceAssignedPoster(makePoster(), toChild: "Movie", in: root,
                                                   appearance: .softFinish) == .assigned)
        #expect(try service.assignedPosterAppearance(toChild: "Movie", in: root) == .softFinish)
        #expect(try service.replaceAssignedPoster(makePoster(color: .blue), toChild: "Movie", in: root,
                                                   appearance: .matteFrame) == .assigned)
        #expect(try service.assignedPosterAppearance(toChild: "Movie", in: root) == .matteFrame)

        #expect(NSWorkspace.shared.setIcon(makeNSImage(color: .green), forFile: movie.path, options: []))
        #expect(try service.assignedPosterAppearance(toChild: "Movie", in: root) == nil)
    }

    @Test func appearanceAwareAssignmentRecordsSelectedStyle() throws {
        let (root, _) = try makeMovieDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(try service.assignPoster(makePoster(), toChild: "Movie", in: root,
                                        appearance: .softFinish) == .assigned)
        #expect(try service.assignedPosterAppearance(toChild: "Movie", in: root) == .softFinish)
    }

    @Test func automaticRestyleRequiresCurrentOwnedUnsuppressedIcon() throws {
        let (foreignRoot, foreignMovie) = try makeMovieDirectory()
        defer { try? FileManager.default.removeItem(at: foreignRoot) }
        #expect(try service.assignPoster(makePoster(), toChild: "Movie", in: foreignRoot) == .assigned)
        #expect(NSWorkspace.shared.setIcon(makeNSImage(color: .blue), forFile: foreignMovie.path, options: []))
        #expect(try service.restyleAssignedPoster(makePoster(), toChild: "Movie", in: foreignRoot,
                                                  appearance: .softFinish) == .existingIconPreserved)

        let (missingRoot, missingMovie) = try makeMovieDirectory()
        defer { try? FileManager.default.removeItem(at: missingRoot) }
        #expect(try service.assignPoster(makePoster(), toChild: "Movie", in: missingRoot) == .assigned)
        #expect(NSWorkspace.shared.setIcon(nil, forFile: missingMovie.path, options: []))
        #expect(try service.restyleAssignedPoster(makePoster(), toChild: "Movie", in: missingRoot,
                                                  appearance: .matteFrame) == .existingIconPreserved)
        #expect(try !service.hasCustomIcon(at: missingMovie))

        let (suppressedRoot, _) = try makeMovieDirectory()
        defer { try? FileManager.default.removeItem(at: suppressedRoot) }
        #expect(try service.assignPoster(makePoster(), toChild: "Movie", in: suppressedRoot) == .assigned)
        #expect(try service.removeAssignedPoster(toChild: "Movie", in: suppressedRoot))
        #expect(try service.restyleAssignedPoster(makePoster(), toChild: "Movie", in: suppressedRoot,
                                                  appearance: .softFinish) == .existingIconPreserved)
        #expect(try service.isPosterSuppressed(toChild: "Movie", in: suppressedRoot))
    }

    @Test func explicitStyledAssignmentOverridesSuppressionAndLegacyRemainsRaw() throws {
        let (root, _) = try makeMovieDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(try service.assignPoster(makePoster(), toChild: "Movie", in: root) == .assigned)
        #expect(try service.removeAssignedPoster(toChild: "Movie", in: root))
        #expect(try service.assignPoster(makePoster(), toChild: "Movie", in: root) == .existingIconPreserved)
        #expect(try service.replaceAssignedPoster(makePoster(), toChild: "Movie", in: root,
                                                  appearance: .matteFrame) == .assigned)
        #expect(try service.assignedPosterAppearance(toChild: "Movie", in: root) == .matteFrame)
    }

    @Test func ownershipMarkerWithoutAppearanceDecodesAsRaw() throws {
        let (root, movie) = try makeMovieDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try service.assignPoster(makePoster(), toChild: "Movie", in: root,
                                        appearance: .softFinish) == .assigned)

        let icon = movie.appendingPathComponent("Icon\r")
        let descriptor = open(icon.path, O_RDONLY | O_NOFOLLOW)
        #expect(descriptor >= 0)
        guard descriptor >= 0 else { return }
        defer { _ = close(descriptor) }
        let attribute = "com.moviefolderposters.ownership"
        let length = fgetxattr(descriptor, attribute, nil, 0, 0, 0)
        #expect(length > 0)
        guard length > 0 else { return }
        var markerData = Data(count: length)
        let readCount = markerData.withUnsafeMutableBytes { bytes in
            fgetxattr(descriptor, attribute, bytes.baseAddress, length, 0, 0)
        }
        #expect(readCount == length)
        var marker = try #require(JSONSerialization.jsonObject(with: markerData) as? [String: String])
        marker.removeValue(forKey: "appearance")
        markerData = try JSONSerialization.data(withJSONObject: marker)
        let writeCount = markerData.withUnsafeBytes { bytes in
            fsetxattr(descriptor, attribute, bytes.baseAddress, bytes.count, 0, 0)
        }
        #expect(writeCount == 0)
        #expect(try service.assignedPosterAppearance(toChild: "Movie", in: root) == .raw)
    }

    @Test func userReplacementIsPreservedAndCannotBeRemoved() throws {
        let (root, movie) = try makeMovieDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try service.assignPoster(makePoster(), toChild: "Movie", in: root) == .assigned)
        #expect(NSWorkspace.shared.setIcon(makeNSImage(color: .blue), forFile: movie.path, options: []))

        #expect(try !service.hasAssignedPoster(toChild: "Movie", in: root))
        #expect(try service.replaceAssignedPoster(makePoster(), toChild: "Movie", in: root) == .existingIconPreserved)
        #expect(try !service.removeAssignedPoster(toChild: "Movie", in: root))
        #expect(try service.hasCustomIcon(at: movie))
    }

    @Test func clearedIconIsNotOwnedEvenWhenIconFileRemains() throws {
        let (root, movie) = try makeMovieDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try service.assignPoster(makePoster(), toChild: "Movie", in: root) == .assigned)
        #expect(NSWorkspace.shared.setIcon(nil, forFile: movie.path, options: []))

        #expect(try !service.hasAssignedPoster(toChild: "Movie", in: root))
        #expect(try !service.removeAssignedPoster(toChild: "Movie", in: root))
    }

    @Test func removalSuppressesAutomaticAssignmentUntilExplicitReplacement() throws {
        let (root, _) = try makeMovieDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try service.assignPoster(makePoster(), toChild: "Movie", in: root) == .assigned)
        #expect(try service.removeAssignedPoster(toChild: "Movie", in: root))
        #expect(try service.isPosterSuppressed(toChild: "Movie", in: root))
        #expect(try service.assignPoster(makePoster(), toChild: "Movie", in: root) == .existingIconPreserved)
        #expect(try service.assignPoster(makePoster(color: .blue), toChild: "Movie", in: root)
                == .existingIconPreserved)
        #expect(try service.replaceAssignedPoster(makePoster(color: .blue), toChild: "Movie", in: root) == .assigned)
        #expect(try !service.isPosterSuppressed(toChild: "Movie", in: root))
    }

    @Test func explicitAssignmentClearsRemovalSuppression() throws {
        let (root, movie) = try makeMovieDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try service.assignPoster(makePoster(), toChild: "Movie", in: root) == .assigned)
        #expect(try service.removeAssignedPoster(toChild: "Movie", in: root))
        #expect(try service.isPosterSuppressed(toChild: "Movie", in: root))

        #expect(try service.replaceAssignedPoster(makePoster(color: .blue), toChild: "Movie", in: root) == .assigned)
        #expect(try !service.isPosterSuppressed(toChild: "Movie", in: root))
        #expect(try service.hasAssignedPoster(toChild: "Movie", in: root))
        #expect(try service.hasCustomIcon(at: movie))
    }

    @Test func staleIdentityCannotRemovePosterAndInvalidDataLeavesItIntact() throws {
        let (root, movie) = try makeMovieDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = try service.readCurrentState(ofChild: "Movie", in: root).identity
        #expect(try service.assignPoster(makePoster(), toChild: "Movie", in: root) == .assigned)
        #expect(throws: FolderPosterError.self) {
            try service.replaceAssignedPoster(Data([0, 1, 2]), toChild: "Movie", in: root)
        }
        #expect(try service.hasAssignedPoster(toChild: "Movie", in: root))
        #expect(throws: FolderPosterError.self) {
            try service.removeAssignedPoster(toChild: "Movie", in: root, expectedIdentity: "stale")
        }
        #expect(try service.hasAssignedPoster(toChild: "Movie", in: root, expectedIdentity: identity))
        #expect(try FileManager.default.contentsOfDirectory(atPath: movie.path) == ["Icon\r"])
    }

    private func makeDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func makePoster(color: NSColor = .red) throws -> Data {
        let context = try #require(CGContext(data: nil, width: 200, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: 2))
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func makeNSImage(color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 64, height: 64))
        image.lockFocus()
        color.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 64, height: 64)).fill()
        image.unlockFocus()
        return image
    }

    private func makeMovieDirectory() throws -> (URL, URL) {
        let root = try makeDirectory()
        let movie = root.appendingPathComponent("Movie", isDirectory: true)
        try FileManager.default.createDirectory(at: movie, withIntermediateDirectories: false)
        return (root, movie)
    }
}
