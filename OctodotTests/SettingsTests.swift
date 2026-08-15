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
        #expect(AppPreferences.AppearanceMode.system.windowAppearance == nil)
        #expect(AppPreferences.AppearanceMode.light.windowAppearance?.name == .aqua)
        #expect(AppPreferences.AppearanceMode.dark.windowAppearance?.name == .darkAqua)
    }

    @Test func preferencesMigrateLegacyShortcutValues() {
        let suiteName = "SettingsTests.defaults.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        userDefaults.set("controlOptionN", forKey: "AppPreferences.globalShortcut.v1")

        let preferences = AppPreferences(userDefaults: userDefaults)

        #expect(preferences.globalShortcut == .controlOptionN)
        #expect(userDefaults.string(forKey: "AppPreferences.globalShortcut.v2") == preferences.globalShortcut.storageValue)
        #expect(userDefaults.object(forKey: "AppPreferences.globalShortcut.v1") == nil)
    }

    @Test func shortcutValidityRequiresNonShiftModifier() {
        #expect(AppPreferences.GlobalShortcut(keyCode: 0, modifierFlags: [.command]).isValid)
        #expect(AppPreferences.GlobalShortcut(keyCode: 0, modifierFlags: [.control, .option]).isValid)
        #expect(AppPreferences.GlobalShortcut(keyCode: 0, modifierFlags: [.command, .shift]).isValid)
        #expect(AppPreferences.GlobalShortcut(keyCode: 0, modifierFlags: [.shift]).isValid == false)
        #expect(AppPreferences.GlobalShortcut(keyCode: 0, modifierFlags: []).isValid == false)
        #expect(AppPreferences.GlobalShortcut(keyCode: 128, modifierFlags: [.command]).isValid == false)
        #expect(AppPreferences.GlobalShortcut(keyCode: 0, modifierFlags: [.command, .capsLock]).isValid == false)
    }

    @Test func corruptCurrentShortcutDoesNotReviveStaleLegacyValue() {
        let suiteName = "SettingsTests.defaults.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        userDefaults.set("invalid", forKey: "AppPreferences.globalShortcut.v2")
        userDefaults.set("controlOptionN", forKey: "AppPreferences.globalShortcut.v1")

        let preferences = AppPreferences(userDefaults: userDefaults)

        #expect(preferences.globalShortcut == .commandQuote)
        #expect(userDefaults.string(forKey: "AppPreferences.globalShortcut.v2") == preferences.globalShortcut.storageValue)
    }

    @Test func invalidShortcutAssignmentPreservesLastValidPreference() {
        let suiteName = "SettingsTests.defaults.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppPreferences(userDefaults: userDefaults)

        preferences.globalShortcut = AppPreferences.GlobalShortcut(
            keyCode: 0,
            modifierFlags: [.shift]
        )

        #expect(preferences.globalShortcut == .commandQuote)
        #expect(preferences.globalShortcutErrorMessage != nil)
        #expect(userDefaults.string(forKey: "AppPreferences.globalShortcut.v2") == preferences.globalShortcut.storageValue)
    }

    @Test func preferencesRejectStoredShiftOnlyShortcut() {
        let suiteName = "SettingsTests.defaults.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let shortcut = AppPreferences.GlobalShortcut(keyCode: 0, modifierFlags: [.shift])
        userDefaults.set(shortcut.storageValue, forKey: "AppPreferences.globalShortcut.v2")

        let preferences = AppPreferences(userDefaults: userDefaults)

        #expect(preferences.globalShortcut == .commandQuote)
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

    @Test func launchAtLoginFailureIsActionableAndLeavesToggleOff() {
        struct TestError: LocalizedError {
            var errorDescription: String? { "Registration unavailable" }
        }

        let preferences = AppPreferences(
            userDefaults: AppStateTests.makeIsolatedUserDefaults(),
            launchAtLoginService: .init(
                isEnabled: { false },
                setEnabled: { _ in throw TestError() }
            )
        )

        preferences.launchAtLogin = true

        #expect(preferences.launchAtLogin == false)
        #expect(preferences.launchAtLoginErrorMessage?.contains("Registration unavailable") == true)
    }

    @Test func launchAtLoginApprovalRequirementIsSurfaced() {
        let preferences = AppPreferences(
            userDefaults: AppStateTests.makeIsolatedUserDefaults(),
            launchAtLoginService: .init(
                isEnabled: { false },
                setEnabled: { _ in }
            )
        )

        preferences.launchAtLogin = true

        #expect(preferences.launchAtLogin == false)
        #expect(preferences.launchAtLoginErrorMessage?.contains("System Settings") == true)
    }
}
