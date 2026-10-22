import AppKit

/// A standalone AppKit prototype for the product About window.
@MainActor
final class AboutPrototypeApplication: NSObject, NSApplicationDelegate {
  /// The window that displays the prototype About content.
  private var window: NSWindow?

  /// Opens the About window when the prototype launches.
  func applicationDidFinishLaunching(_ notification: Notification) {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 680, height: 470),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.title = "About Movie Folder Posters"
    window.center()
    window.isReleasedWhenClosed = false
    window.contentView = makeContentView()
    window.makeKeyAndOrderFront(nil)
    self.window = window

    NSApp.applicationIconImage = image(named: "MovieFolderPostersIcon.png")
    NSApp.activate(ignoringOtherApps: true)
  }

  /// Builds the product-first layout with compact secondary attribution.
  private func makeContentView() -> NSView {
    let root = NSView()
    root.translatesAutoresizingMaskIntoConstraints = false

    let hero = makeHero()
    let divider = NSBox()
    divider.boxType = .separator
    divider.translatesAutoresizingMaskIntoConstraints = false

    let attribution = makeAttribution()

    root.addSubview(hero)
    root.addSubview(divider)
    root.addSubview(attribution)

    NSLayoutConstraint.activate([
      hero.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 52),
      hero.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -52),
      hero.topAnchor.constraint(equalTo: root.topAnchor, constant: 54),
      hero.bottomAnchor.constraint(equalTo: divider.topAnchor, constant: -42),

      divider.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 38),
      divider.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -38),

      attribution.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 40),
      attribution.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -40),
      attribution.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 20),
      attribution.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
      attribution.heightAnchor.constraint(equalToConstant: 72)
    ])

    return root
  }

  /// Creates the dominant product mark, name, tagline, and version.
  private func makeHero() -> NSView {
    let container = NSStackView()
    container.orientation = .horizontal
    container.alignment = .centerY
    container.spacing = 30
    container.translatesAutoresizingMaskIntoConstraints = false

    let logoView = NSImageView()
    logoView.image = image(named: "MovieFolderPostersIcon.png")
    logoView.imageScaling = .scaleProportionallyUpOrDown
    logoView.wantsLayer = true
    logoView.layer?.cornerRadius = 22
    logoView.layer?.cornerCurve = .continuous
    logoView.layer?.masksToBounds = true
    logoView.translatesAutoresizingMaskIntoConstraints = false
    logoView.setContentHuggingPriority(.required, for: .horizontal)
    NSLayoutConstraint.activate([
      logoView.widthAnchor.constraint(equalToConstant: 154),
      logoView.heightAnchor.constraint(equalToConstant: 154)
    ])

    let title = label("Movie Folder Posters", size: 28, weight: .bold)
    title.maximumNumberOfLines = 2
    title.setContentCompressionResistancePriority(.required, for: .vertical)

    let tagline = label("Movie artwork, right where you browse.", size: 15, weight: .regular)
    tagline.textColor = .secondaryLabelColor

    let version = label("VERSION 1.0", size: 11, weight: .semibold)
    version.textColor = .secondaryLabelColor

    let copy = NSStackView(views: [title, tagline, version])
    copy.orientation = .vertical
    copy.alignment = .leading
    copy.spacing = 9
    copy.translatesAutoresizingMaskIntoConstraints = false

    container.addArrangedSubview(logoView)
    container.addArrangedSubview(copy)
    return container
  }

  /// Creates a subdued TMDb attribution footer and a native link button.
  private func makeAttribution() -> NSView {
    let container = NSStackView()
    container.orientation = .horizontal
    container.alignment = .centerY
    container.distribution = .fill
    container.spacing = 16
    container.translatesAutoresizingMaskIntoConstraints = false

    let logoView = NSImageView()
    logoView.image = image(named: "TMDbLogo.svg")
    logoView.imageScaling = .scaleProportionallyUpOrDown
    logoView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      logoView.widthAnchor.constraint(equalToConstant: 54),
      logoView.heightAnchor.constraint(equalToConstant: 36)
    ])
    logoView.setContentHuggingPriority(.required, for: .horizontal)
    logoView.setContentCompressionResistancePriority(.required, for: .horizontal)

    let notice = label(
      "This product uses the TMDB API but is not endorsed or certified by TMDB.",
      size: 11,
      weight: .regular
    )
    notice.textColor = .secondaryLabelColor
    notice.maximumNumberOfLines = 2
    notice.alignment = .left
    notice.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    notice.setContentHuggingPriority(.defaultLow, for: .horizontal)

    let visitButton = NSButton(title: "Visit TMDb", target: self, action: #selector(openTMDb))
    visitButton.bezelStyle = .rounded
    visitButton.controlSize = .small
    visitButton.setButtonType(.momentaryPushIn)
    visitButton.setContentHuggingPriority(.required, for: .horizontal)
    visitButton.setContentCompressionResistancePriority(.required, for: .horizontal)

    container.addArrangedSubview(logoView)
    container.addArrangedSubview(notice)
    container.addArrangedSubview(visitButton)
    return container
  }

  /// Creates a centered AppKit text label.
  private func label(_ text: String, size: CGFloat, weight: NSFont.Weight) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = .systemFont(ofSize: size, weight: weight)
    field.translatesAutoresizingMaskIntoConstraints = false
    return field
  }

  /// Loads a bundled prototype asset by its filename.
  private func image(named filename: String) -> NSImage? {
    guard let resourceURL = Bundle.main.resourceURL else { return nil }
    let assetURL = resourceURL
      .appendingPathComponent("Assets", isDirectory: true)
      .appendingPathComponent(filename)
    return NSImage(contentsOf: assetURL)
  }

  /// Opens the official TMDb website from the footer button.
  @objc private func openTMDb() {
    guard let url = URL(string: "https://www.themoviedb.org/") else { return }
    NSWorkspace.shared.open(url)
  }

}

@main
enum AboutWindowPrototype {
  @MainActor
  static func main() {
    let application = NSApplication.shared
    let delegate = AboutPrototypeApplication()
    application.setActivationPolicy(.regular)
    application.delegate = delegate
    application.run()
  }
}
