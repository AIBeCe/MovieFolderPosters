import AppKit
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

// NSWorkspace.setIcon must be serialized, including callers outside the Finder processing actor.
private let iconAssignmentLock = Mutex<Void>(())

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
        _ imageData: Data, toChild name: String, in directory: URL
    ) throws -> PosterAssignmentResult {
        try Task.checkCancellation()
        try validateDirectory(directory)
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/") else { throw FolderPosterError.invalidChild }
        let children = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        guard let child = children.first(where: { $0.lastPathComponent == name }) else {
            throw FolderPosterError.invalidChild
        }
        try validateDirectory(child)
        return try iconAssignmentLock.withLock { _ in
            // Preserve every existing custom icon, regardless of who installed it.
            if try hasCustomIcon(at: child) { return .existingIconPreserved }
            let image = try makePosterImage(from: imageData)
            try Task.checkCancellation()
            guard NSWorkspace.shared.setIcon(image, forFile: child.path, options: []) else {
                throw FolderPosterError.iconAssignmentFailed
            }
            return .assigned
        }
    }

    private func makePosterImage(from data: Data) throws -> NSImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let poster = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 512
              ] as CFDictionary),
              let context = CGContext(data: nil, width: 512, height: 512, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw FolderPosterError.invalidImage
        }
        let bounds = try posterBounds(for: CGSize(width: poster.width, height: poster.height))
        context.interpolationQuality = .high
        context.draw(poster, in: bounds)
        guard let icon = context.makeImage() else { throw FolderPosterError.invalidImage }
        return NSImage(cgImage: icon, size: NSSize(width: 512, height: 512))
    }

    private func hasCustomIcon(at directory: URL) throws -> Bool {
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
        // Finder flags are a big-endian UInt16 at offset 8; kHasCustomIcon is 0x0400.
        return finderInfo[8] & 0x04 != 0
    }
}
