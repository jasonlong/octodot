import AppKit
import Observation
import ServiceManagement
import SwiftUI

@MainActor
@Observable
final class AppPreferences {
    private static let appearanceModeStorageKey = "AppPreferences.appearanceMode.v1"
    private static let globalShortcutStorageKey = "AppPreferences.globalShortcut.v2"
    private static let legacyGlobalShortcutStorageKey = "AppPreferences.globalShortcut.v1"

    struct LaunchAtLoginService {
        let isEnabled: () -> Bool
        let setEnabled: (Bool) throws -> Void

        @MainActor static let mainApp = LaunchAtLoginService(
            isEnabled: { SMAppService.mainApp.status == .enabled },
            setEnabled: { enabled in
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            }
        )
    }

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

        var windowAppearance: NSAppearance? {
            switch self {
            case .system:
                nil
            case .light:
                NSAppearance(named: .aqua)
            case .dark:
                NSAppearance(named: .darkAqua)
            }
        }
    }

    struct GlobalShortcut: Equatable, Identifiable {
        let keyCode: UInt16
        let modifierFlags: NSEvent.ModifierFlags

        var id: String { storageValue }

        var displayText: String {
            let modifierText = Self.modifierDisplayText(for: modifierFlags)
            let keyText = Self.keyDisplayText(for: keyCode)
            return modifierText + keyText
        }

        var storageValue: String {
            "\(keyCode):\(modifierFlags.rawValue)"
        }

        var isValid: Bool {
            let allowedModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
            return keyCode <= 127
                && modifierFlags.subtracting(allowedModifiers).isEmpty
                && !modifierFlags.intersection([.command, .option, .control]).isEmpty
        }

        static let commandQuote = GlobalShortcut(keyCode: 39, modifierFlags: [.command])
        static let controlOptionN = GlobalShortcut(keyCode: 45, modifierFlags: [.control, .option])

        static func from(storageValue: String) -> GlobalShortcut? {
            let parts = storageValue.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  let keyCode = UInt16(parts[0]),
                  let rawFlags = UInt(parts[1]) else {
                return nil
            }

            let shortcut = GlobalShortcut(
                keyCode: keyCode,
                modifierFlags: NSEvent.ModifierFlags(rawValue: rawFlags)
            )
            return shortcut.isValid ? shortcut : nil
        }

        private static func modifierDisplayText(for modifierFlags: NSEvent.ModifierFlags) -> String {
            var text = ""
            if modifierFlags.contains(.control) {
                text += "⌃"
            }
            if modifierFlags.contains(.option) {
                text += "⌥"
            }
            if modifierFlags.contains(.shift) {
                text += "⇧"
            }
            if modifierFlags.contains(.command) {
                text += "⌘"
            }
            return text
        }

        private static func keyDisplayText(for keyCode: UInt16) -> String {
            if let specialKey = specialKeyLabels[keyCode] {
                return specialKey
            }

            if let character = printableKeyLabels[keyCode] {
                return character
            }

            return "Key \(keyCode)"
        }

        private static let specialKeyLabels: [UInt16: String] = [
            36: "↩",
            48: "⇥",
            49: "Space",
            51: "⌫",
            53: "⎋",
            123: "←",
            124: "→",
            125: "↓",
            126: "↑",
        ]

        private static let printableKeyLabels: [UInt16: String] = [
            0: "A",
            1: "S",
            2: "D",
            3: "F",
            4: "H",
            5: "G",
            6: "Z",
            7: "X",
            8: "C",
            9: "V",
            11: "B",
            12: "Q",
            13: "W",
            14: "E",
            15: "R",
            16: "Y",
            17: "T",
            18: "1",
            19: "2",
            20: "3",
            21: "4",
            22: "6",
            23: "5",
            24: "=",
            25: "9",
            26: "7",
            27: "-",
            28: "8",
            29: "0",
            30: "]",
            31: "O",
            32: "U",
            33: "[",
            34: "I",
            35: "P",
            37: "L",
            38: "J",
            39: "'",
            40: "K",
            41: ";",
            42: "\\",
            43: ",",
            44: "/",
            45: "N",
            46: "M",
            47: ".",
            50: "`",
        ]
    }

    private let userDefaults: UserDefaults
    @ObservationIgnored private let launchAtLoginService: LaunchAtLoginService

    var appearanceMode: AppearanceMode {
        didSet {
            guard appearanceMode != oldValue else { return }
            userDefaults.set(appearanceMode.rawValue, forKey: Self.appearanceModeStorageKey)
        }
    }

    var globalShortcut: GlobalShortcut {
        didSet {
            guard globalShortcut != oldValue else { return }
            guard globalShortcut.isValid else {
                globalShortcut = oldValue
                globalShortcutErrorMessage = "Choose a valid key with Command, Option, or Control"
                return
            }
            globalShortcutErrorMessage = nil
            userDefaults.set(globalShortcut.storageValue, forKey: Self.globalShortcutStorageKey)
        }
    }

    var globalShortcutErrorMessage: String?
    var launchAtLoginErrorMessage: String?

    var launchAtLogin: Bool {
        get { launchAtLoginService.isEnabled() }
        set {
            do {
                try launchAtLoginService.setEnabled(newValue)
                if newValue, !launchAtLoginService.isEnabled() {
                    launchAtLoginErrorMessage = "Allow Octodot in System Settings › General › Login Items to launch it automatically."
                } else if !newValue, launchAtLoginService.isEnabled() {
                    launchAtLoginErrorMessage = "Octodot couldn't turn off Launch at Login. Try again from System Settings › General › Login Items."
                } else {
                    launchAtLoginErrorMessage = nil
                }
            } catch {
                launchAtLoginErrorMessage = "Octodot couldn't update Launch at Login: \(error.localizedDescription)"
                DebugTrace.log("launch at login failed: \(error.localizedDescription)")
            }
        }
    }

    init(
        userDefaults: UserDefaults = .standard,
        launchAtLoginService: LaunchAtLoginService = .mainApp
    ) {
        self.userDefaults = userDefaults
        self.launchAtLoginService = launchAtLoginService
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
        if let storedValue = userDefaults.string(forKey: globalShortcutStorageKey) {
            guard let shortcut = GlobalShortcut.from(storageValue: storedValue) else {
                userDefaults.set(GlobalShortcut.commandQuote.storageValue, forKey: globalShortcutStorageKey)
                return .commandQuote
            }
            return shortcut
        }

        guard let legacyRawValue = userDefaults.string(forKey: legacyGlobalShortcutStorageKey) else {
            return .commandQuote
        }

        let shortcut: GlobalShortcut
        switch legacyRawValue {
        case "commandQuote":
            shortcut = .commandQuote
        case "controlOptionN":
            shortcut = .controlOptionN
        default:
            shortcut = .commandQuote
        }
        userDefaults.set(shortcut.storageValue, forKey: globalShortcutStorageKey)
        userDefaults.removeObject(forKey: legacyGlobalShortcutStorageKey)
        return shortcut
    }
}
