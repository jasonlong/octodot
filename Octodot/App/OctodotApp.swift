import SwiftUI

@main
struct OctodotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(appState: appDelegate.appState, preferences: appDelegate.preferences)
        }
    }
}
