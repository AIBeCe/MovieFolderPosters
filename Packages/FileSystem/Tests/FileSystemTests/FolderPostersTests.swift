import AppKit
import Darwin
import ImageIO
import Testing

@testable import FileSystem

@Suite(.serialized)
/// Exercises safe icon assignment, ownership tracking, suppression, and user-icon preservation.
struct FolderPostersTests {
  /// Service instance shared by the tests in this suite.
  private let service = FileSystemService()

  /// Scenario: portrait image keeps proportions and is centered.
  @Test func portraitImageKeepsProportionsAndIsCentered() throws {
    let bounds = try service.posterBounds(for: CGSize(width: 200, height: 300))
    #expect(abs(bounds.width - 512 * 2 / 3) < 0.001)
    #expect(bounds.height == 512)
    #expect(abs(bounds.midX - 256) < 0.001)
    #expect(bounds.midY == 256)
  }

  /// Scenario: landscape image keeps proportions and is centered.
  @Test func landscapeImageKeepsProportionsAndIsCentered() throws {
    let bounds = try service.posterBounds(for: CGSize(width: 400, height: 200))
    #expect(bounds == CGRect(x: 0, y: 128, width: 512, height: 256))
  }

  /// Scenario: invalid image dimensions are rejected.
  @Test func invalidImageDimensionsAreRejected() {
    #expect(throws: FolderPosterError.self) { try service.posterBounds(for: .zero) }
    #expect(throws: FolderPosterError.self) {
      try service.posterBounds(for: CGSize(width: CGFloat.infinity, height: 200))
    }
  }

  /// Scenario: nested and hidden child names are rejected.
  @Test func nestedAndHiddenChildNamesAreRejected() throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["..", "Movie/Subfolder", ".Hidden", ""] {
      #expect(throws: FolderPosterError.self) {
        try service.assignPoster(Data(), toChild: name, in: root)
      }
    }
  }

  /// Scenario: missing child is rejected.
  @Test func missingChildIsRejected() throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(throws: FolderPosterError.self) {
      try service.assignPoster(Data(), toChild: "Missing", in: root)
    }
  }

  /// Scenario: stale candidate cannot assign to replacement directory.
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

  /// Scenario: regular file is rejected without changing contents.
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

  /// Scenario: symbolic link child is rejected.
  @Test func symbolicLinkChildIsRejected() throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("Real", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("Link"), withDestinationURL: target)
    #expect(throws: FolderPosterError.self) {
      try service.assignPoster(Data(), toChild: "Link", in: root)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
  }

  /// Scenario: malformed poster does not write icon metadata.
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

  /// Scenario: custom icon is assigned once and movie contents stay intact.
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

  /// Scenario: assignment records ownership and replacement remains owned.
  @Test func assignmentRecordsOwnershipAndReplacementRemainsOwned() throws {
    let (root, movie) = try makeMovieDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(try service.assignPoster(makePoster(), toChild: "Movie", in: root) == .assigned)
    #expect(try service.hasAssignedPoster(toChild: "Movie", in: root))
    let inspection = try service.inspectPoster(toChild: "Movie", in: root)
    #expect(inspection.ownership == .owned)
    #expect(inspection.appearance == .raw)
    #expect(
      try service.replaceAssignedPoster(makePoster(color: .blue), toChild: "Movie", in: root)
        == .assigned)
    #expect(try service.hasAssignedPoster(toChild: "Movie", in: root))
    #expect(try FileManager.default.contentsOfDirectory(atPath: movie.path) == ["Icon\r"])
  }

  /// Scenario: strict inspection detects an externally changed owned icon.
  @Test func strictInspectionReportsChangedOwnership() throws {
    let (root, movie) = try makeMovieDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(try service.assignPoster(makePoster(), toChild: "Movie", in: root) == .assigned)
    let iconFile = movie.appendingPathComponent("Icon\r")
    let icon = try FileHandle(forWritingTo: iconFile)
    try icon.truncate(atOffset: 0)
    try icon.write(contentsOf: Data("changed icon bytes".utf8))
    try icon.close()
    #expect(try service.inspectPoster(toChild: "Movie", in: root).ownership == .changed)
    #expect(try service.removeAssignedPoster(toChild: "Movie", in: root) == false)
  }

  /// Scenario: legacy assignment records raw appearance and styled replacement updates it.
  @Test func legacyAssignmentRecordsRawAppearanceAndStyledReplacementUpdatesIt() throws {
    let (root, movie) = try makeMovieDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(try service.assignPoster(makePoster(), toChild: "Movie", in: root) == .assigned)
    #expect(try service.assignedPosterAppearance(toChild: "Movie", in: root) == .raw)
    #expect(
      try service.replaceAssignedPoster(
        makePoster(), toChild: "Movie", in: root,
        appearance: .softFinish) == .assigned)
    #expect(try service.assignedPosterAppearance(toChild: "Movie", in: root) == .softFinish)
    #expect(
      try service.replaceAssignedPoster(
        makePoster(color: .blue), toChild: "Movie", in: root,
        appearance: .matteFrame) == .assigned)
    #expect(try service.assignedPosterAppearance(toChild: "Movie", in: root) == .matteFrame)

    #expect(
      NSWorkspace.shared.setIcon(makeNSImage(color: .green), forFile: movie.path, options: []))
    #expect(try service.assignedPosterAppearance(toChild: "Movie", in: root) == nil)
  }

}

/// Poster appearance and ownership policy regression scenarios.
extension FolderPostersTests {
  /// Scenario: appearance aware assignment records selected style.
  @Test func appearanceAwareAssignmentRecordsSelectedStyle() throws {
    let (root, _) = try makeMovieDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(
      try service.assignPoster(
        makePoster(), toChild: "Movie", in: root,
        appearance: .softFinish) == .assigned)
    #expect(try service.assignedPosterAppearance(toChild: "Movie", in: root) == .softFinish)
  }

  /// Scenario: automatic restyle requires current owned unsuppressed icon.
  @Test func automaticRestyleRequiresCurrentOwnedUnsuppressedIcon() throws {
    let (foreignRoot, foreignMovie) = try makeMovieDirectory()
    defer { try? FileManager.default.removeItem(at: foreignRoot) }
    #expect(try service.assignPoster(makePoster(), toChild: "Movie", in: foreignRoot) == .assigned)
    #expect(
      NSWorkspace.shared.setIcon(makeNSImage(color: .blue), forFile: foreignMovie.path, options: [])
    )
    #expect(
      try service.restyleAssignedPoster(
        makePoster(), toChild: "Movie", in: foreignRoot,
        appearance: .softFinish) == .existingIconPreserved)

    let (missingRoot, missingMovie) = try makeMovieDirectory()
    defer { try? FileManager.default.removeItem(at: missingRoot) }
    #expect(try service.assignPoster(makePoster(), toChild: "Movie", in: missingRoot) == .assigned)
    #expect(NSWorkspace.shared.setIcon(nil, forFile: missingMovie.path, options: []))
    #expect(
      try service.restyleAssignedPoster(
        makePoster(), toChild: "Movie", in: missingRoot,
        appearance: .matteFrame) == .existingIconPreserved)
    #expect(try !service.hasCustomIcon(at: missingMovie))

    let (suppressedRoot, _) = try makeMovieDirectory()
    defer { try? FileManager.default.removeItem(at: suppressedRoot) }
    #expect(
      try service.assignPoster(makePoster(), toChild: "Movie", in: suppressedRoot) == .assigned)
    #expect(try service.removeAssignedPoster(toChild: "Movie", in: suppressedRoot))
    #expect(
      try service.restyleAssignedPoster(
        makePoster(), toChild: "Movie", in: suppressedRoot,
        appearance: .softFinish) == .existingIconPreserved)
    #expect(try service.isPosterSuppressed(toChild: "Movie", in: suppressedRoot))
  }

  /// Scenario: explicit styled assignment overrides suppression and legacy remains raw.
  @Test func explicitStyledAssignmentOverridesSuppressionAndLegacyRemainsRaw() throws {
    let (root, _) = try makeMovieDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(try service.assignPoster(makePoster(), toChild: "Movie", in: root) == .assigned)
    #expect(try service.removeAssignedPoster(toChild: "Movie", in: root))
    #expect(
      try service.assignPoster(makePoster(), toChild: "Movie", in: root) == .existingIconPreserved)
    #expect(
      try service.replaceAssignedPoster(
        makePoster(), toChild: "Movie", in: root,
        appearance: .matteFrame) == .assigned)
    #expect(try service.assignedPosterAppearance(toChild: "Movie", in: root) == .matteFrame)
  }

  /// Scenario: ownership marker without appearance decodes as raw.
  @Test func ownershipMarkerWithoutAppearanceDecodesAsRaw() throws {
    let (root, movie) = try makeMovieDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(
      try service.assignPoster(
        makePoster(), toChild: "Movie", in: root,
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

  /// Scenario: user replacement is preserved and cannot be removed.
  @Test func userReplacementIsPreservedAndCannotBeRemoved() throws {
    let (root, movie) = try makeMovieDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(try service.assignPoster(makePoster(), toChild: "Movie", in: root) == .assigned)
    #expect(NSWorkspace.shared.setIcon(makeNSImage(color: .blue), forFile: movie.path, options: []))

    #expect(try !service.hasAssignedPoster(toChild: "Movie", in: root))
    #expect(
      try service.replaceAssignedPoster(makePoster(), toChild: "Movie", in: root)
        == .existingIconPreserved)
    #expect(try !service.removeAssignedPoster(toChild: "Movie", in: root))
    #expect(try service.hasCustomIcon(at: movie))
  }

  /// Scenario: cleared icon is not owned even when icon file remains.
  @Test func clearedIconIsNotOwnedEvenWhenIconFileRemains() throws {
    let (root, movie) = try makeMovieDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(try service.assignPoster(makePoster(), toChild: "Movie", in: root) == .assigned)
    #expect(NSWorkspace.shared.setIcon(nil, forFile: movie.path, options: []))

    #expect(try !service.hasAssignedPoster(toChild: "Movie", in: root))
    #expect(try !service.removeAssignedPoster(toChild: "Movie", in: root))
  }

  /// Scenario: removal suppresses automatic assignment until explicit replacement.
  @Test func removalSuppressesAutomaticAssignmentUntilExplicitReplacement() throws {
    let (root, _) = try makeMovieDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(try service.assignPoster(makePoster(), toChild: "Movie", in: root) == .assigned)
    #expect(try service.removeAssignedPoster(toChild: "Movie", in: root))
    #expect(try service.isPosterSuppressed(toChild: "Movie", in: root))
    let inspection = try service.inspectPoster(toChild: "Movie", in: root)
    #expect(inspection.ownership == .none)
    #expect(inspection.isSuppressed)
    #expect(
      try service.assignPoster(makePoster(), toChild: "Movie", in: root) == .existingIconPreserved)
    #expect(
      try service.assignPoster(makePoster(color: .blue), toChild: "Movie", in: root)
        == .existingIconPreserved)
    #expect(
      try service.replaceAssignedPoster(makePoster(color: .blue), toChild: "Movie", in: root)
        == .assigned)
    #expect(try !service.isPosterSuppressed(toChild: "Movie", in: root))
  }

  /// Scenario: explicit assignment clears removal suppression.
  @Test func explicitAssignmentClearsRemovalSuppression() throws {
    let (root, movie) = try makeMovieDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(try service.assignPoster(makePoster(), toChild: "Movie", in: root) == .assigned)
    #expect(try service.removeAssignedPoster(toChild: "Movie", in: root))
    #expect(try service.isPosterSuppressed(toChild: "Movie", in: root))

    #expect(
      try service.replaceAssignedPoster(makePoster(color: .blue), toChild: "Movie", in: root)
        == .assigned)
    #expect(try !service.isPosterSuppressed(toChild: "Movie", in: root))
    #expect(try service.hasAssignedPoster(toChild: "Movie", in: root))
    #expect(try service.hasCustomIcon(at: movie))
  }

  /// Scenario: stale identity cannot remove poster and invalid data leaves it intact.
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
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    return root
  }

  private func makePoster(color: NSColor = .red) throws -> Data {
    let context = try #require(
      CGContext(
        data: nil, width: 200, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: 2))
    context.setFillColor(color.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(
      CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
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
