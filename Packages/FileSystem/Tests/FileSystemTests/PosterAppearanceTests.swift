import AppKit
import ImageIO
import Testing

@testable import FileSystem

@Suite(.serialized)
/// Exercises poster sizing, rendering treatments, and rejection of malformed image data.
struct PosterAppearanceTests {
  /// Service instance used to render test poster data.
  private let service = FileSystemService()

  /// Scenario: renderer produces transparent512 pixel bitmaps for every appearance.
  @Test func rendererProducesTransparent512PixelBitmapsForEveryAppearance() throws {
    let source = try makePoster()
    for appearance in PosterAppearance.allCases {
      let image = try #require(Raster(data: service.renderPoster(source, appearance: appearance)))
      #expect(image.width == 512)
      #expect(image.height == 512)
      #expect(image.pixel(x: 0, y: 0)[3] == 0)
      #expect(image.pixel(x: 256, y: 256)[3] > 240)
    }
  }

  /// Scenario: raw and soft finish keep portrait aspect ratio and inset.
  @Test func rawAndSoftFinishKeepPortraitAspectRatioAndInset() throws {
    let source = try makePoster()
    let raw = try #require(Raster(data: service.renderPoster(source, appearance: .raw)))
    let soft = try #require(Raster(data: service.renderPoster(source, appearance: .softFinish)))

    #expect(raw.pixel(x: 60, y: 256)[3] == 0)
    #expect(raw.pixel(x: 100, y: 256)[0] > 240)
    #expect(soft.pixel(x: 60, y: 256)[3] == 0)
    #expect(soft.pixel(x: 256, y: 30)[0] > 240)
    #expect(soft.pixel(x: 256, y: 256)[1] < 60)
    #expect(soft.pixel(x: 102, y: 24)[3] < 240)
    let rawContentWidth = (0..<raw.width).filter { raw.pixel(x: $0, y: 256)[0] > 200 }.count
    let softContentWidth = (0..<soft.width).filter { soft.pixel(x: $0, y: 256)[0] > 200 }.count
    #expect((338...344).contains(rawContentWidth))
    #expect((306...312).contains(softContentWidth))
  }

  /// Scenario: matte frame renders graphite border around undistorted poster.
  @Test func matteFrameRendersGraphiteBorderAroundUndistortedPoster() throws {
    let image = try #require(
      Raster(data: service.renderPoster(try makePoster(), appearance: .matteFrame)))
    let frame = image.pixel(x: 102, y: 256)
    let poster = image.pixel(x: 106, y: 256)

    #expect(frame[0] > 35 && frame[0] < 75)
    #expect(abs(Int(frame[0]) - Int(frame[1])) < 8)
    #expect(abs(Int(frame[1]) - Int(frame[2])) < 8)
    #expect(poster[0] > 240 && poster[1] < 60)
  }

  /// Scenario: renderer rejects malformed image data.
  @Test func rendererRejectsMalformedImageData() {
    #expect(throws: FolderPosterError.self) {
      try service.renderPoster(Data([0, 1, 2]), appearance: .softFinish)
    }
  }

  private func makePoster() throws -> Data {
    let context = try #require(
      CGContext(
        data: nil, width: 200, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(
      CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
  }
}

/// Decodes a bitmap into pixels for appearance assertions.
private struct Raster {
  /// Pixel width of the decoded bitmap.
  let width: Int
  /// Pixel height of the decoded bitmap.
  let height: Int
  /// Row-major RGBA pixel bytes.
  private let bytes: [UInt8]

  /// Creates a bitmap snapshot when Core Graphics can decode the supplied image.
  init?(data: Data) {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return nil }
    let imageWidth = image.width
    let imageHeight = image.height
    var storage = [UInt8](repeating: 0, count: imageWidth * imageHeight * 4)
    let rendered = storage.withUnsafeMutableBytes { bytes in
      guard
        let context = CGContext(
          data: bytes.baseAddress, width: imageWidth, height: imageHeight,
          bitsPerComponent: 8, bytesPerRow: imageWidth * 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
      return true
    }
    guard rendered else { return nil }
    width = imageWidth
    height = imageHeight
    bytes = storage
  }

  /// Returns the RGBA components at the requested coordinate.
  func pixel(x: Int, y: Int) -> [UInt8] {
    let offset = (y * width + x) * 4
    return Array(bytes[offset..<(offset + 4)])
  }
}
