import AppKit
import FileSystem

@MainActor
final class PreviewChoiceButton: NSButton {
    init(title: String, image: NSImage, target: AnyObject?, action: Selector) {
        super.init(frame: .zero)
        self.title = title
        self.image = image
        self.target = target
        self.action = action
        imagePosition = .imageAbove
        imageScaling = .scaleProportionallyDown
        setButtonType(.pushOnPushOff)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 8
        font = .systemFont(ofSize: 13, weight: .medium)
        focusRingType = .exterior
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func updateSelection(_ selected: Bool) {
        state = selected ? .on : .off
        layer?.borderWidth = selected ? 3 : 0
        layer?.borderColor = NSColor.controlAccentColor.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSelection(state == .on)
    }
}

@MainActor
enum SettingsPreviewArtwork {
    static func poster(_ appearance: PosterAppearance) -> NSImage? {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: PreviewChoiceButton.self)
        #endif
        guard let url = bundle.url(forResource: "PreviewPoster", withExtension: "png"),
              let data = try? Data(contentsOf: url),
              let rendered = try? FileSystemService().renderPoster(data, appearance: appearance),
              let image = NSImage(data: rendered) else { return nil }
        image.size = NSSize(width: 164, height: 164)
        return image
    }

    static func appearance(_ appearance: AppColorAppearance) -> NSImage {
        NSImage(size: NSSize(width: 144, height: 94), flipped: false) { bounds in
            let rounded = NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 4), xRadius: 7, yRadius: 7)
            rounded.addClip()
            switch appearance {
            case .system:
                drawDesktop(in: bounds, dark: false)
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: NSRect(x: 72, y: 0, width: 72, height: 94)).addClip()
                drawDesktop(in: bounds, dark: true)
                NSGraphicsContext.restoreGraphicsState()
            case .light: drawDesktop(in: bounds, dark: false)
            case .dark: drawDesktop(in: bounds, dark: true)
            }
            return true
        }
    }

    private static func drawDesktop(in bounds: NSRect, dark: Bool) {
        let top = dark ? NSColor(red: 0.18, green: 0.14, blue: 0.39, alpha: 1)
            : NSColor(red: 0.38, green: 0.74, blue: 0.88, alpha: 1)
        let bottom = dark ? NSColor(red: 0.04, green: 0.12, blue: 0.24, alpha: 1)
            : NSColor(red: 0.80, green: 0.90, blue: 0.96, alpha: 1)
        NSGradient(starting: bottom, ending: top)?.draw(in: bounds, angle: 55)
        let window = NSRect(x: 21, y: 14, width: 108, height: 61)
        let background = dark ? NSColor(white: 0.14, alpha: 1) : NSColor(white: 0.98, alpha: 1)
        background.setFill()
        NSBezierPath(roundedRect: window, xRadius: 5, yRadius: 5).fill()
        (dark ? NSColor(white: 0.22, alpha: 1) : NSColor(white: 0.89, alpha: 1)).setFill()
        NSBezierPath(rect: NSRect(x: 22, y: 15, width: 26, height: 59)).fill()
        NSColor.systemBlue.setFill()
        NSBezierPath(roundedRect: NSRect(x: 24, y: 47, width: 22, height: 8), xRadius: 2, yRadius: 2).fill()
        for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: 28 + index * 9, y: 64, width: 5, height: 5)).fill()
        }
        (dark ? NSColor(white: 0.40, alpha: 1) : NSColor(white: 0.77, alpha: 1)).setFill()
        for y in [48, 37, 26] {
            NSBezierPath(roundedRect: NSRect(x: 56, y: y, width: 61, height: 4), xRadius: 2, yRadius: 2).fill()
        }
    }
}
