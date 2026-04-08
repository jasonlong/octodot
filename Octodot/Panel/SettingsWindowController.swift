import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    private let appState: AppState
    private let preferences: AppPreferences
    private let updateChecker: UpdateChecker
    private let hostingController: NSHostingController<AnyView>

    init(appState: AppState, preferences: AppPreferences, updateChecker: UpdateChecker) {
        self.appState = appState
        self.preferences = preferences
        self.updateChecker = updateChecker
        self.hostingController = NSHostingController(
            rootView: Self.makeRootView(appState: appState, preferences: preferences, updateChecker: updateChecker)
        )

        super.init(window: nil)
        self.window = Self.makeWindow(contentViewController: hostingController, preferences: preferences)
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
        guard let window else {
            return
        }
        hostingController.rootView = Self.makeRootView(appState: appState, preferences: preferences, updateChecker: updateChecker)
        window.appearance = preferences.appearanceMode.windowAppearance
        window.invalidateShadow()
        window.displayIfNeeded()
    }

    private static func makeWindow(contentViewController: NSViewController, preferences: AppPreferences) -> NSWindow {
        let window = NSWindow(contentViewController: contentViewController)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .preference
        window.isMovableByWindowBackground = true
        window.tabbingMode = .disallowed
        window.setContentSize(NSSize(width: 600, height: 560))
        window.center()
        window.isReleasedWhenClosed = false
        window.appearance = preferences.appearanceMode.windowAppearance
        return window
    }

    private static func makeRootView(appState: AppState, preferences: AppPreferences, updateChecker: UpdateChecker) -> AnyView {
        AnyView(
            SettingsView(appState: appState, preferences: preferences, updateChecker: updateChecker)
                .preferredColorScheme(preferences.appearanceMode.colorScheme)
        )
    }
}
