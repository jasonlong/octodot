import AppKit
import SwiftUI

final class StatusItemController {
    private let statusItem: NSStatusItem
    private let panel: NotificationPanel
    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.panel = NotificationPanel(appState: appState)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "bell.fill", accessibilityDescription: "Octodot")
            button.image?.isTemplate = true
            button.action = #selector(togglePanel)
            button.target = self
        }
    }

    @objc private func togglePanel() {
        if panel.isVisible {
            panel.close()
            appState.isPanelVisible = false
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let button = statusItem.button,
              let buttonWindow = button.window else { return }

        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))

        let panelWidth = panel.frame.width
        let panelX = buttonRect.midX - panelWidth / 2
        let panelY = buttonRect.minY - panel.frame.height

        panel.setFrameOrigin(NSPoint(x: panelX, y: panelY))
        panel.makeKeyAndOrderFront(nil)
        appState.isPanelVisible = true
    }
}
