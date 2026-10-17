import AppKit
import Foundation

@MainActor
protocol AppAppearanceSettingsDelegate: AnyObject {
    func appAppearanceSettingsDidChange(_ settings: AppAppearanceSettings)
}

@MainActor
final class AppAppearanceSettings {
    private static let defaultsKey = "nativeAppColorAppearance"
    private let defaults: UserDefaults

    private(set) var choice: AppColorAppearance
    weak var delegate: (any AppAppearanceSettingsDelegate)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedValue = defaults.string(forKey: Self.defaultsKey)
        choice = storedValue.flatMap(AppColorAppearance.init(rawValue:)) ?? .system
    }

    func select(_ choice: AppColorAppearance) {
        guard choice != self.choice else { return }
        self.choice = choice
        defaults.set(choice.rawValue, forKey: Self.defaultsKey)
        delegate?.appAppearanceSettingsDidChange(self)
    }

    static func appearance(for choice: AppColorAppearance) -> NSAppearance? {
        switch choice {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

enum AppColorAppearance: String, CaseIterable {
    case system
    case light
    case dark
}
