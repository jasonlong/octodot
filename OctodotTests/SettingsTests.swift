import AppKit
import SwiftUI
import Testing
@testable import Octodot

@MainActor
struct SettingsTests {
    @Test func preferencesDefaultToSystemAppearanceAndCommandQuoteShortcut() {
        let suiteName = "SettingsTests.defaults.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(userDefaults: userDefaults)

        #expect(preferences.appearanceMode == .system)
        #expect(preferences.globalShortcut == .commandQuote)
    }

    @Test func preferencesPersistAppearanceAndShortcutChoices() {
        let suiteName = "SettingsTests.defaults.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(userDefaults: userDefaults)
        preferences.appearanceMode = .dark
        preferences.globalShortcut = .controlOptionN

        let reloaded = AppPreferences(userDefaults: userDefaults)

        #expect(reloaded.appearanceMode == .dark)
        #expect(reloaded.globalShortcut == .controlOptionN)
    }

    @Test func appearanceModeMapsToExpectedColorScheme() {
        #expect(AppPreferences.AppearanceMode.system.colorScheme == nil)
        #expect(AppPreferences.AppearanceMode.light.colorScheme == .light)
        #expect(AppPreferences.AppearanceMode.dark.colorScheme == .dark)
    }

    @Test func statusItemMatchesConfiguredGlobalShortcut() {
        #expect(StatusItemController.matchesToggleHotkey(
            keyCode: AppPreferences.GlobalShortcut.commandQuote.keyCode,
            modifierFlags: [.command],
            shortcut: .commandQuote
        ))

        #expect(StatusItemController.matchesToggleHotkey(
            keyCode: AppPreferences.GlobalShortcut.controlOptionN.keyCode,
            modifierFlags: [.control, .option],
            shortcut: .controlOptionN
        ))

        #expect(StatusItemController.matchesToggleHotkey(
            keyCode: AppPreferences.GlobalShortcut.commandQuote.keyCode,
            modifierFlags: [.command, .shift],
            shortcut: .commandQuote
        ) == false)
    }
}
