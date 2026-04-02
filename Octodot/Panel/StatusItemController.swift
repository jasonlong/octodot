import AppKit
import Observation
import SwiftUI

@MainActor
final class StatusItemController {
    enum Constants {
        static let activeAlpha: CGFloat = 1.0
        static let dimmedAlpha: CGFloat = 0.45
        static let iconSize = NSSize(width: 18, height: 18)
        static let toggleHotkeyCode: UInt16 = 45
        static let toggleHotkeyModifiers: NSEvent.ModifierFlags = [.control, .option]
    }

    struct Appearance: Equatable {
        let iconName: String
        let alpha: CGFloat
    }

    private let statusItem: NSStatusItem
    private let panel: NotificationPanel
    private let appState: AppState
    private let contextMenu: NSMenu
    private let defaultIcon = StatusItemController.makeIcon(named: "menubar-icon")
    private let unreadIcon = StatusItemController.makeIcon(named: "menubar-icon-unread")
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?

    init(appState: AppState) {
        self.appState = appState
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.panel = NotificationPanel(appState: appState)

        self.contextMenu = NSMenu()

        if let button = statusItem.button {
            button.image = defaultIcon
            button.action = #selector(handleClick)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let quitItem = NSMenuItem(title: "Quit Octodot", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        contextMenu.addItem(quitItem)

        updateStatusItemAppearance()
        observeStatusItemState()
        setupGlobalHotkey()
        setupOutsideClickMonitors()
    }

    deinit {
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
        }
    }

    private func setupGlobalHotkey() {
        // Ctrl+Option+N toggles panel from anywhere
        // Requires Accessibility permission in System Settings → Privacy & Security → Accessibility
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if Self.matchesToggleHotkey(keyCode: event.keyCode, modifierFlags: event.modifierFlags) {
                DispatchQueue.main.async { self?.togglePanel() }
            }
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if Self.matchesToggleHotkey(keyCode: event.keyCode, modifierFlags: event.modifierFlags) {
                DispatchQueue.main.async { self?.togglePanel() }
                return nil
            }
            return event
        }
    }

    private func setupOutsideClickMonitors() {
        let mouseEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) { [weak self] _ in
            Task { @MainActor in
                self?.closePanelForOutsideClickIfNeeded(mouseLocation: NSEvent.mouseLocation)
            }
        }

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseEvents) { [weak self] event in
            self?.closePanelForOutsideClickIfNeeded(mouseLocation: NSEvent.mouseLocation)
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
        panel.setFrameOrigin(Self.panelOrigin(buttonRect: buttonRect, panelSize: panel.frame.size))
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        appState.isPanelVisible = true
    }

    private func closePanelForOutsideClickIfNeeded(mouseLocation: CGPoint) {
        guard panel.isVisible,
              let statusItemFrame = statusItemButtonScreenFrame()
        else { return }

        let shouldClose = Self.shouldClosePanelForClick(
            mouseLocation: mouseLocation,
            panelFrame: panel.frame,
            statusItemFrame: statusItemFrame
        )

        if shouldClose {
            panel.close()
        }
    }

    private func statusItemButtonScreenFrame() -> CGRect? {
        guard let button = statusItem.button,
              let buttonWindow = button.window
        else { return nil }

        return buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private func observeStatusItemState() {
        withObservationTracking {
            _ = appState.isSignedIn
            _ = appState.unreadNotificationCount
            updateStatusItemAppearance()
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observeStatusItemState()
            }
        }
    }

    private func updateStatusItemAppearance() {
        guard let button = statusItem.button else { return }

        let appearance = Self.appearance(isSignedIn: appState.isSignedIn, unreadCount: appState.unreadNotificationCount)
        button.image = appearance.iconName == "menubar-icon-unread" ? unreadIcon : defaultIcon
        button.alphaValue = appearance.alpha
    }

    private static func makeIcon(named name: String) -> NSImage? {
        let icon = NSImage(named: name)
        icon?.size = Constants.iconSize
        icon?.isTemplate = true
        return icon
    }

    static func appearance(isSignedIn: Bool, unreadCount: Int) -> Appearance {
        let hasUnreadNotifications = isSignedIn && unreadCount > 0
        return Appearance(
            iconName: hasUnreadNotifications ? "menubar-icon-unread" : "menubar-icon",
            alpha: hasUnreadNotifications ? Constants.activeAlpha : Constants.dimmedAlpha
        )
    }

    static func panelOrigin(buttonRect: CGRect, panelSize: CGSize) -> CGPoint {
        CGPoint(
            x: buttonRect.midX - panelSize.width / 2,
            y: buttonRect.minY - panelSize.height
        )
    }

    static func matchesToggleHotkey(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> Bool {
        keyCode == Constants.toggleHotkeyCode
            && modifierFlags.intersection([.command, .shift, .control, .option]) == Constants.toggleHotkeyModifiers
    }

    static func shouldClosePanelForClick(mouseLocation: CGPoint, panelFrame: CGRect, statusItemFrame: CGRect) -> Bool {
        !panelFrame.contains(mouseLocation) && !statusItemFrame.contains(mouseLocation)
    }
}
