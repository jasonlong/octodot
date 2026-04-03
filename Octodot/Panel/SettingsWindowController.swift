import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    private let appState: AppState
    private let preferences: AppPreferences

    init(appState: AppState, preferences: AppPreferences) {
        self.appState = appState
        self.preferences = preferences

        super.init(window: nil)
        self.window = Self.makeWindow(appState: appState, preferences: preferences)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window else { return }
        DebugTrace.log("settings window show visible=\(window.isVisible) key=\(window.isKeyWindow)")
        window.orderFrontRegardless()
        window.makeKey()
        NSApp.activate(ignoringOtherApps: true)
        DebugTrace.log("settings window shown visible=\(window.isVisible) key=\(window.isKeyWindow)")
    }

    func updateAppearance() {
        guard let existingWindow = window else {
            return
        }

        let frame = existingWindow.frame
        let wasVisible = existingWindow.isVisible
        let newWindow = Self.makeWindow(appState: appState, preferences: preferences)
        newWindow.setFrame(frame, display: false)
        window = newWindow

        existingWindow.orderOut(nil)
        if wasVisible {
            show()
        }
    }

    private static func makeWindow(appState: AppState, preferences: AppPreferences) -> NSWindow {
        let hostingController = NSHostingController(
            rootView: SettingsView(appState: appState, preferences: preferences)
                .preferredColorScheme(preferences.appearanceMode.resolvedColorScheme)
        )

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .preference
        window.isMovableByWindowBackground = true
        window.tabbingMode = .disallowed
        window.setContentSize(NSSize(width: 540, height: 390))
        window.center()
        window.isReleasedWhenClosed = false
        window.appearance = preferences.appearanceMode.resolvedWindowAppearance
        return window
    }
}
