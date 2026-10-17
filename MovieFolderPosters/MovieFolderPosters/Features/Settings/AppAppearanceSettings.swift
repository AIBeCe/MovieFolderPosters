import AppKit
import Foundation

/// Persists the app's color appearance choice and notifies its window owner.
@MainActor
protocol AppAppearanceSettingsDelegate: AnyObject {
  /// Reports that the selected appearance changed.
  ///
  /// - Parameter settings: The settings object containing the new choice.
  func appAppearanceSettingsDidChange(_ settings: AppAppearanceSettings)
}

/// Stores the selected app appearance independently from poster appearance settings.
@MainActor
final class AppAppearanceSettings {
  /// The UserDefaults key that stores the raw appearance choice.
  private static let defaultsKey = "nativeAppColorAppearance"
  /// The defaults store used to persist appearance selection.
  private let defaults: UserDefaults

  /// The current color appearance choice.
  private(set) var choice: AppColorAppearance
  /// Receives changes after a new choice has been persisted.
  weak var delegate: (any AppAppearanceSettingsDelegate)?

  /// Loads the saved choice, falling back to the system appearance.
  ///
  /// - Parameter defaults: The defaults store to read and write.
  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    let storedValue = defaults.string(forKey: Self.defaultsKey)
    choice = storedValue.flatMap(AppColorAppearance.init(rawValue:)) ?? .system
  }

  /// Persists a changed appearance choice and notifies the delegate.
  ///
  /// - Parameter choice: The appearance to use for host app windows.
  func select(_ choice: AppColorAppearance) {
    guard choice != self.choice else { return }
    self.choice = choice
    defaults.set(choice.rawValue, forKey: Self.defaultsKey)
    delegate?.appAppearanceSettingsDidChange(self)
  }

  /// Resolves a stored choice to the corresponding AppKit appearance.
  ///
  /// - Parameter choice: The selected appearance mode.
  /// - Returns: An explicit light or dark appearance, or `nil` for system behavior.
  static func appearance(for choice: AppColorAppearance) -> NSAppearance? {
    switch choice {
    case .system: nil
    case .light: NSAppearance(named: .aqua)
    case .dark: NSAppearance(named: .darkAqua)
    }
  }
}

/// Supported color appearance modes for the host application.
enum AppColorAppearance: String, CaseIterable {
  /// Follows the current macOS appearance.
  case system
  /// Forces a light appearance.
  case light
  /// Forces a dark appearance.
  case dark
}
