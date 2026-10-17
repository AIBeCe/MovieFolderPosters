import AppKit
import CryptoKit
import Darwin
import ImageIO
import Synchronization

/// Describes whether a poster was installed or an existing custom icon was left intact.
public enum PosterAssignmentResult: Sendable {
  case assigned
  case existingIconPreserved
}

/// Failures encountered while validating poster data or assigning Finder icons.
public enum FolderPosterError: Error {
  case invalidChild
  case invalidImage
  case iconAssignmentFailed
}

/// Serializes icon and ownership metadata mutations within this process.
private let iconAssignmentLock = Mutex<Void>(())
/// Extended attribute binding an icon to this app's ownership record.
private let ownershipAttribute = "com.moviefolderposters.ownership"
/// Extended attribute recording that a user removed an app-managed poster.
private let suppressionAttribute = "com.moviefolderposters.suppressed"
/// Finder's conventional custom icon file name.
private let iconFileName = "Icon\r"
/// Maximum accepted size for Finder's custom icon file and resource fork.
private let maximumIconBytes = 4 * 1024 * 1024

/// Encodes the directory identity, rendered icon digest, and selected appearance.
private struct PosterOwnership: Codable {
  /// The folder identity to which the icon belongs.
  let identity: String
  /// Digest of the icon file and resource fork at assignment time.
  let digest: String
  /// Appearance used to render the assigned poster.
  let appearance: PosterAppearance

  /// Creates an ownership record, defaulting legacy assignments to raw rendering.
  init(identity: String, digest: String, appearance: PosterAppearance = .raw) {
    self.identity = identity
    self.digest = digest
    self.appearance = appearance
  }

  /// Keys accepted by the backward-compatible ownership decoder.
  private enum CodingKeys: String, CodingKey { case identity, digest, appearance }

  /// Decodes ownership metadata and treats older records as raw appearance.
  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    identity = try values.decode(String.self, forKey: .identity)
    digest = try values.decode(String.self, forKey: .digest)
    appearance = try values.decodeIfPresent(PosterAppearance.self, forKey: .appearance) ?? .raw
  }
}

extension FileSystemService {
  /// Fits an image inside a canvas while preserving its aspect ratio.
  ///
  /// - Parameters:
  ///   - size: The image dimensions; both values must be finite and positive.
  ///   - canvas: The destination dimensions; both values must be finite and positive.
  /// - Returns: Centered bounds fully contained by the canvas.
  /// - Throws: ``FolderPosterError/invalidImage`` when either size is invalid.
  public func posterBounds(for size: CGSize, in canvas: CGSize = CGSize(width: 512, height: 512))
    throws -> CGRect
  {
    guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
      canvas.width.isFinite, canvas.height.isFinite, canvas.width > 0, canvas.height > 0
    else {
      throw FolderPosterError.invalidImage
    }
    let scale = min(canvas.width / size.width, canvas.height / size.height)
    let width = size.width * scale
    let height = size.height * scale
    return CGRect(
      x: (canvas.width - width) / 2, y: (canvas.height - height) / 2, width: width, height: height)
  }

  /// Assigns an unstyled poster only when the child has no existing custom icon.
  ///
  /// - Parameters:
  ///   - imageData: Encoded poster image bytes.
  ///   - name: The immediate child folder name.
  ///   - directory: The authorized parent directory.
  ///   - expectedIdentity: Optional identity that the child must match.
  /// - Returns: Whether the poster was assigned or an existing icon was preserved.
  /// - Throws: ``FolderPosterError`` for invalid children, images, or Finder icon assignment failures.
  public func assignPoster(
    _ imageData: Data, toChild name: String, in directory: URL, expectedIdentity: String? = nil
  ) throws -> PosterAssignmentResult {
    try assignPoster(
      imageData, toChild: name, in: directory, appearance: .raw,
      expectedIdentity: expectedIdentity)
  }

  /// Assigns a poster with the selected appearance when no custom icon is present.
  ///
  /// - Parameters:
  ///   - imageData: Encoded poster image bytes.
  ///   - name: The immediate child folder name.
  ///   - directory: The authorized parent directory.
  ///   - appearance: The visual treatment applied to the poster.
  ///   - expectedIdentity: Optional identity that the child must match.
  /// - Returns: Whether the poster was assigned or an existing icon was preserved.
  /// - Throws: ``FolderPosterError`` for invalid children, images, or Finder icon assignment failures.
  public func assignPoster(
    _ imageData: Data, toChild name: String, in directory: URL,
    appearance: PosterAppearance, expectedIdentity: String? = nil
  ) throws -> PosterAssignmentResult {
    try Task.checkCancellation()
    try validatePosterTarget(name, in: directory)
    let child = directory.appendingPathComponent(name, isDirectory: true)
    return try iconAssignmentLock.withLock { _ in
      let identity = try lockedIdentity(of: child, expected: expectedIdentity)
      if try suppressionExists(at: child, identity: identity) || hasCustomIcon(at: child) {
        return .existingIconPreserved
      }
      let image = try makePosterImage(from: imageData, appearance: appearance)
      try Task.checkCancellation()
      guard NSWorkspace.shared.setIcon(image, forFile: child.path, options: []) else {
        throw FolderPosterError.iconAssignmentFailed
      }
      recordOwnership(of: child, identity: identity, appearance: appearance)
      clearSuppression(at: child, identity: identity)
      return .assigned
    }
  }

  /// Reports whether the app still owns the current icon for the child identity.
  ///
  /// - Parameters:
  ///   - name: The immediate child folder name.
  ///   - directory: The authorized parent directory.
  ///   - expectedIdentity: Optional identity that the child must match.
  /// - Returns: `true` only when ownership metadata and the current icon digest agree.
  /// - Throws: ``FolderPosterError`` when the child cannot be safely inspected.
  public func hasAssignedPoster(
    toChild name: String, in directory: URL, expectedIdentity: String? = nil
  ) throws -> Bool {
    try validatePosterTarget(name, in: directory)
    let child = directory.appendingPathComponent(name, isDirectory: true)
    return try iconAssignmentLock.withLock { _ in
      let identity = try lockedIdentity(of: child, expected: expectedIdentity)
      return isOwnedIcon(at: child, identity: identity)
    }
  }

  /// Returns the appearance recorded for the currently owned icon.
  ///
  /// - Parameters:
  ///   - name: The immediate child folder name.
  ///   - directory: The authorized parent directory.
  ///   - expectedIdentity: Optional identity that the child must match.
  /// - Returns: The recorded appearance, or `nil` when the icon is not app-owned.
  /// - Throws: ``FolderPosterError`` when the child cannot be safely inspected.
  public func assignedPosterAppearance(
    toChild name: String, in directory: URL, expectedIdentity: String? = nil
  ) throws -> PosterAppearance? {
    try validatePosterTarget(name, in: directory)
    let child = directory.appendingPathComponent(name, isDirectory: true)
    return try iconAssignmentLock.withLock { _ in
      let identity = try lockedIdentity(of: child, expected: expectedIdentity)
      return assignedAppearance(at: child, identity: identity)
    }
  }

  /// Replaces the child's icon while preserving a custom icon not owned by this app.
  ///
  /// - Parameters:
  ///   - imageData: Encoded poster image bytes.
  ///   - name: The immediate child folder name.
  ///   - directory: The authorized parent directory.
  ///   - expectedIdentity: Optional identity that the child must match.
  /// - Returns: Whether the poster was assigned or an existing icon was preserved.
  /// - Throws: ``FolderPosterError`` when validation or icon assignment fails.
  public func replaceAssignedPoster(
    _ imageData: Data, toChild name: String, in directory: URL, expectedIdentity: String? = nil
  ) throws -> PosterAssignmentResult {
    try replaceAssignedPoster(
      imageData, toChild: name, in: directory, appearance: .raw,
      expectedIdentity: expectedIdentity)
  }

  /// Replaces the child's icon using a chosen appearance while preserving unowned icons.
  ///
  /// - Parameters:
  ///   - imageData: Encoded poster image bytes.
  ///   - name: The immediate child folder name.
  ///   - directory: The authorized parent directory.
  ///   - appearance: The visual treatment applied to the poster.
  ///   - expectedIdentity: Optional identity that the child must match.
  /// - Returns: Whether the poster was assigned or an existing icon was preserved.
  /// - Throws: ``FolderPosterError`` when validation or icon assignment fails.
  public func replaceAssignedPoster(
    _ imageData: Data, toChild name: String, in directory: URL,
    appearance: PosterAppearance, expectedIdentity: String? = nil
  ) throws -> PosterAssignmentResult {
    try validatePosterTarget(name, in: directory)
    let image = try makePosterImage(from: imageData, appearance: appearance)
    let child = directory.appendingPathComponent(name, isDirectory: true)
    return try iconAssignmentLock.withLock { _ in
      let identity = try lockedIdentity(of: child, expected: expectedIdentity)
      let ownsCurrentIcon = isOwnedIcon(at: child, identity: identity)
      if !ownsCurrentIcon, try hasCustomIcon(at: child) { return .existingIconPreserved }
      try Task.checkCancellation()
      guard NSWorkspace.shared.setIcon(image, forFile: child.path, options: []) else {
        throw FolderPosterError.iconAssignmentFailed
      }
      recordOwnership(of: child, identity: identity, appearance: appearance)
      clearSuppression(at: child, identity: identity)
      return .assigned
    }
  }

  /// Changes appearance only while the app still owns the current child icon.
  ///
  /// - Parameters:
  ///   - imageData: Encoded poster image bytes.
  ///   - name: The immediate child folder name.
  ///   - directory: The authorized parent directory.
  ///   - appearance: The new visual treatment.
  ///   - expectedIdentity: Optional identity that the child must match.
  /// - Returns: Whether the poster was restyled or an existing icon was preserved.
  /// - Throws: ``FolderPosterError`` when validation or icon assignment fails.
  public func restyleAssignedPoster(
    _ imageData: Data, toChild name: String, in directory: URL,
    appearance: PosterAppearance, expectedIdentity: String? = nil
  ) throws -> PosterAssignmentResult {
    try validatePosterTarget(name, in: directory)
    let image = try makePosterImage(from: imageData, appearance: appearance)
    let child = directory.appendingPathComponent(name, isDirectory: true)
    return try iconAssignmentLock.withLock { _ in
      let identity = try lockedIdentity(of: child, expected: expectedIdentity)
      if try suppressionExists(at: child, identity: identity)
        || !isOwnedIcon(at: child, identity: identity)
      {
        return .existingIconPreserved
      }
      try Task.checkCancellation()
      guard NSWorkspace.shared.setIcon(image, forFile: child.path, options: []) else {
        throw FolderPosterError.iconAssignmentFailed
      }
      recordOwnership(of: child, identity: identity, appearance: appearance)
      return .assigned
    }
  }

  /// Removes an app-owned icon and records suppression so automatic processing will not restore it.
  ///
  /// - Parameters:
  ///   - name: The immediate child folder name.
  ///   - directory: The authorized parent directory.
  ///   - expectedIdentity: Optional identity that the child must match.
  /// - Returns: `true` if an owned icon was removed, otherwise `false`.
  /// - Throws: ``FolderPosterError`` when validation or icon removal fails.
  public func removeAssignedPoster(
    toChild name: String, in directory: URL, expectedIdentity: String? = nil
  ) throws -> Bool {
    try validatePosterTarget(name, in: directory)
    let child = directory.appendingPathComponent(name, isDirectory: true)
    return try iconAssignmentLock.withLock { _ in
      let identity = try lockedIdentity(of: child, expected: expectedIdentity)
      guard isOwnedIcon(at: child, identity: identity) else { return false }
      try Task.checkCancellation()
      try markSuppressed(at: child, identity: identity)
      guard NSWorkspace.shared.setIcon(nil, forFile: child.path, options: []) else {
        throw FolderPosterError.iconAssignmentFailed
      }
      return true
    }
  }

  /// Checks whether automatic poster assignment was suppressed for this child.
  ///
  /// - Parameters:
  ///   - name: The immediate child folder name.
  ///   - directory: The authorized parent directory.
  /// - Returns: `true` when a suppression marker exists for the current child identity.
  /// - Throws: ``FolderPosterError`` when the child cannot be safely inspected.
  public func isPosterSuppressed(toChild name: String, in directory: URL) throws -> Bool {
    try validatePosterTarget(name, in: directory)
    let child = directory.appendingPathComponent(name, isDirectory: true)
    return try iconAssignmentLock.withLock { _ in
      let identity = try lockedIdentity(of: child, expected: nil)
      return try suppressionExists(at: child, identity: identity)
    }
  }

  /// Validates the parent directory and immediate child name before icon operations.
  private func validatePosterTarget(_ name: String, in directory: URL) throws {
    try validateDirectory(directory)
    guard isValidChildName(name) else { throw FolderPosterError.invalidChild }
  }

  /// Reads the current child identity and verifies any identity supplied by the caller.
  private func lockedIdentity(of child: URL, expected: String?) throws -> String {
    let identity: String
    do { identity = try fileIdentity(at: child) } catch { throw FolderPosterError.invalidChild }
    if let expected, expected != identity { throw FolderPosterError.invalidChild }
    return identity
  }

  /// Decodes poster bytes and produces the 512-point Finder icon image.
  private func makePosterImage(from data: Data, appearance: PosterAppearance) throws -> NSImage {
    let image = try PosterAppearanceRenderer.image(from: data, appearance: appearance)

    return NSImage(cgImage: image, size: NSSize(width: 512, height: 512))
  }

  /// Reads Finder's custom-icon flag without following a directory symlink.
  func hasCustomIcon(at directory: URL) throws -> Bool {
    var finderInfo = [UInt8](repeating: 0, count: 32)
    let count = directory.withUnsafeFileSystemRepresentation { path in
      guard let path else { return -1 }
      return getxattr(
        path, "com.apple.FinderInfo", &finderInfo, finderInfo.count, 0, XATTR_NOFOLLOW)
    }
    if count == -1 {
      let failure = errno
      if failure == ENOATTR { return false }
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure))
    }
    guard count == 32 else { throw CocoaError(.fileReadCorruptFile) }
    return finderInfo[8] & 0x04 != 0
  }

  /// Opens a bounded regular `Icon` file beneath the validated folder descriptor.
  private func iconDescriptor(in folder: URL, identity: String) -> Int32? {
    guard let folderFD = folderDescriptor(folder, identity: identity) else { return nil }
    defer { _ = close(folderFD) }
    let iconFD = iconFileName.withCString {
      openat(folderFD, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    }
    guard iconFD >= 0 else { return nil }
    var info = stat()
    guard fstat(iconFD, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
      info.st_size >= 0, info.st_size <= maximumIconBytes
    else {
      _ = close(iconFD)
      return nil
    }
    return iconFD
  }

  /// Reads an extended attribute only when its size is within the icon limit.
  private func readAttribute(_ name: String, from descriptor: Int32) -> Data? {
    let length = fgetxattr(descriptor, name, nil, 0, 0, 0)
    guard length >= 0, length <= maximumIconBytes else { return nil }
    var value = Data(count: length)
    let result = value.withUnsafeMutableBytes { bytes in
      fgetxattr(descriptor, name, bytes.baseAddress, length, 0, 0)
    }
    return result == length ? value : nil
  }

  /// Hashes the icon file and resource fork so external icon edits invalidate ownership.
  private func iconDigest(descriptor: Int32) -> String? {
    guard let resourceFork = readAttribute("com.apple.ResourceFork", from: descriptor) else {
      return nil
    }
    var contents = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = read(descriptor, &buffer, buffer.count)
      if count == 0 { break }
      if count < 0 {
        if errno == EINTR { continue }
        return nil
      }
      guard contents.count + count <= maximumIconBytes else { return nil }
      contents.append(contentsOf: buffer[0..<count])
    }
    var material = Data("Icon\r\0".utf8)
    material.append(contents)
    material.append(0)
    material.append(resourceFork)
    return SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
  }

  /// Returns whether ownership metadata still matches the current icon and folder identity.
  private func isOwnedIcon(at folder: URL, identity: String) -> Bool {
    assignedAppearance(at: folder, identity: identity) != nil
  }

  /// Reads ownership metadata only when it matches the current icon digest and folder identity.
  private func assignedAppearance(at folder: URL, identity: String) -> PosterAppearance? {
    guard (try? hasCustomIcon(at: folder)) == true else { return nil }
    guard let descriptor = iconDescriptor(in: folder, identity: identity) else { return nil }
    defer { _ = close(descriptor) }
    guard let marker = readAttribute(ownershipAttribute, from: descriptor),
      let ownership = try? JSONDecoder().decode(PosterOwnership.self, from: marker),
      ownership.identity == identity, let digest = iconDigest(descriptor: descriptor)
    else { return nil }
    return ownership.digest == digest ? ownership.appearance : nil
  }

  /// Records the identity and digest of the icon after Finder accepts the assignment.
  private func recordOwnership(of folder: URL, identity: String, appearance: PosterAppearance) {
    guard let descriptor = iconDescriptor(in: folder, identity: identity) else { return }
    defer { _ = close(descriptor) }
    guard let digest = iconDigest(descriptor: descriptor) else { return }
    guard
      let marker = try? JSONEncoder().encode(
        PosterOwnership(identity: identity, digest: digest, appearance: appearance)
      )
    else { return }
    _ = marker.withUnsafeBytes {
      fsetxattr(descriptor, ownershipAttribute, $0.baseAddress, $0.count, 0, 0)
    }
  }

  /// Opens the folder without following symlinks and optionally confirms its identity.
  private func folderDescriptor(_ folder: URL, identity: String? = nil) -> Int32? {
    let descriptor = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { return nil }
    if let identity {
      var info = stat()
      guard fstat(descriptor, &info) == 0, fileIdentity(info) == identity else {
        _ = close(descriptor)
        return nil
      }
    }
    return descriptor
  }

  /// Builds the volatile device, inode, and creation timestamp identity for a stat result.
  private func fileIdentity(_ info: stat) -> String {
    "\(info.st_dev):\(info.st_ino):\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec)"
  }

  /// Checks for a suppression marker on the folder matching the expected identity.
  private func suppressionExists(at folder: URL, identity: String) throws -> Bool {
    guard let descriptor = folderDescriptor(folder, identity: identity) else {
      throw FolderPosterError.invalidChild
    }
    defer { _ = close(descriptor) }
    let length = fgetxattr(descriptor, suppressionAttribute, nil, 0, 0, 0)
    if length < 0 {
      if errno == ENOATTR { return false }
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    return true
  }

  /// Writes a suppression marker so automatic assignment respects the user's removal.
  private func markSuppressed(at folder: URL, identity: String) throws {
    guard let descriptor = folderDescriptor(folder, identity: identity) else {
      throw FolderPosterError.invalidChild
    }
    defer { _ = close(descriptor) }
    let value = Data("1".utf8)
    let result = value.withUnsafeBytes {
      fsetxattr(descriptor, suppressionAttribute, $0.baseAddress, $0.count, 0, 0)
    }
    guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
  }

  /// Clears a suppression marker after a new poster has been assigned.
  private func clearSuppression(at folder: URL, identity: String) {
    guard let descriptor = folderDescriptor(folder, identity: identity) else { return }
    defer { _ = close(descriptor) }
    _ = fremovexattr(descriptor, suppressionAttribute, 0)
  }
}
