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
            let icon = NSImage(named: "menubar-icon")
            icon?.size = NSSize(width: 18, height: 18)
            icon?.isTemplate = true
            button.image = icon
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
