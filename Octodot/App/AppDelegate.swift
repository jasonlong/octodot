import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard Self.shouldLaunchUI(environment: ProcessInfo.processInfo.environment) else {
            return
        }

        let appState = AppState()
        statusItemController = StatusItemController(appState: appState)
    }

    static func shouldLaunchUI(environment: [String: String]) -> Bool {
        environment["XCTestConfigurationFilePath"] == nil
    }
}
