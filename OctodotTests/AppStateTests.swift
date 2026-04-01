import Foundation
import Testing
@testable import Octodot

struct AppStateTests {
    static func makeNotification(id: Int, repo: String = "acme/alpha", isUnread: Bool = true) -> GitHubNotification {
        GitHubNotification(
            id: "\(id)",
            threadId: "\(id)",
            title: "Notification \(id)",
            repository: repo,
            reason: .subscribed,
            type: .pullRequest,
            updatedAt: Date().addingTimeInterval(Double(-id * 600)),
            isUnread: isUnread,
            url: URL(string: "https://github.com/acme/test/pull/\(id)")!,
            subjectURL: nil,
            subjectState: .open
        )
    }

    static func makeNotifications(_ count: Int = 5) -> [GitHubNotification] {
        (0..<count).map { i in
            makeNotification(
                id: i,
                repo: i % 2 == 0 ? "acme/alpha" : "acme/beta",
                isUnread: i < 3
            )
        }
    }

    static func makeState(_ count: Int = 5) -> AppState {
        AppState(notifications: makeNotifications(count))
    }

    // MARK: - Navigation

    @Test func moveDownIncrementsSelection() {
        let state = Self.makeState()
        #expect(state.selectedIndex == 0)
        state.moveDown()
        #expect(state.selectedIndex == 1)
        state.moveDown()
        #expect(state.selectedIndex == 2)
    }

    @Test func moveDownClampsAtEnd() {
        let state = Self.makeState(3)
        state.selectedIndex = 2
        state.moveDown()
        #expect(state.selectedIndex == 2)
    }

    @Test func moveUpDecrementsSelection() {
        let state = Self.makeState()
        state.selectedIndex = 3
        state.moveUp()
        #expect(state.selectedIndex == 2)
    }

    @Test func moveUpClampsAtZero() {
        let state = Self.makeState()
        state.selectedIndex = 0
        state.moveUp()
        #expect(state.selectedIndex == 0)
    }

    @Test func jumpToTop() {
        let state = Self.makeState()
        state.selectedIndex = 4
        state.jumpToTop()
        #expect(state.selectedIndex == 0)
    }

    @Test func jumpToBottom() {
        let state = Self.makeState()
        state.jumpToBottom()
        #expect(state.selectedIndex == 4)
    }

    @Test func navigationOnEmptyListIsNoOp() {
        let state = Self.makeState(0)
        state.moveDown()
        #expect(state.selectedIndex == 0)
        state.moveUp()
        #expect(state.selectedIndex == 0)
        state.jumpToTop()
        #expect(state.selectedIndex == 0)
        state.jumpToBottom()
        #expect(state.selectedIndex == 0)
    }

    // MARK: - Filtering

    @Test func searchFiltersbyTitle() {
        let state = Self.makeState()
        state.searchQuery = "Notification 2"
        #expect(state.filteredNotifications.count == 1)
        #expect(state.filteredNotifications.first?.id == "2")
    }

    @Test func searchFiltersByRepo() {
        let state = Self.makeState()
        state.groupByRepo = false
        state.searchQuery = "alpha"
        let filtered = state.filteredNotifications
        #expect(filtered.allSatisfy { $0.repository == "acme/alpha" })
    }

    @Test func emptySearchReturnsAll() {
        let state = Self.makeState()
        state.searchQuery = ""
        #expect(state.filteredNotifications.count == 5)
    }

    @Test func searchIsCaseInsensitive() {
        let state = Self.makeState()
        state.searchQuery = "NOTIFICATION 0"
        #expect(state.filteredNotifications.count == 1)
    }

    // MARK: - Group by repo

    @Test func groupByRepoSortsByRepository() {
        let state = Self.makeState()
        state.groupByRepo = true
        let repos = state.filteredNotifications.map(\.repository)
        #expect(repos == repos.sorted())
    }

    @Test func toggleGroupByRepoFlips() {
        let state = Self.makeState()
        state.groupByRepo = false
        state.toggleGroupByRepo()
        #expect(state.groupByRepo == true)
        state.toggleGroupByRepo()
        #expect(state.groupByRepo == false)
    }

    // MARK: - Mark read

    @Test func markReadTogglesUnreadState() {
        let state = Self.makeState()
        state.groupByRepo = false
        #expect(state.notifications[0].isUnread == true)
        state.selectedIndex = 0
        state.markRead()
        #expect(state.notifications[0].isUnread == false)
        state.markRead()
        #expect(state.notifications[0].isUnread == true)
    }

    // MARK: - Done (remove + advance)

    @Test func doneRemovesSelectedNotification() {
        let state = Self.makeState()
        state.groupByRepo = false
        let targetId = state.filteredNotifications[0].id
        state.selectedIndex = 0
        state.done()
        #expect(state.notifications.contains(where: { $0.id == targetId }) == false)
        #expect(state.notifications.count == 4)
    }

    @Test func doneAdvancesSelection() {
        let state = Self.makeState()
        state.groupByRepo = false
        state.selectedIndex = 1
        state.done()
        // Selection stays at 1 (now pointing to what was item 2)
        #expect(state.selectedIndex == 1)
    }

    @Test func doneAtLastItemClampsSelection() {
        let state = Self.makeState(3)
        state.groupByRepo = false
        state.selectedIndex = 2
        state.done()
        #expect(state.selectedIndex == 1)
    }

    @Test func doneOnSingleItemResultsInEmptyList() {
        let state = Self.makeState(1)
        state.done()
        #expect(state.notifications.isEmpty)
        #expect(state.selectedIndex == 0)
    }

    // MARK: - Undo

    @Test func undoRestoresRemovedNotification() {
        let state = Self.makeState()
        state.groupByRepo = false
        let original = state.notifications
        state.selectedIndex = 0
        state.done()
        #expect(state.notifications.count == 4)
        state.undo()
        #expect(state.notifications.count == 5)
        #expect(state.notifications[0].id == original[0].id)
    }

    @Test func multipleUndos() {
        let state = Self.makeState()
        state.groupByRepo = false
        state.selectedIndex = 0
        state.done()
        state.selectedIndex = 0
        state.done()
        #expect(state.notifications.count == 3)
        state.undo()
        #expect(state.notifications.count == 4)
        state.undo()
        #expect(state.notifications.count == 5)
    }

    @Test func undoOnEmptyStackIsNoOp() {
        let state = Self.makeState()
        let before = state.notifications.count
        state.undo()
        #expect(state.notifications.count == before)
    }

    // MARK: - Clamp selection

    @Test func clampSelectionWhenIndexExceedsList() {
        let state = Self.makeState(3)
        state.selectedIndex = 10
        state.clampSelection()
        #expect(state.selectedIndex == 2)
    }

    @Test func clampSelectionOnEmptyList() {
        let state = Self.makeState(0)
        state.selectedIndex = 5
        state.clampSelection()
        #expect(state.selectedIndex == 0)
    }

    // MARK: - Selected notification

    @Test func selectedNotificationReturnsCorrectItem() {
        let state = Self.makeState()
        state.groupByRepo = false
        state.selectedIndex = 2
        #expect(state.selectedNotification?.id == "2")
    }

    @Test func selectedNotificationNilWhenEmpty() {
        let state = Self.makeState(0)
        #expect(state.selectedNotification == nil)
    }

    // MARK: - Search activation

    @Test func activateAndDeactivateSearch() {
        let state = Self.makeState()
        state.activateSearch()
        #expect(state.isSearchActive == true)
        state.searchQuery = "test"
        state.deactivateSearch()
        #expect(state.isSearchActive == false)
        #expect(state.searchQuery == "")
    }
}
