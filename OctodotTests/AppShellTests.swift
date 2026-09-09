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

    @Test func panelOriginStaysInsideVisibleScreenFrame() {
        let visibleFrame = CGRect(x: 100, y: 50, width: 1_000, height: 700)
        let panelSize = CGSize(width: 380, height: 500)

        let leftOrigin = StatusItemController.clampedPanelOrigin(
            buttonRect: CGRect(x: 100, y: 730, width: 20, height: 20),
            panelSize: panelSize,
            visibleFrame: visibleFrame
        )
        let rightOrigin = StatusItemController.clampedPanelOrigin(
            buttonRect: CGRect(x: 1_080, y: 730, width: 20, height: 20),
            panelSize: panelSize,
            visibleFrame: visibleFrame
        )

        #expect(leftOrigin.x == visibleFrame.minX)
        #expect(rightOrigin.x == visibleFrame.maxX - panelSize.width)
        #expect(leftOrigin.y >= visibleFrame.minY)
        #expect(rightOrigin.y >= visibleFrame.minY)
    }

    @Test func usableStatusItemFrameRejectsZeroOriginPlaceholderFrame() {
        #expect(StatusItemController.isUsableStatusItemFrame(.zero) == false)
        #expect(StatusItemController.isUsableStatusItemFrame(CGRect(x: 0, y: 0, width: 24, height: 24)) == false)
        let screenFrame = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let validFrame = CGRect(
            x: screenFrame.midX,
            y: max(screenFrame.minY + 1, screenFrame.maxY - 30),
            width: 24,
            height: 24
        )

        #expect(StatusItemController.isUsableStatusItemFrame(validFrame))
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

    @Test func hotkeyFailureMessageMentionsShortcutAndConflict() {
        let message = StatusItemController.hotkeyFailureMessage(
            for: .commandQuote,
            kind: .registerShortcut,
            status: OSStatus(eventHotKeyExistsErr)
        )

        #expect(message.contains("⌘'"))
        #expect(message.contains("Another app may already be using it."))
    }

    @Test func closingNotificationPanelFlushesQueuedActions() async {
        let defaults = AppStateTests.makeIsolatedUserDefaults()
        let session = StubNetworkSession(results: [
            .success((
                Data(),
                AppStateTests.httpResponse(
                    url: "https://api.github.com/notifications/threads/0",
                    statusCode: 204
                )
            ))
        ])
        let client = GitHubAPIClient(
            token: "ghp_secret",
            session: session,
            useGraphQLForSubjectMetadata: false
        )
        let state = AppStateTests.makeState(
            1,
            apiClient: client,
            actionDispatchDelayNanoseconds: 5_000_000_000,
            sleepHandler: AppStateTests.realSleep,
            userDefaults: defaults
        )
        let panel = NotificationPanel(
            appState: state,
            preferences: AppPreferences(userDefaults: defaults),
            updateChecker: UpdateChecker(
                session: StubNetworkSession(results: []),
                userDefaults: defaults
            ),
            showSettings: {}
        )
        state.isPanelVisible = true

        state.done()
        let requestsBeforeClose = await session.recordedRequests()
        #expect(requestsBeforeClose.contains { $0.httpMethod == "DELETE" } == false)

        panel.close()

        await AppStateTests.waitUntil {
            await session.recordedRequests().filter { $0.httpMethod == "DELETE" }.count == 1
        }
        let requestsAfterClose = await session.recordedRequests()
        #expect(requestsAfterClose.filter { $0.httpMethod == "DELETE" }.count == 1)
        #expect(state.isPanelVisible == false)

        panel.close()
        let requestsAfterRepeatedClose = await session.recordedRequests()
        #expect(requestsAfterRepeatedClose.filter { $0.httpMethod == "DELETE" }.count == 1)
    }

    @Test func terminationDrainDispatchesQueuedActionsAndWaitsForCompletion() async {
        let defaults = AppStateTests.makeIsolatedUserDefaults()
        let response = AppStateTests.httpResponse(
            url: "https://api.github.com/notifications/threads/0",
            statusCode: 204
        )
        let session = SuspendedActionSession(response: response)
        let client = GitHubAPIClient(
            token: "ghp_secret",
            session: session,
            useGraphQLForSubjectMetadata: false
        )
        let state = AppStateTests.makeState(
            1,
            apiClient: client,
            actionDispatchDelayNanoseconds: 5_000_000_000,
            sleepHandler: AppStateTests.realSleep,
            userDefaults: defaults
        )
        state.done()

        let drainTask = Task { @MainActor in
            await state.drainPendingActions(
                timeoutNanoseconds: 1_000_000_000,
                pollIntervalNanoseconds: 1,
                terminationSleepHandler: { _ in await Task.yield() }
            )
        }

        await AppStateTests.waitUntil {
            await session.requestStarted()
        }
        #expect(state.hasPendingThreadActions)

        await session.resume()

        #expect(await drainTask.value)
        #expect(state.hasPendingThreadActions == false)
        #expect((await session.recordedRequests()).count == 1)
    }

    @Test func terminationDrainStopsAtInjectedTimeoutWhileActionIsPending() async {
        let defaults = AppStateTests.makeIsolatedUserDefaults()
        let response = AppStateTests.httpResponse(
            url: "https://api.github.com/notifications/threads/0",
            statusCode: 204
        )
        let session = SuspendedActionSession(response: response)
        let client = GitHubAPIClient(
            token: "ghp_secret",
            session: session,
            useGraphQLForSubjectMetadata: false
        )
        let state = AppStateTests.makeState(
            1,
            apiClient: client,
            actionDispatchDelayNanoseconds: 5_000_000_000,
            sleepHandler: AppStateTests.realSleep,
            userDefaults: defaults
        )
        state.done()
        state.flushPendingActions()
        await AppStateTests.waitUntil {
            await session.requestStarted()
        }

        let drained = await state.drainPendingActions(
            timeoutNanoseconds: 3,
            pollIntervalNanoseconds: 1,
            terminationSleepHandler: { _ in }
        )

        #expect(drained == false)
        #expect(state.hasPendingThreadActions)

        await session.resume()
        await AppStateTests.waitUntil {
            await MainActor.run { state.hasPendingThreadActions == false }
        }
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

    @Test func appDelegateRecognizesFirstRunLaunchMode() {
        #expect(AppDelegate.shouldUseFirstRunExperience(arguments: ["Octodot", "--first-run"], environment: [:]))
        #expect(AppDelegate.shouldUseFirstRunExperience(arguments: ["Octodot"], environment: ["OCTODOT_FIRST_RUN": "1"]))
        #expect(AppDelegate.shouldUseFirstRunExperience(arguments: ["Octodot"], environment: ["OCTODOT_FIRST_RUN": "true"]))
        #expect(AppDelegate.shouldUseFirstRunExperience(arguments: ["Octodot"], environment: [:]) == false)
    }

    @Test func appDelegateFirstRunLaunchConfigurationSkipsBootstrapToken() {
        let configuration = AppDelegate.launchConfiguration(
            arguments: ["Octodot", "--first-run"],
            environment: [:],
            tokenLoader: { "ghp_saved" }
        )

        #expect(configuration.bootstrapToken == nil)
        #expect(configuration.useMockData == false)
        #expect(configuration.userDefaults != .standard)
        #expect(configuration.shouldShowPanelOnLaunch)
    }

    @Test func appDelegateLaunchConfigurationUnderXCTestSkipsTokenLoader() {
        var didLoadToken = false

        let configuration = AppDelegate.launchConfiguration(
            arguments: ["Octodot"],
            environment: ["XCTestConfigurationFilePath": "/tmp/test.xctest"],
            tokenLoader: {
                didLoadToken = true
                return "should-not-load"
            }
        )

        #expect(didLoadToken == false)
        #expect(configuration.bootstrapToken == nil)
        #expect(configuration.useMockData == false)
        #expect(configuration.shouldShowPanelOnLaunch == false)
        #expect(configuration.userDefaults != .standard)
    }

    @Test func appDelegateNormalLaunchConfigurationUsesSavedToken() {
        let configuration = AppDelegate.launchConfiguration(
            arguments: ["Octodot"],
            environment: [:],
            tokenLoader: { "ghp_saved" }
        )

        #expect(configuration.bootstrapToken == "ghp_saved")
        #expect(configuration.useMockData == false)
        #expect(configuration.userDefaults == .standard)
        #expect(configuration.shouldShowPanelOnLaunch == false)
    }

    @Test func appDelegateNormalDebugLaunchWithoutTokenUsesMockData() {
        let configuration = AppDelegate.launchConfiguration(
            arguments: ["Octodot"],
            environment: [:],
            tokenLoader: { nil }
        )

        #if DEBUG
        #expect(configuration.useMockData)
        #else
        #expect(configuration.useMockData == false)
        #endif
    }

    @Test func firstRunStateStaysSignedOutInsteadOfUsingDebugMockData() {
        let configuration = AppDelegate.launchConfiguration(
            arguments: ["Octodot", "--first-run"],
            environment: [:],
            tokenLoader: { "ghp_saved" }
        )
        let state = AppState(
            userDefaults: configuration.userDefaults,
            bootstrapToken: configuration.bootstrapToken,
            useMockData: configuration.useMockData
        )

        #expect(state.notifications.isEmpty)
        #expect(state.authStatus == .signedOut)
    }

    @Test func appDelegateShowsPanelOnlyOnceWhenLaunchingWithoutSavedToken() {
        let defaults = AppStateTests.makeIsolatedUserDefaults()

        let first = AppDelegate.shouldShowPanelOnLaunch(
            bootstrapToken: nil,
            userDefaults: defaults
        )
        let second = AppDelegate.shouldShowPanelOnLaunch(
            bootstrapToken: nil,
            userDefaults: defaults
        )

        #expect(first)
        #expect(second == false)
    }

    @Test func appDelegateDoesNotShowPanelWhenSavedTokenExists() {
        let defaults = AppStateTests.makeIsolatedUserDefaults()

        let shouldShow = AppDelegate.shouldShowPanelOnLaunch(
            bootstrapToken: "ghp_saved",
            userDefaults: defaults
        )

        #expect(shouldShow == false)
    }

    @Test func terminationPolicyDistinguishesUpdaterRelaunchFromUserQuit() {
        #expect(AppDelegate.terminationPolicy(
            hasPendingThreadActions: false,
            isInstallingUpdate: false,
            isTerminatingAfterSuccessfulUpdate: false
        ) == .terminateNow)
        #expect(AppDelegate.terminationPolicy(
            hasPendingThreadActions: true,
            isInstallingUpdate: false,
            isTerminatingAfterSuccessfulUpdate: false
        ) == .drainPendingActions)
        #expect(AppDelegate.terminationPolicy(
            hasPendingThreadActions: false,
            isInstallingUpdate: true,
            isTerminatingAfterSuccessfulUpdate: false
        ) == .cancelInstallAndDrainPendingActions)
        #expect(AppDelegate.terminationPolicy(
            hasPendingThreadActions: true,
            isInstallingUpdate: true,
            isTerminatingAfterSuccessfulUpdate: true
        ) == .drainPendingActions)
        #expect(AppDelegate.terminationPolicy(
            hasPendingThreadActions: false,
            isInstallingUpdate: true,
            isTerminatingAfterSuccessfulUpdate: true
        ) == .terminateNow)
    }

    @Test func terminationCoordinatorWaitsForActionAndUpdaterCleanupAndRepliesOnce() async {
        let coordinator = ApplicationTerminationCoordinator()
        let actions = TerminationOperationGate()
        let updater = TerminationOperationGate()
        var replyCount = 0

        let firstReply = coordinator.begin(
            policy: .cancelInstallAndDrainPendingActions,
            drainPendingActions: { await actions.wait() },
            cancelInstall: { await updater.wait() },
            reply: { replyCount += 1 }
        )
        #expect(firstReply == .terminateLater)

        await AppStateTests.waitUntil {
            await MainActor.run { actions.didStart && updater.didStart }
        }
        let repeatedReply = coordinator.begin(
            policy: .terminateNow,
            drainPendingActions: { true },
            cancelInstall: { true },
            reply: { replyCount += 1 }
        )
        #expect(repeatedReply == .terminateLater)

        actions.finish(with: true)
        await AppStateTests.settleTasks()
        #expect(replyCount == 0)

        updater.finish(with: false)
        await AppStateTests.waitUntil {
            await MainActor.run { replyCount == 1 }
        }
        #expect(replyCount == 1)

        let afterReply = coordinator.begin(
            policy: .terminateNow,
            drainPendingActions: { true },
            cancelInstall: { true },
            reply: { replyCount += 1 }
        )
        #expect(afterReply == .terminateLater)
        #expect(replyCount == 1)
    }

    @Test func successfulUpdateTerminationDrainsActionsWithoutCancellingUpdater() async {
        let coordinator = ApplicationTerminationCoordinator()
        var actionDrainCount = 0
        var updaterCancelCount = 0
        var replyCount = 0

        let initialReply = coordinator.begin(
            policy: .drainPendingActions,
            drainPendingActions: {
                actionDrainCount += 1
                return true
            },
            cancelInstall: {
                updaterCancelCount += 1
                return true
            },
            reply: { replyCount += 1 }
        )

        #expect(initialReply == .terminateLater)
        await AppStateTests.waitUntil {
            await MainActor.run { replyCount == 1 }
        }
        #expect(actionDrainCount == 1)
        #expect(updaterCancelCount == 0)
        #expect(replyCount == 1)
    }

    @Test func notificationListRowTapSelectsBeforeOpening() {
        var operations: [String] = []

        NotificationListView.handleRowTap(
            id: "42",
            onSelect: { operations.append("select:\($0)") },
            onOpen: { operations.append("open:\($0)") }
        )

        #expect(operations == ["select:42", "open:42"])
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

    @Test func notificationListScrollRequestKeepsSelectedRowTargetAcrossRepositoryBoundaries() {
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

        #expect(firstInFirstGroup?.targetID == "1")
        #expect(secondInSameGroup?.targetID == "2")
        #expect(firstInSecondGroup?.targetID == "3")
    }

    @Test func notificationListJumpToTopTargetsFirstRepositoryHeader() {
        let notifications = [
            AppStateTests.makeNotification(id: 1, repo: "acme/alpha"),
            AppStateTests.makeNotification(id: 2, repo: "acme/alpha"),
            AppStateTests.makeNotification(id: 3, repo: "acme/beta")
        ]
        let previous = NotificationListView.scrollRequest(
            selectedNotificationID: "3",
            notifications: notifications,
            groupByRepo: true,
            jumpToTopRequestID: 0
        )
        let current = NotificationListView.scrollRequest(
            selectedNotificationID: "1",
            notifications: notifications,
            groupByRepo: true,
            jumpToTopRequestID: 1
        )

        #expect(current?.topTargetID == "repo:acme/alpha")
        #expect(NotificationListView.shouldAnchorTop(previous: previous, current: current!))
    }

    @Test func notificationListRepeatedJumpToTopStillRequestsTopAnchor() {
        let notifications = AppStateTests.makeNotifications(3)
        let previous = NotificationListView.scrollRequest(
            selectedNotificationID: "0",
            notifications: notifications,
            groupByRepo: false,
            jumpToTopRequestID: 4
        )
        let current = NotificationListView.scrollRequest(
            selectedNotificationID: "0",
            notifications: notifications,
            groupByRepo: false,
            jumpToTopRequestID: 5
        )

        #expect(current?.topTargetID == "0")
        #expect(NotificationListView.shouldAnchorTop(previous: previous, current: current!))
    }

    @Test func notificationListSelectionChangeDoesNotRequestTopAnchor() {
        let notifications = AppStateTests.makeNotifications(3)
        let previous = NotificationListView.scrollRequest(
            selectedNotificationID: "2",
            notifications: notifications,
            groupByRepo: false,
            jumpToTopRequestID: 7
        )
        let current = NotificationListView.scrollRequest(
            selectedNotificationID: "0",
            notifications: notifications,
            groupByRepo: false,
            jumpToTopRequestID: 7
        )

        #expect(NotificationListView.shouldAnchorTop(previous: previous, current: current!) == false)
    }

    @Test func notificationListRevealsContextWhenMovingDownFromViewportBottom() {
        let notifications = AppStateTests.makeNotifications(4)
        let previous = NotificationListView.scrollRequest(
            selectedNotificationID: "1",
            notifications: notifications,
            groupByRepo: false
        )
        let current = NotificationListView.scrollRequest(
            selectedNotificationID: "2",
            notifications: notifications,
            groupByRepo: false
        )

        #expect(NotificationListView.shouldRevealDownwardContext(
            previous: previous,
            current: current!,
            previousRowFrame: CGRect(x: 0, y: 356, width: 380, height: 44),
            currentRowFrame: CGRect(x: 0, y: 400, width: 380, height: 44),
            viewportHeight: 400
        ))
        #expect(NotificationListView.shouldRevealDownwardContext(
            previous: previous,
            current: current!,
            previousRowFrame: CGRect(x: 0, y: 300, width: 380, height: 44),
            currentRowFrame: CGRect(x: 0, y: 400, width: 380, height: 44),
            viewportHeight: 400
        ))
        #expect(NotificationListView.shouldRevealDownwardContext(
            previous: previous,
            current: current!,
            previousRowFrame: CGRect(x: 0, y: 348, width: 380, height: 44),
            currentRowFrame: nil,
            viewportHeight: 406
        ))
        #expect(NotificationListView.shouldRevealDownwardContext(
            previous: previous,
            current: current!,
            previousRowFrame: CGRect(x: 0, y: 300, width: 380, height: 44),
            currentRowFrame: CGRect(x: 0, y: 344, width: 380, height: 44),
            viewportHeight: 400
        ) == false)
    }

    @Test func notificationListRevealsContextAfterActingOnBottomItem() {
        let notifications = AppStateTests.makeNotifications(4)
        let previous = NotificationListView.scrollRequest(
            selectedNotificationID: "1",
            notifications: notifications,
            groupByRepo: false
        )
        let current = NotificationListView.scrollRequest(
            selectedNotificationID: "2",
            notifications: [notifications[0], notifications[2], notifications[3]],
            groupByRepo: false
        )
        #expect(NotificationListView.shouldRevealDownwardContext(
            previous: previous,
            current: current!,
            previousRowFrame: CGRect(x: 0, y: 356, width: 380, height: 44),
            currentRowFrame: CGRect(x: 0, y: 356, width: 380, height: 44),
            viewportHeight: 400
        ))
    }

    @Test func notificationListDoesNotRevealDownwardContextWhenMovingUp() {
        let notifications = AppStateTests.makeNotifications(4)
        let previous = NotificationListView.scrollRequest(
            selectedNotificationID: "2",
            notifications: notifications,
            groupByRepo: false
        )
        let current = NotificationListView.scrollRequest(
            selectedNotificationID: "1",
            notifications: notifications,
            groupByRepo: false
        )

        #expect(NotificationListView.shouldRevealDownwardContext(
            previous: previous,
            current: current!,
            previousRowFrame: CGRect(x: 0, y: 356, width: 380, height: 44),
            currentRowFrame: CGRect(x: 0, y: 312, width: 380, height: 44),
            viewportHeight: 400
        ) == false)
    }

    @Test func notificationListSuppressesScrollAfterPointerActionRemovesRow() {
        let notifications = AppStateTests.makeNotifications(4)
        let previous = NotificationListView.scrollRequest(
            selectedNotificationID: "1",
            notifications: notifications,
            groupByRepo: false
        )
        let current = NotificationListView.scrollRequest(
            selectedNotificationID: "2",
            notifications: [notifications[0], notifications[2], notifications[3]],
            groupByRepo: false
        )
        let currentAfterRemovingUnselectedRow = NotificationListView.scrollRequest(
            selectedNotificationID: "1",
            notifications: [notifications[0], notifications[1], notifications[2]],
            groupByRepo: false
        )

        #expect(NotificationListView.shouldSuppressScroll(
            previous: previous,
            current: current!,
            pointerActionID: "1"
        ))
        #expect(NotificationListView.shouldSuppressScroll(
            previous: previous,
            current: current!,
            pointerActionID: nil
        ) == false)
        #expect(NotificationListView.shouldSuppressScroll(
            previous: previous,
            current: currentAfterRemovingUnselectedRow!,
            pointerActionID: "3"
        ))
        #expect(NotificationListView.shouldSuppressScroll(
            previous: previous,
            current: current!,
            pointerActionID: "3"
        ) == false)
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

    @Test func issueMetadataResolutionRunsOnceWhenOpenerIsUnavailable() {
        var issue = GitHubNotification(
            id: "42",
            threadId: "42",
            title: "Issue",
            repository: "acme/test",
            reason: .subscribed,
            type: .issue,
            updatedAt: Date(),
            isUnread: true,
            url: URL(string: "https://github.com/acme/test/issues/42")!,
            subjectURL: "https://api.github.com/repos/acme/test/issues/42",
            subjectState: .open
        )

        #expect(issue.needsSubjectMetadataResolution)
        let didApply = issue.apply(.init(state: .open, ciStatus: nil, hasResolvedOpener: true))
        #expect(didApply)
        #expect(issue.needsSubjectMetadataResolution == false)
    }

    @Test func pullRequestWithoutCIRunsMetadataResolutionOncePerFreshnessWindow() {
        var pullRequest = GitHubNotification(
            id: "42",
            threadId: "42",
            title: "Pull request",
            repository: "acme/test",
            reason: .reviewRequested,
            type: .pullRequest,
            updatedAt: Date(),
            isUnread: true,
            url: URL(string: "https://github.com/acme/test/pull/42")!,
            subjectURL: "https://api.github.com/repos/acme/test/pulls/42",
            subjectState: .open
        )

        #expect(pullRequest.needsSubjectMetadataResolution)
        let didApply = pullRequest.apply(
            .init(
                state: .open,
                ciStatus: nil,
                hasResolvedCIStatus: true,
                hasResolvedOpener: true
            )
        )
        #expect(didApply)
        #expect(pullRequest.ciStatus == nil)
        #expect(pullRequest.hasResolvedCIStatus)
        #expect(pullRequest.needsSubjectMetadataResolution == false)

        _ = pullRequest.apply(
            .init(
                state: .open,
                ciStatus: nil,
                hasResolvedCIStatus: false,
                hasResolvedOpener: true
            )
        )
        #expect(pullRequest.needsSubjectMetadataResolution)
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

private actor SuspendedActionSession: NetworkSession {
    private let response: HTTPURLResponse
    private var requests: [URLRequest] = []
    private var continuation: CheckedContinuation<Void, Never>?

    init(response: HTTPURLResponse) {
        self.response = response
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        return (Data(), response)
    }

    func requestStarted() -> Bool {
        !requests.isEmpty
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class TerminationOperationGate {
    private(set) var didStart = false
    private var continuation: CheckedContinuation<Bool, Never>?

    func wait() async -> Bool {
        didStart = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func finish(with result: Bool) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}
