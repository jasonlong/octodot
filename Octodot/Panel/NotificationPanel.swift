import AppKit
import SwiftUI

final class NotificationPanel: NSPanel {
    private let appState: AppState

    init(appState: AppState, preferences: AppPreferences) {
        self.appState = appState

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 500),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .statusBar
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        let rootView = PanelRootView(
            appState: appState,
            preferences: preferences,
            closePanel: { [weak self] in
                self?.close()
            }
        )

        contentView = NSHostingView(rootView: rootView)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        if appState.isSearchActive {
            appState.deactivateSearch()
        } else {
            close()
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape key
            cancelOperation(nil)
        } else {
            super.keyDown(with: event)
        }
    }

    override func close() {
        super.close()
        appState.isPanelVisible = false
    }
}

private struct PanelRootView: View {
    @Bindable var appState: AppState
    @Bindable var preferences: AppPreferences
    let closePanel: () -> Void

    var body: some View {
        PanelContentView(appState: appState, closePanel: closePanel)
            .preferredColorScheme(preferences.appearanceMode.resolvedColorScheme)
    }
}
