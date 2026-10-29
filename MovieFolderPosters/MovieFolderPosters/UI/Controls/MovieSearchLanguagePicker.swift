import AppKit
import Network

/// Native picker for recognized ISO language choices, retaining any valid saved regional choice.
@MainActor final class MovieSearchLanguagePicker: NSPopUpButton {
  /// Shared explanatory copy for all matching settings surfaces.
  static let supportingText = "Requests movie titles in this language. Original and alternative titles can still "
    + "identify a movie. Confirmed movie identities are preserved."
  /// Stable matching values corresponding to the native menu items.
  private var languages = [TMDbLanguage]()
  /// Selected validated language; no selection uses the application's established default.
  var selectedLanguage: TMDbLanguage {
    guard let index = itemArray.firstIndex(where: { $0 == selectedItem }), languages.indices.contains(index) else {
      return .english
    }

    return languages[index]
  }

  /// Creates a native keyboard and VoiceOver accessible language control.
  init() {
    super.init(frame: .zero, pullsDown: false)
    setAccessibilityLabel("Search language")
    setAccessibilityHelp(Self.supportingText)
    toolTip = Self.supportingText
    let identifiers = Locale.LanguageCode.isoLanguageCodes.map(\.identifier)
      + ["en-US", "en-GB", "pt-BR", "pt-PT", "es-ES", "es-MX", "fr-FR", "fr-CA", "de-DE", "zh-CN", "zh-TW"]
    languages = Array(Set(identifiers.compactMap { try? TMDbLanguage($0) })).sorted {
      Self.label(for: $0).localizedStandardCompare(Self.label(for: $1)) == .orderedAscending
    }
    rebuildMenu(selecting: .english)
  }

  /// Programmatic controls do not support archive construction.
  @available(*, unavailable)
  required init(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  /// Displays an effective saved language, inserting valid regional choices missing from the local catalog.
  /// - Parameter language: Captured effective matching language to display.
  func display(_ language: TMDbLanguage) {
    if !languages.contains(language) {
      languages.append(language)
      languages.sort { Self.label(for: $0).localizedStandardCompare(Self.label(for: $1)) == .orderedAscending }
      rebuildMenu(selecting: language)
    } else if let index = languages.firstIndex(of: language) {
      select(item(at: index))
    }
  }

  /// Rebuilds native items while preserving the validated selection by identity.
  private func rebuildMenu(selecting language: TMDbLanguage) {
    removeAllItems()
    addItems(withTitles: languages.map(Self.label(for:)))
    if let index = languages.firstIndex(of: language) { select(item(at: index)) }
  }

  /// Uses a localized language name with its ISO identifier to distinguish regional variants.
  static func label(for language: TMDbLanguage) -> String {
    let name = Locale.current.localizedString(forIdentifier: language.rawValue) ?? language.rawValue

    return "\(name) (\(language.rawValue))"
  }
}
