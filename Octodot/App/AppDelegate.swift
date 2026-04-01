import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let appState = AppState()
        statusItemController = StatusItemController(appState: appState)
    }
}
