import AppKit
import Foundation
import ImageIO

public enum PosterAppearance: String, Codable, Sendable, CaseIterable {
    case raw
    case softFinish
    case matteFrame
}

extension FileSystemService {
    public func renderPoster(_ data: Data, appearance: PosterAppearance) throws -> Data {
        let image = try PosterAppearanceRenderer.image(from: data, appearance: appearance)
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else {
            throw FolderPosterError.invalidImage
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw FolderPosterError.invalidImage }
        return output as Data
    }
}

enum PosterAppearanceRenderer {
    static func image(from data: Data, appearance: PosterAppearance) throws -> CGImage {
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

        context.interpolationQuality = .high
        let size = CGSize(width: poster.width, height: poster.height)
        switch appearance {
        case .raw:
            let bounds = try posterBounds(for: size, canvas: CGSize(width: 512, height: 512))
            context.draw(poster, in: bounds)
        case .softFinish:
            let bounds = try posterBounds(for: size, canvas: CGSize(width: 464, height: 464))
                .offsetBy(dx: 24, dy: 24)
            drawRoundedPoster(poster, in: bounds, radius: 14, on: context)
            strokeRounded(bounds, radius: 14, width: 1, color: CGColor(gray: 1, alpha: 0.18), on: context)
        case .matteFrame:
            let bounds = try posterBounds(for: size, canvas: CGSize(width: 454, height: 454))
                .offsetBy(dx: 29, dy: 29)
            drawMattePoster(poster, in: bounds, on: context)
        }

        guard let rendered = context.makeImage() else { throw FolderPosterError.invalidImage }
        return rendered
    }

    private static func posterBounds(for size: CGSize, canvas: CGSize) throws -> CGRect {
        guard size.width > 0, size.height > 0 else { throw FolderPosterError.invalidImage }
        let scale = min(canvas.width / size.width, canvas.height / size.height)
        let width = size.width * scale
        let height = size.height * scale
        return CGRect(x: (canvas.width - width) / 2, y: (canvas.height - height) / 2,
                      width: width, height: height)
    }

    private static func roundedPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
        CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    private static func drawRoundedPoster(_ poster: CGImage, in bounds: CGRect, radius: CGFloat,
                                          on context: CGContext) {
        let path = roundedPath(bounds, radius: radius)
        addShadow(for: path, on: context)
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.draw(poster, in: bounds)
        context.restoreGState()
    }

    private static func drawMattePoster(_ poster: CGImage, in bounds: CGRect, on context: CGContext) {
        let outer = bounds.insetBy(dx: -5, dy: -5)
        let outerPath = roundedPath(outer, radius: 18)
        addShadow(for: outerPath, on: context)
        context.addPath(outerPath)
        context.setFillColor(CGColor(red: 0x35 / 255, green: 0x38 / 255, blue: 0x3C / 255, alpha: 1))
        context.fillPath()
        strokeRounded(outer, radius: 18, width: 1.5, color: CGColor(gray: 1, alpha: 0.28), on: context)

        let innerPath = roundedPath(bounds, radius: 13)
        context.saveGState()
        context.addPath(innerPath)
        context.clip()
        context.draw(poster, in: bounds)
        context.restoreGState()
        strokeRounded(bounds, radius: 13, width: 1, color: CGColor(gray: 0, alpha: 0.20), on: context)
    }

    private static func addShadow(for path: CGPath, on context: CGContext) {
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -6), blur: 12, color: CGColor(gray: 0, alpha: 0.22))
        context.addPath(path)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fillPath()
        context.restoreGState()
    }

    private static func strokeRounded(_ rect: CGRect, radius: CGFloat, width: CGFloat,
                                      color: CGColor, on context: CGContext) {
        context.saveGState()
        context.addPath(roundedPath(rect.insetBy(dx: width / 2, dy: width / 2), radius: radius))
        context.setLineWidth(width)
        context.setStrokeColor(color)
        context.strokePath()
        context.restoreGState()
    }
}
