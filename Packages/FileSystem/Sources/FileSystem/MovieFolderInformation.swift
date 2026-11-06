import CryptoKit
import Darwin
import Foundation

/// Explicit opt-in sources for immediate movie-folder information.
public struct MovieFolderInformationOptions: Sendable {
  /// Whether bounded NFO bytes are read.
  public let readsNFOInformation: Bool
  /// Whether video filenames are inspected without opening video contents.
  public let readsImmediateVideoNames: Bool
  /// Whether image filenames are inspected without opening image contents.
  public let readsImmediateImageNames: Bool
  /// Whether any filesystem information was selected.
  public var isEnabled: Bool { readsNFOInformation || readsImmediateVideoNames || readsImmediateImageNames }

  /// Captures explicit source choices; omitted choices perform no local reads.
  public init(readsNFOInformation: Bool = false, readsImmediateVideoNames: Bool = false,
    readsImmediateImageNames: Bool = false) {
    self.readsNFOInformation = readsNFOInformation
    self.readsImmediateVideoNames = readsImmediateVideoNames
    self.readsImmediateImageNames = readsImmediateImageNames
  }
}

/// One verified regular immediate file; only NFO content may be present.
public struct MovieFolderInformationFile: Sendable {
  /// Original immediate filename.
  public let name: String
  /// Bounded NFO bytes, retained only in memory for this attempt.
  public let nfoContents: Data?
}

/// Bounded information read under pinned root and child directory identities.
public struct MovieFolderInformationReadResult: Sendable {
  /// Relevant verified files, sorted by their original names.
  public let files: [MovieFolderInformationFile]
  /// False when a selected source could not be read completely and safely.
  public let isComplete: Bool
  /// SHA-256 of options, completeness, relevant identities, metadata and NFO bytes.
  public let sha256: String
}

extension FileSystemService {
  /// Reads only selected immediate information inside a previously authorized child directory.
  ///
  /// Does not authorize access, recurse, open media contents, follow symbolic links, or write files.
  /// - Parameters:
  ///   - name: One immediate child component.
  ///   - directory: Authorized collection root, retained by the caller while reading.
  ///   - expectedIdentity: Required captured device/inode/birth identity of the movie folder.
  ///   - options: Independent explicitly enabled sources.
  /// - Returns: Bounded in-memory information, completeness, and its SHA-256 value.
  /// - Throws: Cancellation, invalid paths, unavailable directories or changed directory identity.
  public func movieInformation(toChild name: String, in directory: URL, expectedIdentity: String,
    options: MovieFolderInformationOptions) throws -> MovieFolderInformationReadResult {
    var reader = MovieFolderInformationReader(options: options)

    guard options.isEnabled else { return reader.readResult }
    guard directory.isFileURL, !directory.path.contains("\0"), !name.isEmpty, name != ".", name != "..",
      !name.contains("/"), !name.contains("\0") else {
      throw DirectoryAccessError.invalidDirectory
    }

    let root = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)

    guard root >= 0 else { throw DirectoryAccessError.accessDenied }

    defer { close(root) }
    let initialRoot = try reader.directoryInfo(root)
    let child = openat(root, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)

    guard child >= 0 else { throw DirectoryAccessError.invalidDirectory }

    defer { close(child) }
    let initialChild = try reader.directoryInfo(child)

    guard reader.identity(initialChild) == expectedIdentity else { throw DirectoryAccessError.identityChanged }

    try reader.verifyPaths(root: initialRoot, child: initialChild, name: name, directory: directory, rootFD: root)
    try reader.inspect(child)
    reader.verifyEntries(in: child)
    let finalChild = try reader.directoryInfo(child)

    guard reader.identity(finalChild) == expectedIdentity else { throw DirectoryAccessError.identityChanged }

    if reader.metadata(initialChild) != reader.metadata(finalChild) { reader.isComplete = false }
    try reader.verifyPaths(root: initialRoot, child: initialChild, name: name, directory: directory, rootFD: root)

    return reader.readResult
  }
}

/// Descriptor-owned synchronous read; all temporary contents disappear with this value.
struct MovieFolderInformationReader {
  /// Supported video-name extensions, without reading media bytes.
  private let videoExtensions: Set<String> = ["mkv", "mp4", "m4v", "avi", "mov", "mpg", "mpeg", "ts"]
  /// Supported image-name extensions; images never become poster artwork.
  private let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "heic", "tif", "tiff", "bmp", "avif"]
  /// Explicit captured source choices.
  let options: MovieFolderInformationOptions
  /// Whether enumeration and every selected file were complete.
  var isComplete = true
  /// Verified selected files, paired with canonical descriptor metadata.
  private var entries: [(file: MovieFolderInformationFile, metadata: String)] = []
  /// Total NFO bytes successfully retained for this movie folder.
  private var nfoBytes = 0
  /// Count of selected NFO entries, including rejected ones.
  private var nfoCount = 0
  /// Canonical read result whose SHA-256 value never persists source contents.
  var readResult: MovieFolderInformationReadResult {
    let sorted = entries.sorted { $0.file.name.utf8.lexicographicallyPrecedes($1.file.name.utf8) }
    var hasher = SHA256()
    hasher.update(data: Data("MovieFolderInformation:v1:".utf8))
    let flags = [options.readsNFOInformation, options.readsImmediateVideoNames,
      options.readsImmediateImageNames, isComplete]
    for flag in flags { hasher.update(data: Data([flag ? 1 : 0])) }
    for entry in sorted {
      for bytes in [Data(entry.file.name.utf8), Data(entry.metadata.utf8), entry.file.nfoContents ?? Data()] {
        hasher.update(data: Data("\(bytes.count):".utf8))
        hasher.update(data: bytes)
      }
    }

    return MovieFolderInformationReadResult(files: sorted.map(\.file), isComplete: isComplete,
      sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined())
  }

  /// Creates an empty read result for the selected sources.
  init(options: MovieFolderInformationOptions) { self.options = options }

  /// Enumerates no more than 1,025 non-dot entries, counting all filenames regardless of source eligibility.
  mutating func inspect(_ descriptor: Int32) throws {
    let duplicate = dup(descriptor)

    guard duplicate >= 0 else { isComplete = false; return }
    guard let stream = fdopendir(duplicate) else { close(duplicate); isComplete = false; return }

    defer { closedir(stream) }
    var count = 0
    while true {
      try Task.checkCancellation()
      errno = 0

      guard let entry = readdir(stream) else {
        if errno != 0 { isComplete = false }
        return
      }

      let name = withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
      }
      if name == "." || name == ".." { continue }
      count += 1

      guard count <= 1_024 else { isComplete = false; return }

      inspectEntry(name, in: descriptor)
    }
  }

  /// Rechecks every selected entry after all reads, detecting edits to earlier files during later reads.
  mutating func verifyEntries(in descriptor: Int32) {
    for entry in entries {
      var current = stat()
      if fstatat(descriptor, entry.file.name, &current, AT_SYMLINK_NOFOLLOW) != 0
        || current.st_mode & S_IFMT != S_IFREG || metadata(current) != entry.metadata {
        isComplete = false
      }
    }
  }

  /// Classifies a selected immediate entry without following links or opening media files.
  private mutating func inspectEntry(_ name: String, in descriptor: Int32) {
    let suffix = (name as NSString).pathExtension.lowercased()
    let isNFO = options.readsNFOInformation && suffix == "nfo"
    let selected = isNFO || (options.readsImmediateVideoNames && videoExtensions.contains(suffix))
      || (options.readsImmediateImageNames && imageExtensions.contains(suffix))

    guard selected else { return }

    var classified = stat()

    guard fstatat(descriptor, name, &classified, AT_SYMLINK_NOFOLLOW) == 0,
      classified.st_mode & S_IFMT == S_IFREG else { isComplete = false; return }

    var contents: Data?
    if isNFO {
      nfoCount += 1

      guard nfoCount <= 8, classified.st_size >= 0, classified.st_size <= 256 * 1_024,
        nfoBytes + Int(classified.st_size) <= 1_024 * 1_024 else { isComplete = false; return }

      contents = readNFO(name, in: descriptor, classified: classified)

      guard let contents else { isComplete = false; return }

      nfoBytes += contents.count
    }
    var current = stat()

    guard fstatat(descriptor, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
      metadata(current) == metadata(classified) else { isComplete = false; return }

    entries.append((MovieFolderInformationFile(name: name, nfoContents: contents), metadata(classified)))
  }

  /// Reads through a nonblocking no-follow descriptor, with a bounded overflow probe and identity checks.
  private func readNFO(_ name: String, in directory: Int32, classified: stat) -> Data? {
    let file = openat(directory, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)

    guard file >= 0 else { return .none }

    defer { close(file) }
    var opened = stat()

    guard fstat(file, &opened) == 0, metadata(opened) == metadata(classified),
      opened.st_mode & S_IFMT == S_IFREG else { return .none }

    var contents = Data()
    var buffer = [UInt8](repeating: 0, count: 8_192)
    while contents.count <= 256 * 1_024 {
      if Task.isCancelled { return .none }
      let remaining = 256 * 1_024 + 1 - contents.count
      let count = read(file, &buffer, min(buffer.count, remaining))
      if count < 0 {
        if errno == EINTR { continue }
        return .none
      }
      if count == 0 { break }
      contents.append(contentsOf: buffer.prefix(count))
    }
    var finished = stat()

    guard contents.count == classified.st_size, contents.count <= 256 * 1_024,
      fstat(file, &finished) == 0, metadata(finished) == metadata(classified) else { return .none }

    return contents
  }

  /// Reads metadata from a pinned directory descriptor.
  func directoryInfo(_ descriptor: Int32) throws -> stat {
    var info = stat()

    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
      throw DirectoryAccessError.identityChanged
    }

    return info
  }

  /// Stable child identity shared with the existing inventory contract.
  func identity(_ info: stat) -> String {
    "\(info.st_dev):\(info.st_ino):\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec)"
  }

  /// Metadata sensitive to replacement, content edits and file-type changes.
  func metadata(_ info: stat) -> String {
    identity(info) + ":\(info.st_mode):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec)"
      + ":\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
  }

  /// Confirms the current authorized paths still designate the opened directories.
  func verifyPaths(root: stat, child: stat, name: String, directory: URL, rootFD: Int32) throws {
    var currentRoot = stat()
    var currentChild = stat()

    guard lstat(directory.path, &currentRoot) == 0, identity(currentRoot) == identity(root),
      currentRoot.st_mode & S_IFMT == S_IFDIR,
      fstatat(rootFD, name, &currentChild, AT_SYMLINK_NOFOLLOW) == 0,
      currentChild.st_mode & S_IFMT == S_IFDIR, identity(currentChild) == identity(child) else {
      throw DirectoryAccessError.identityChanged
    }
  }
}
