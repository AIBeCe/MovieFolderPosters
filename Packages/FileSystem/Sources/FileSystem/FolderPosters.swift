import AppKit
import CryptoKit
import Darwin
import ImageIO
import Synchronization

public enum PosterAssignmentResult: Sendable {
    case assigned
    case existingIconPreserved
}

public enum FolderPosterError: Error {
    case invalidChild
    case invalidImage
    case iconAssignmentFailed
}

private let iconAssignmentLock = Mutex<Void>(())
private let ownershipAttribute = "com.moviefolderposters.ownership"
private let suppressionAttribute = "com.moviefolderposters.suppressed"
private let iconFileName = "Icon\r"
private let maximumIconBytes = 4 * 1024 * 1024

private struct PosterOwnership: Codable {
    let identity: String
    let digest: String
    let appearance: PosterAppearance

    init(identity: String, digest: String, appearance: PosterAppearance = .raw) {
        self.identity = identity
        self.digest = digest
        self.appearance = appearance
    }

    private enum CodingKeys: String, CodingKey { case identity, digest, appearance }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        identity = try values.decode(String.self, forKey: .identity)
        digest = try values.decode(String.self, forKey: .digest)
        appearance = try values.decodeIfPresent(PosterAppearance.self, forKey: .appearance) ?? .raw
    }
}

extension FileSystemService {
    public func posterBounds(for size: CGSize, in canvas: CGSize = CGSize(width: 512, height: 512)) throws -> CGRect {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              canvas.width.isFinite, canvas.height.isFinite, canvas.width > 0, canvas.height > 0 else {
            throw FolderPosterError.invalidImage
        }
        let scale = min(canvas.width / size.width, canvas.height / size.height)
        let width = size.width * scale
        let height = size.height * scale
        return CGRect(x: (canvas.width - width) / 2, y: (canvas.height - height) / 2, width: width, height: height)
    }

    public func assignPoster(
        _ imageData: Data, toChild name: String, in directory: URL, expectedIdentity: String? = nil
    ) throws -> PosterAssignmentResult {
        try assignPoster(imageData, toChild: name, in: directory, appearance: .raw,
                         expectedIdentity: expectedIdentity)
    }

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

    public func replaceAssignedPoster(
        _ imageData: Data, toChild name: String, in directory: URL, expectedIdentity: String? = nil
    ) throws -> PosterAssignmentResult {
        try replaceAssignedPoster(imageData, toChild: name, in: directory, appearance: .raw,
                                  expectedIdentity: expectedIdentity)
    }

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

    public func restyleAssignedPoster(
        _ imageData: Data, toChild name: String, in directory: URL,
        appearance: PosterAppearance, expectedIdentity: String? = nil
    ) throws -> PosterAssignmentResult {
        try validatePosterTarget(name, in: directory)
        let image = try makePosterImage(from: imageData, appearance: appearance)
        let child = directory.appendingPathComponent(name, isDirectory: true)
        return try iconAssignmentLock.withLock { _ in
            let identity = try lockedIdentity(of: child, expected: expectedIdentity)
            if try suppressionExists(at: child, identity: identity) || !isOwnedIcon(at: child, identity: identity) {
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

    public func isPosterSuppressed(toChild name: String, in directory: URL) throws -> Bool {
        try validatePosterTarget(name, in: directory)
        let child = directory.appendingPathComponent(name, isDirectory: true)
        return try iconAssignmentLock.withLock { _ in
            let identity = try lockedIdentity(of: child, expected: nil)
            return try suppressionExists(at: child, identity: identity)
        }
    }

    private func validatePosterTarget(_ name: String, in directory: URL) throws {
        try validateDirectory(directory)
        guard isValidChildName(name) else { throw FolderPosterError.invalidChild }
    }

    private func lockedIdentity(of child: URL, expected: String?) throws -> String {
        let identity: String
        do { identity = try fileIdentity(at: child) } catch { throw FolderPosterError.invalidChild }
        if let expected, expected != identity { throw FolderPosterError.invalidChild }
        return identity
    }

    private func makePosterImage(from data: Data, appearance: PosterAppearance) throws -> NSImage {
        let image = try PosterAppearanceRenderer.image(from: data, appearance: appearance)
        return NSImage(cgImage: image, size: NSSize(width: 512, height: 512))
    }

    func hasCustomIcon(at directory: URL) throws -> Bool {
        var finderInfo = [UInt8](repeating: 0, count: 32)
        let count = directory.withUnsafeFileSystemRepresentation { path in
            getxattr(path!, "com.apple.FinderInfo", &finderInfo, finderInfo.count, 0, XATTR_NOFOLLOW)
        }
        if count == -1 {
            let failure = errno
            if failure == ENOATTR { return false }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure))
        }
        guard count == 32 else { throw CocoaError(.fileReadCorruptFile) }
        return finderInfo[8] & 0x04 != 0
    }

    private func iconDescriptor(in folder: URL, identity: String) -> Int32? {
        guard let folderFD = folderDescriptor(folder, identity: identity) else { return nil }
        defer { _ = close(folderFD) }
        let iconFD = iconFileName.withCString {
            openat(folderFD, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard iconFD >= 0 else { return nil }
        var info = stat()
        guard fstat(iconFD, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, info.st_size <= maximumIconBytes else {
            _ = close(iconFD)
            return nil
        }
        return iconFD
    }

    private func readAttribute(_ name: String, from descriptor: Int32) -> Data? {
        let length = fgetxattr(descriptor, name, nil, 0, 0, 0)
        guard length >= 0, length <= maximumIconBytes else { return nil }
        var value = Data(count: length)
        let result = value.withUnsafeMutableBytes { bytes in
            fgetxattr(descriptor, name, bytes.baseAddress, length, 0, 0)
        }
        return result == length ? value : nil
    }

    private func iconDigest(descriptor: Int32) -> String? {
        guard let resourceFork = readAttribute("com.apple.ResourceFork", from: descriptor) else { return nil }
        var contents = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; return nil }
            guard contents.count + count <= maximumIconBytes else { return nil }
            contents.append(contentsOf: buffer[0..<count])
        }
        var material = Data("Icon\r\0".utf8)
        material.append(contents)
        material.append(0)
        material.append(resourceFork)
        return SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
    }

    private func isOwnedIcon(at folder: URL, identity: String) -> Bool {
        assignedAppearance(at: folder, identity: identity) != nil
    }

    private func assignedAppearance(at folder: URL, identity: String) -> PosterAppearance? {
        guard (try? hasCustomIcon(at: folder)) == true else { return nil }
        guard let descriptor = iconDescriptor(in: folder, identity: identity) else { return nil }
        defer { _ = close(descriptor) }
        guard let marker = readAttribute(ownershipAttribute, from: descriptor),
              let ownership = try? JSONDecoder().decode(PosterOwnership.self, from: marker),
              ownership.identity == identity, let digest = iconDigest(descriptor: descriptor) else { return nil }
        return ownership.digest == digest ? ownership.appearance : nil
    }

    private func recordOwnership(of folder: URL, identity: String, appearance: PosterAppearance) {
        guard let descriptor = iconDescriptor(in: folder, identity: identity) else { return }
        defer { _ = close(descriptor) }
        guard let digest = iconDigest(descriptor: descriptor) else { return }
        guard let marker = try? JSONEncoder().encode(
            PosterOwnership(identity: identity, digest: digest, appearance: appearance)
        ) else { return }
        _ = marker.withUnsafeBytes {
            fsetxattr(descriptor, ownershipAttribute, $0.baseAddress, $0.count, 0, 0)
        }
    }

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

    private func fileIdentity(_ info: stat) -> String {
        "\(info.st_dev):\(info.st_ino):\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec)"
    }

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

    private func clearSuppression(at folder: URL, identity: String) {
        guard let descriptor = folderDescriptor(folder, identity: identity) else { return }
        defer { _ = close(descriptor) }
        _ = fremovexattr(descriptor, suppressionAttribute, 0)
    }
}
