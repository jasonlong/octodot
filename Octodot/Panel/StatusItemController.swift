import AppKit
import SwiftUI

final class StatusItemController {
    private let statusItem: NSStatusItem
    private let panel: NotificationPanel
    private let appState: AppState
    private let contextMenu: NSMenu

    init(appState: AppState) {
        self.appState = appState
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.panel = NotificationPanel(appState: appState)

        self.contextMenu = NSMenu()

        if let button = statusItem.button {
            let icon = NSImage(named: "menubar-icon")
            icon?.size = NSSize(width: 18, height: 18)
            icon?.isTemplate = true
            button.image = icon
            button.action = #selector(handleClick)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let quitItem = NSMenuItem(title: "Quit Octodot", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        contextMenu.addItem(quitItem)

        setupGlobalHotkey()
    }

    private func setupGlobalHotkey() {
        // Ctrl+Option+N toggles panel from anywhere
        // Requires Accessibility permission in System Settings → Privacy & Security → Accessibility
        let mask: NSEvent.ModifierFlags = [.control, .option]
        let keyCode: UInt16 = 45 // N

        func isHotkey(_ event: NSEvent) -> Bool {
            event.keyCode == keyCode
                && event.modifierFlags.intersection([.command, .shift, .control, .option]) == mask
        }

        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if isHotkey(event) {
                DispatchQueue.main.async { self?.togglePanel() }
            }
        }

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if isHotkey(event) {
                DispatchQueue.main.async { self?.togglePanel() }
                return nil
            }
            return event
        }
    }

    @objc private func handleClick() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            statusItem.menu = contextMenu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            togglePanel()
        }
    }

    private func togglePanel() {
        if panel.isVisible {
            panel.close()
            appState.isPanelVisible = false
        } else {
            showPanel()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
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
