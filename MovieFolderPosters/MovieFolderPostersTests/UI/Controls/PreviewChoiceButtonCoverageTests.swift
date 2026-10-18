import AppKit
import FileSystem
import Testing

@testable import MovieFolderPosters

/// Covers selection presentation and rendered artwork for Settings preview choices.
@MainActor
struct PreviewChoiceButtonCoverageTests {
  /// Verifies that a preview button exposes its title, artwork, and selected border state.
  @Test func buttonReflectsSelectionInStateAndBorder() throws {
    let image = NSImage(size: NSSize(width: 24, height: 24))
    let button = PreviewChoiceButton(
      title: "Soft finish", image: image, target: nil, action: #selector(NSObject.description))

    #expect(button.title == "Soft finish")
    #expect(button.accessibilityLabel() == "Soft finish")
    #expect(button.image === image)
    #expect(button.imagePosition == .imageAbove)
    #expect(button.imageScaling == .scaleProportionallyDown)

    button.updateSelection(true)
    #expect(button.state == .on)
    #expect(button.layer?.borderWidth == 3)
    #expect(button.layer?.borderColor == NSColor.controlAccentColor.cgColor)

    button.updateSelection(false)
    #expect(button.state == .off)
    #expect(button.layer?.borderWidth == 0)
  }

  /// Verifies that each bundled poster finish produces a correctly sized preview image.
  @Test func posterArtworkRendersEverySupportedFinish() throws {
    for appearance in PosterAppearance.allCases {
      let image = try #require(SettingsPreviewArtwork.poster(appearance))
      #expect(image.size == NSSize(width: 164, height: 164))
      #expect(image.cgImage(forProposedRect: nil, context: nil, hints: nil) != nil)
    }
  }

  /// Verifies that each color appearance draws a nonempty preview at its documented size.
  @Test func colorAppearanceArtworkRendersForEveryChoice() {
    for appearance in AppColorAppearance.allCases {
      let image = SettingsPreviewArtwork.appearance(appearance)
      #expect(image.size == NSSize(width: 144, height: 94))
      #expect(image.cgImage(forProposedRect: nil, context: nil, hints: nil) != nil)
    }
  }
}
