import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let preferences = AppPreferences()
    let appState = AppState()
    lazy var settingsWindowController = SettingsWindowController(
        appState: appState,
        preferences: preferences
    )
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard Self.shouldLaunchUI(environment: ProcessInfo.processInfo.environment) else {
            return
        }

        DebugTrace.reset()
        DebugTrace.log("app launch")
        statusItemController = StatusItemController(
            appState: appState,
            preferences: preferences,
            settingsWindowController: settingsWindowController
        )
    }

    func showSettings() {
        settingsWindowController.show()
    }

    static func shouldLaunchUI(environment: [String: String]) -> Bool {
        environment["XCTestConfigurationFilePath"] == nil
    }
}
