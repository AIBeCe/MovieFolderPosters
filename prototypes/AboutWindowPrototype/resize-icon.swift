import AppKit
import Foundation

/// Writes a square PNG size while retaining the source image's transparent corners.
func resizeIcon(sourcePath: String, destinationPath: String, size: Int) throws {
  guard let source = NSImage(contentsOfFile: sourcePath) else {
    throw CocoaError(.fileReadCorruptFile)
  }

  let dimensions = NSSize(width: size, height: size)
  guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: .none,
    pixelsWide: size,
    pixelsHigh: size,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: .zero,
    bitsPerPixel: .zero
  ) else {
    throw CocoaError(.fileWriteUnknown)
  }

  bitmap.size = dimensions
  NSGraphicsContext.saveGraphicsState()
  defer { NSGraphicsContext.restoreGraphicsState() }

  guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    throw CocoaError(.fileWriteUnknown)
  }
  NSGraphicsContext.current = context
  context.imageInterpolation = .high
  source.draw(
    in: NSRect(origin: .zero, size: dimensions),
    from: NSRect(origin: .zero, size: source.size),
    operation: .copy,
    fraction: 1
  )
  context.flushGraphics()

  guard let data = bitmap.representation(using: .png, properties: [:]) else {
    throw CocoaError(.fileWriteUnknown)
  }
  try data.write(to: URL(fileURLWithPath: destinationPath), options: .atomic)
}

let arguments = CommandLine.arguments
guard arguments.count == 4, let size = Int(arguments[3]) else {
  fatalError("Usage: resize-icon.swift SOURCE DESTINATION SIZE")
}
try resizeIcon(sourcePath: arguments[1], destinationPath: arguments[2], size: size)
