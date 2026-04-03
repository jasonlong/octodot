import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    private let appState: AppState
    private let preferences: AppPreferences
    private let settingsViewState: SettingsViewState

    init(appState: AppState, preferences: AppPreferences, settingsViewState: SettingsViewState) {
        self.appState = appState
        self.preferences = preferences
        self.settingsViewState = settingsViewState

        super.init(window: nil)
        self.window = Self.makeWindow(
            appState: appState,
            preferences: preferences,
            settingsViewState: settingsViewState
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func updateAppearance() {
        guard let existingWindow = window else {
            return
        }
        let frame = existingWindow.frame
        let wasVisible = existingWindow.isVisible

        let newWindow = Self.makeWindow(
            appState: appState,
            preferences: preferences,
            settingsViewState: settingsViewState
        )
        newWindow.setFrame(frame, display: false)
        window = newWindow

        existingWindow.orderOut(nil)
        if wasVisible {
            show()
        }
    }

    private static func makeWindow(
        appState: AppState,
        preferences: AppPreferences,
        settingsViewState: SettingsViewState
    ) -> NSWindow {
        let hostingController = makeHostingController(
            appState: appState,
            preferences: preferences,
            settingsViewState: settingsViewState
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

    private static func makeHostingController(
        appState: AppState,
        preferences: AppPreferences,
        settingsViewState: SettingsViewState
    ) -> NSHostingController<AnyView> {
        let rootView = AnyView(
            SettingsView(
                appState: appState,
                preferences: preferences,
                selection: Binding(
                    get: { settingsViewState.selectedTab },
                    set: { settingsViewState.selectedTab = $0 }
                )
            )
        )
        return NSHostingController(rootView: rootView)
    }
}
