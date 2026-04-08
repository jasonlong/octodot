import SwiftUI

@main
struct OctodotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(appState: appDelegate.appState, preferences: appDelegate.preferences, updateChecker: appDelegate.updateChecker)
                .preferredColorScheme(appDelegate.preferences.appearanceMode.colorScheme)
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    appDelegate.showSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
