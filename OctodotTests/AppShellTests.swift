import AppKit
import Carbon
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

    @Test func toggleHotkeyMatchesConfiguredShortcut() {
        #expect(StatusItemController.matchesToggleHotkey(
            keyCode: AppPreferences.GlobalShortcut.commandQuote.keyCode,
            modifierFlags: [.command],
            shortcut: .commandQuote
        ))

        #expect(StatusItemController.matchesToggleHotkey(
            keyCode: AppPreferences.GlobalShortcut.commandQuote.keyCode,
            modifierFlags: [.option],
            shortcut: .commandQuote
        ) == false)

        #expect(StatusItemController.matchesToggleHotkey(
            keyCode: AppPreferences.GlobalShortcut.commandQuote.keyCode,
            modifierFlags: [.command, .shift],
            shortcut: .commandQuote
        ) == false)
    }

    @Test func carbonHotkeyModifiersMirrorAppKitFlags() {
        #expect(StatusItemController.carbonModifiers(from: [.command]) == UInt32(cmdKey))
        #expect(StatusItemController.carbonModifiers(from: [.control, .option]) == UInt32(controlKey | optionKey))
    }

    @Test func outsideClickClosesPanelButStatusItemClickDoesNot() {
        let panelFrame = CGRect(x: 100, y: 100, width: 380, height: 500)
        let statusItemFrame = CGRect(x: 220, y: 620, width: 20, height: 24)

        #expect(StatusItemController.shouldClosePanelForClick(
            mouseLocation: CGPoint(x: 50, y: 50),
            panelFrame: panelFrame,
            statusItemFrame: statusItemFrame
        ))

        #expect(StatusItemController.shouldClosePanelForClick(
            mouseLocation: CGPoint(x: 200, y: 300),
            panelFrame: panelFrame,
            statusItemFrame: statusItemFrame
        ) == false)

        #expect(StatusItemController.shouldClosePanelForClick(
            mouseLocation: CGPoint(x: 225, y: 625),
            panelFrame: panelFrame,
            statusItemFrame: statusItemFrame
        ) == false)
    }

    @Test func appDelegateSkipsUiLaunchUnderXCTest() {
        #expect(AppDelegate.shouldLaunchUI(environment: [:]) == true)
        #expect(AppDelegate.shouldLaunchUI(environment: ["XCTestConfigurationFilePath": "/tmp/test.xctest"]) == false)
    }

    @Test func notificationListScrollRequestRequiresVisibleSelection() {
        let notifications = AppStateTests.makeNotifications(3)

        let request = NotificationListView.scrollRequest(
            selectedNotificationID: "1",
            notifications: notifications,
            groupByRepo: false
        )

        #expect(request?.targetID == "1")
        #expect(request?.visibleIDs == ["0", "1", "2"])
        #expect(NotificationListView.scrollRequest(
            selectedNotificationID: "999",
            notifications: notifications,
            groupByRepo: false
        ) == nil)
    }

    @Test func notificationListScrollRequestTracksVisibleOrder() {
        let notifications = AppStateTests.makeNotifications(3)

        let original = NotificationListView.scrollRequest(
            selectedNotificationID: "1",
            notifications: notifications,
            groupByRepo: false
        )
        let reordered = NotificationListView.scrollRequest(
            selectedNotificationID: "1",
            notifications: Array(notifications.reversed()),
            groupByRepo: false
        )

        #expect(original != reordered)
    }

    @Test func notificationListScrollRequestTargetsRepositoryHeaderForFirstRowInGroup() {
        let notifications = [
            AppStateTests.makeNotification(id: 1, repo: "acme/alpha"),
            AppStateTests.makeNotification(id: 2, repo: "acme/alpha"),
            AppStateTests.makeNotification(id: 3, repo: "acme/beta")
        ]

        let firstInFirstGroup = NotificationListView.scrollRequest(
            selectedNotificationID: "1",
            notifications: notifications,
            groupByRepo: true
        )
        let secondInSameGroup = NotificationListView.scrollRequest(
            selectedNotificationID: "2",
            notifications: notifications,
            groupByRepo: true
        )
        let firstInSecondGroup = NotificationListView.scrollRequest(
            selectedNotificationID: "3",
            notifications: notifications,
            groupByRepo: true
        )

        #expect(firstInFirstGroup?.targetID == "repo:acme/alpha")
        #expect(secondInSameGroup?.targetID == "2")
        #expect(firstInSecondGroup?.targetID == "repo:acme/beta")
    }

    @Test func notificationListBuildsRepositoryHeadersOnlyAtBoundaries() {
        let notifications = [
            AppStateTests.makeNotification(id: 1, repo: "acme/alpha"),
            AppStateTests.makeNotification(id: 2, repo: "acme/alpha"),
            AppStateTests.makeNotification(id: 3, repo: "acme/beta")
        ]

        let items = NotificationListView.listItems(
            notifications: notifications,
            selectedNotificationID: "2",
            groupByRepo: true
        )

        #expect(items == [
            .repositoryHeader(name: "acme/alpha", isFirst: true),
            .notification(notifications[0], isSelected: false),
            .notification(notifications[1], isSelected: true),
            .repositoryHeader(name: "acme/beta", isFirst: false),
            .notification(notifications[2], isSelected: false)
        ])
    }

    @Test func notificationListOmitsHeadersWhenGroupingDisabled() {
        let notifications = AppStateTests.makeNotifications(2)

        let items = NotificationListView.listItems(
            notifications: notifications,
            selectedNotificationID: "1",
            groupByRepo: false
        )

        #expect(items == [
            .notification(notifications[0], isSelected: false),
            .notification(notifications[1], isSelected: true)
        ])
    }

    @Test func notificationRowFormatsRelativeTimeBoundaries() {
        let now = Date(timeIntervalSince1970: 1_000)

        #expect(NotificationRowView.relativeTimeText(from: now.addingTimeInterval(-30), now: now) == "now")
        #expect(NotificationRowView.relativeTimeText(from: now.addingTimeInterval(-120), now: now) == "2m")
        #expect(NotificationRowView.relativeTimeText(from: now.addingTimeInterval(-7_200), now: now) == "2h")
        #expect(NotificationRowView.relativeTimeText(from: now.addingTimeInterval(-172_800), now: now) == "2d")
    }

    @Test func notificationDisplayReferenceNumberParsesPullRequestsAndIssues() {
        let pullRequest = AppStateTests.makeNotification(id: 1234, repo: "planetscale/app-bb")
        let issue = GitHubNotification(
            id: "42",
            threadId: "42",
            title: "Issue",
            repository: "planetscale/app-bb",
            reason: .subscribed,
            type: .issue,
            updatedAt: Date(),
            isUnread: true,
            url: URL(string: "https://github.com/planetscale/app-bb/issues/42")!,
            subjectURL: nil,
            subjectState: .open
        )
        let discussion = GitHubNotification(
            id: "9",
            threadId: "9",
            title: "Discussion",
            repository: "planetscale/app-bb",
            reason: .subscribed,
            type: .discussion,
            updatedAt: Date(),
            isUnread: true,
            url: URL(string: "https://github.com/planetscale/app-bb/discussions/9")!,
            subjectURL: nil,
            subjectState: .unknown
        )

        #expect(pullRequest.displayReferenceNumber == "#1234")
        #expect(issue.displayReferenceNumber == "#42")
        #expect(discussion.displayReferenceNumber == nil)
    }
}
