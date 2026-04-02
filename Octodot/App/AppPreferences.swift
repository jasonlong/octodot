import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class AppPreferences {
    private static let appearanceModeStorageKey = "AppPreferences.appearanceMode.v1"
    private static let globalShortcutStorageKey = "AppPreferences.globalShortcut.v1"

    enum AppearanceMode: String, CaseIterable, Identifiable {
        case system
        case light
        case dark

        var id: String { rawValue }

        var title: String {
            switch self {
            case .system: "System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }

        var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }

    enum GlobalShortcut: String, CaseIterable, Identifiable {
        case commandQuote
        case controlOptionN

        var id: String { rawValue }

        var title: String {
            switch self {
            case .commandQuote: "Cmd+'"
            case .controlOptionN: "Ctrl+Option+N"
            }
        }

        var keyCode: UInt16 {
            switch self {
            case .commandQuote: 39
            case .controlOptionN: 45
            }
        }

        var modifierFlags: NSEvent.ModifierFlags {
            switch self {
            case .commandQuote: [.command]
            case .controlOptionN: [.control, .option]
            }
        }
    }

    private let userDefaults: UserDefaults

    var appearanceMode: AppearanceMode {
        didSet {
            guard appearanceMode != oldValue else { return }
            userDefaults.set(appearanceMode.rawValue, forKey: Self.appearanceModeStorageKey)
        }
    }

    var globalShortcut: GlobalShortcut {
        didSet {
            guard globalShortcut != oldValue else { return }
            userDefaults.set(globalShortcut.rawValue, forKey: Self.globalShortcutStorageKey)
        }
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.appearanceMode = Self.loadAppearanceMode(from: userDefaults)
        self.globalShortcut = Self.loadGlobalShortcut(from: userDefaults)
    }

    private static func loadAppearanceMode(from userDefaults: UserDefaults) -> AppearanceMode {
        guard let rawValue = userDefaults.string(forKey: appearanceModeStorageKey),
              let mode = AppearanceMode(rawValue: rawValue) else {
            return .system
        }
        return mode
    }

    private static func loadGlobalShortcut(from userDefaults: UserDefaults) -> GlobalShortcut {
        guard let rawValue = userDefaults.string(forKey: globalShortcutStorageKey),
              let shortcut = GlobalShortcut(rawValue: rawValue) else {
            return .commandQuote
        }
        return shortcut
    }
}
