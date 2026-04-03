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
        preferences.globalShortcut = AppPreferences.GlobalShortcut(
            keyCode: 17,
            modifierFlags: [.command, .shift]
        )

        let reloaded = AppPreferences(userDefaults: userDefaults)

        #expect(reloaded.appearanceMode == .dark)
        #expect(reloaded.globalShortcut == AppPreferences.GlobalShortcut(
            keyCode: 17,
            modifierFlags: [.command, .shift]
        ))
    }

    @Test func appearanceModeMapsToExpectedColorScheme() {
        #expect(AppPreferences.AppearanceMode.system.colorScheme == nil)
        #expect(AppPreferences.AppearanceMode.light.colorScheme == .light)
        #expect(AppPreferences.AppearanceMode.dark.colorScheme == .dark)
    }

    @Test func appearanceModeMapsToExpectedWindowAppearance() {
        #expect(AppPreferences.AppearanceMode.system.resolvedWindowAppearance.name == .aqua || AppPreferences.AppearanceMode.system.resolvedWindowAppearance.name == .darkAqua)
        #expect(AppPreferences.AppearanceMode.light.resolvedWindowAppearance.name == .aqua)
        #expect(AppPreferences.AppearanceMode.dark.resolvedWindowAppearance.name == .darkAqua)
    }

    @Test func appearanceModeMapsToExpectedResolvedColorScheme() {
        #expect(AppPreferences.AppearanceMode.system.resolvedColorScheme == .light || AppPreferences.AppearanceMode.system.resolvedColorScheme == .dark)
        #expect(AppPreferences.AppearanceMode.light.resolvedColorScheme == .light)
        #expect(AppPreferences.AppearanceMode.dark.resolvedColorScheme == .dark)
    }

    @Test func preferencesMigrateLegacyShortcutValues() {
        let suiteName = "SettingsTests.defaults.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        userDefaults.set("controlOptionN", forKey: "AppPreferences.globalShortcut.v1")

        let preferences = AppPreferences(userDefaults: userDefaults)

        #expect(preferences.globalShortcut == .controlOptionN)
    }

    @Test func shortcutDisplayTextUsesSymbols() {
        let shortcut = AppPreferences.GlobalShortcut(keyCode: 17, modifierFlags: [.command, .shift])

        #expect(shortcut.displayText == "⇧⌘T")
        #expect(AppPreferences.GlobalShortcut.commandQuote.displayText == "⌘'")
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
