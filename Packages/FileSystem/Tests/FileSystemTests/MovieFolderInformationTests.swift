import Foundation
import Darwin
import Testing
@testable import FileSystem

/// Disabled source choices perform no directory access, even when the supplied fixture path does not exist.
@Test func movieInformationReadResultDisabledDoesNotOpenDirectories() throws {
  let readResult = try FileSystemService().movieInformation(toChild: "Movie",
    in: URL(fileURLWithPath: "/Absent-R120-04-\(UUID().uuidString)"),
    expectedIdentity: "not-inspected", options: .init())
  #expect(readResult.isComplete)
  #expect(readResult.files.isEmpty)
}

/// Reading is opt-in, immediate-only, and treats media as names rather than readable contents.
@Test func movieInformationReadResultIsOptInAndNonrecursive() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let child = root.appendingPathComponent("Movie")
  try FileManager.default.createDirectory(at: child.appendingPathComponent("nested"), withIntermediateDirectories: true)
  try Data("<movie><title>Alien</title></movie>".utf8).write(to: child.appendingPathComponent("movie.nfo"))
  try Data().write(to: child.appendingPathComponent("Alien (1979).MKV"))
  try Data().write(to: child.appendingPathComponent("nested/Other.mp4"))
  let service = FileSystemService()
  let identity = try service.fileIdentity(at: child)
  let disabled = try service.movieInformation(toChild: "Movie", in: root, expectedIdentity: identity,
    options: .init())
  #expect(disabled.files.isEmpty)
  let enabled = try service.movieInformation(toChild: "Movie", in: root, expectedIdentity: identity,
    options: .init(readsNFOInformation: true, readsImmediateVideoNames: true))
  #expect(enabled.isComplete)
  #expect(Set(enabled.files.map(\.name)) == ["movie.nfo", "Alien (1979).MKV"])
  #expect(enabled.files.first(where: { $0.name.hasSuffix("MKV") })?.nfoContents == .none)
}

/// A file edited after its individual read invalidates the complete read result before it can be returned.
@Test func movieInformationReadResultRechecksEarlierFiles() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let file = directory.appendingPathComponent("movie.nfo")
  try Data("<movie><title>Alien</title></movie>".utf8).write(to: file)
  let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
  try #require(descriptor >= 0)
  defer { close(descriptor) }
  var reader = MovieFolderInformationReader(options: .init(readsNFOInformation: true))
  try reader.inspect(descriptor)
  #expect(reader.readResult.isComplete)
  let handle = try FileHandle(forWritingTo: file)
  try handle.seekToEnd()
  try handle.write(contentsOf: Data(" ".utf8))
  try handle.close()
  reader.verifyEntries(in: descriptor)
  #expect(!reader.readResult.isComplete)
}

/// Selected symlinks and over-limit NFO bytes are incomplete rather than a useful subset.
@Test func movieInformationReadResultRejectsLinksAndOversizedNFO() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let child = root.appendingPathComponent("Movie")
  try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
  let service = FileSystemService()
  let identity = try service.fileIdentity(at: child)
  try FileManager.default.createSymbolicLink(atPath: child.appendingPathComponent("movie.nfo").path,
    withDestinationPath: "/absent")
  #expect(try !service.movieInformation(toChild: "Movie", in: root, expectedIdentity: identity,
    options: .init(readsNFOInformation: true)).isComplete)
  try FileManager.default.removeItem(at: child.appendingPathComponent("movie.nfo"))
  try Data(repeating: 32, count: 256 * 1_024 + 1).write(to: child.appendingPathComponent("movie.nfo"))
  #expect(try !service.movieInformation(toChild: "Movie", in: root, expectedIdentity: identity,
    options: .init(readsNFOInformation: true)).isComplete)
}

/// Entry enumeration counts ignored files and stops at the exact approved boundary.
@Test(arguments: [1_024, 1_025])
func movieInformationReadResultEnforcesDirectoryEntryBudget(count: Int) throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let child = root.appendingPathComponent("Movie")
  try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
  for index in 0..<count { try Data().write(to: child.appendingPathComponent("ignored-\(index).txt")) }
  let service = FileSystemService()
  let identity = try service.fileIdentity(at: child)
  let readResult = try service.movieInformation(toChild: "Movie", in: root, expectedIdentity: identity,
    options: .init(readsNFOInformation: true))
  #expect(readResult.isComplete == (count == 1_024))
  #expect(readResult.files.isEmpty)
}

/// NFO count, individual bytes and total bytes have inclusive bounded maxima.
@Test(arguments: [(8, 1), (9, 1), (1, 256 * 1_024), (4, 256 * 1_024), (5, 256 * 1_024)])
func movieInformationReadResultEnforcesNFOBudgets(count: Int, bytes: Int) throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let child = root.appendingPathComponent("Movie")
  try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
  for index in 0..<count {
    try Data(repeating: 32, count: bytes).write(to: child.appendingPathComponent("\(index).nfo"))
  }
  let service = FileSystemService()
  let readResult = try service.movieInformation(toChild: "Movie", in: root,
    expectedIdentity: service.fileIdentity(at: child), options: .init(readsNFOInformation: true))
  #expect(readResult.isComplete == (count <= 8 && count * bytes <= 1_024 * 1_024))
}

/// Captured child identity cannot be reused for a replacement directory.
@Test func movieInformationReadResultRejectsReplacementDirectory() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let child = root.appendingPathComponent("Movie")
  try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
  let service = FileSystemService()
  let identity = try service.fileIdentity(at: child)
  try FileManager.default.moveItem(at: child, to: root.appendingPathComponent("previous"))
  try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
  #expect(throws: DirectoryAccessError.self) {
    try service.movieInformation(toChild: "Movie", in: root, expectedIdentity: identity,
      options: .init(readsNFOInformation: true))
  }
}

/// Every approved media extension is recognized case-insensitively without opening its contents.
@Test(arguments: ["mkv", "mp4", "m4v", "avi", "mov", "mpg", "mpeg", "ts", "jpg", "jpeg", "png",
  "webp", "heic", "tif", "tiff", "bmp", "avif"])
func movieInformationReadResultRecognizesApprovedFormats(suffix: String) throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let child = root.appendingPathComponent("Movie")
  try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
  let name = "Alien (1979)." + suffix.uppercased()
  try Data("unreadable media content".utf8).write(to: child.appendingPathComponent(name))
  let service = FileSystemService()
  let readResult = try service.movieInformation(toChild: "Movie", in: root,
    expectedIdentity: service.fileIdentity(at: child),
    options: .init(readsImmediateVideoNames: true, readsImmediateImageNames: true))
  #expect(readResult.isComplete)
  #expect(readResult.files.map(\.name) == [name])
  #expect(readResult.files.first?.nfoContents == .none)
}
