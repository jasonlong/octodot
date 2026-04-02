import AppKit
import Testing
@testable import Octodot

@MainActor
struct AppShellTests {
    @Test func statusItemAppearanceShowsUnreadVariantOnlyWhenSignedInWithUnread() {
        let signedOut = StatusItemController.appearance(isSignedIn: false, unreadCount: 3)
        let signedInNoUnread = StatusItemController.appearance(isSignedIn: true, unreadCount: 0)
        let signedInUnread = StatusItemController.appearance(isSignedIn: true, unreadCount: 2)

        #expect(signedOut.iconName == "menubar-icon")
        #expect(signedOut.alpha == StatusItemController.Constants.dimmedAlpha)
        #expect(signedInNoUnread.iconName == "menubar-icon")
        #expect(signedInNoUnread.alpha == StatusItemController.Constants.dimmedAlpha)
        #expect(signedInUnread.iconName == "menubar-icon-unread")
        #expect(signedInUnread.alpha == StatusItemController.Constants.activeAlpha)
    }

    @Test func panelOriginCentersPanelUnderStatusItem() {
        let buttonRect = CGRect(x: 200, y: 500, width: 20, height: 24)
        let panelSize = CGSize(width: 380, height: 500)
        let origin = StatusItemController.panelOrigin(buttonRect: buttonRect, panelSize: panelSize)

        #expect(origin.x == 20)
        #expect(origin.y == 0)
    }

    @Test func toggleHotkeyMatchesOnlyControlOptionN() {
        #expect(StatusItemController.matchesToggleHotkey(
            keyCode: StatusItemController.Constants.toggleHotkeyCode,
            modifierFlags: [.control, .option]
        ))

        #expect(StatusItemController.matchesToggleHotkey(
            keyCode: StatusItemController.Constants.toggleHotkeyCode,
            modifierFlags: [.control]
        ) == false)

        #expect(StatusItemController.matchesToggleHotkey(
            keyCode: StatusItemController.Constants.toggleHotkeyCode,
            modifierFlags: [.control, .option, .shift]
        ) == false)
    }

    @Test func appDelegateSkipsUiLaunchUnderXCTest() {
        #expect(AppDelegate.shouldLaunchUI(environment: [:]) == true)
        #expect(AppDelegate.shouldLaunchUI(environment: ["XCTestConfigurationFilePath": "/tmp/test.xctest"]) == false)
    }
}
