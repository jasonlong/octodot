import AppKit
import Carbon
import Observation
import SwiftUI

@MainActor
final class StatusItemController: NSObject {
    enum Constants {
        static let activeAlpha: CGFloat = 1.0
        static let dimmedAlpha: CGFloat = 0.45
        static let iconSize = NSSize(width: 18, height: 18)
        static let hotKeySignature: OSType = 0x4F435444 // 'OCTD'
        static let hotKeyID: UInt32 = 1
    }

    struct Appearance: Equatable {
        let iconName: String
        let alpha: CGFloat
    }

    private let statusItem: NSStatusItem
    private let panel: NotificationPanel
    private let settingsWindowController: SettingsWindowController
    private let appState: AppState
    private let preferences: AppPreferences
    private let contextMenu: NSMenu
    private let defaultIcon = StatusItemController.makeIcon(named: "menubar-icon")
    private let unreadIcon = StatusItemController.makeIcon(named: "menubar-icon-unread")
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerRef: EventHandlerRef?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?

    init(appState: AppState, preferences: AppPreferences) {
        self.appState = appState
        self.preferences = preferences
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.panel = NotificationPanel(appState: appState, preferences: preferences)
        self.settingsWindowController = SettingsWindowController(appState: appState, preferences: preferences)

        self.contextMenu = NSMenu()
        super.init()

        if let button = statusItem.button {
            button.image = defaultIcon
            button.action = #selector(handleClick)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        contextMenu.addItem(settingsItem)
        contextMenu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Octodot", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        contextMenu.addItem(quitItem)

        updateStatusItemAppearance()
        observeStatusItemState()
        observeAppearancePreference()
        setupGlobalHotkeyHandler()
        observeHotkeyPreference()
        updateRegisteredGlobalHotkey()
        setupOutsideClickMonitors()
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let hotKeyHandlerRef {
            RemoveEventHandler(hotKeyHandlerRef)
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
        }
    }

    private func setupGlobalHotkeyHandler() {
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let eventTarget = GetApplicationEventTarget()

        let installStatus = InstallEventHandler(
            eventTarget,
            { _, eventRef, userData in
                guard let userData else { return noErr }

                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )

                guard status == noErr,
                      hotKeyID.signature == Constants.hotKeySignature,
                      hotKeyID.id == Constants.hotKeyID else {
                    return noErr
                }

                let controller = Unmanaged<StatusItemController>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                Task { @MainActor in
                    controller.togglePanel()
                }
                return noErr
            },
            1,
            &eventSpec,
            userData,
            &hotKeyHandlerRef
        )
        guard installStatus == noErr else {
            assertionFailure("Failed to install global hotkey handler: \(installStatus)")
            return
        }
    }

    private func updateRegisteredGlobalHotkey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }

        let hotKeyID = EventHotKeyID(signature: Constants.hotKeySignature, id: Constants.hotKeyID)
        let shortcut = preferences.globalShortcut
        let registerStatus = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            Self.carbonModifiers(from: shortcut.modifierFlags),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard registerStatus == noErr else {
            assertionFailure("Failed to register global hotkey: \(registerStatus)")
            return
        }
    }

    private func observeHotkeyPreference() {
        withObservationTracking {
            _ = preferences.globalShortcut
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateRegisteredGlobalHotkey()
                self?.observeHotkeyPreference()
            }
        }
    }

    private func observeAppearancePreference() {
        withObservationTracking {
            _ = preferences.appearanceMode
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.settingsWindowController.updateAppearance()
                self.observeAppearancePreference()
            }
        }
    }

    static func carbonModifiers(from modifierFlags: NSEvent.ModifierFlags) -> UInt32 {
        var carbonFlags: UInt32 = 0
        if modifierFlags.contains(.command) {
            carbonFlags |= UInt32(cmdKey)
        }
        if modifierFlags.contains(.option) {
            carbonFlags |= UInt32(optionKey)
        }
        if modifierFlags.contains(.control) {
            carbonFlags |= UInt32(controlKey)
        }
        if modifierFlags.contains(.shift) {
            carbonFlags |= UInt32(shiftKey)
        }
        return carbonFlags
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
            showContextMenu()
        } else {
            togglePanel()
        }
    }

    private func showContextMenu() {
        guard let button = statusItem.button else { return }

        let menuOrigin = NSPoint(x: 0, y: button.bounds.height + 4)
        contextMenu.popUp(positioning: nil, at: menuOrigin, in: button)
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

    @objc private func openSettings() {
        DispatchQueue.main.async { [self] in
            DebugTrace.log("settings menu action fired")
            NSApp.activate(ignoringOtherApps: true)
            DebugTrace.log("settings opening custom window directly")
            settingsWindowController.show()
        }
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

    static func matchesToggleHotkey(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        shortcut: AppPreferences.GlobalShortcut
    ) -> Bool {
        keyCode == shortcut.keyCode
            && modifierFlags.intersection([.command, .shift, .control, .option]) == shortcut.modifierFlags
    }

    static func shouldClosePanelForClick(mouseLocation: CGPoint, panelFrame: CGRect, statusItemFrame: CGRect) -> Bool {
        !panelFrame.contains(mouseLocation) && !statusItemFrame.contains(mouseLocation)
    }
}
