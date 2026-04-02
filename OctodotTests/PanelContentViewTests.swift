import Testing
@testable import Octodot

struct PanelContentViewTests {
    @Test func routeKeyMapsCoreListCommands() {
        #expect(PanelContentView.routeKey(.character("j"), isSearchActive: false, pendingG: false) ==
            .init(command: .moveDown, pendingG: false, focusDirective: .unchanged, isHandled: true))
        #expect(PanelContentView.routeKey(.character("k"), isSearchActive: false, pendingG: false) ==
            .init(command: .moveUp, pendingG: false, focusDirective: .unchanged, isHandled: true))
        #expect(PanelContentView.routeKey(.character("d"), isSearchActive: false, pendingG: false) ==
            .init(command: .done, pendingG: false, focusDirective: .unchanged, isHandled: true))
        #expect(PanelContentView.routeKey(.character("x"), isSearchActive: false, pendingG: false) ==
            .init(command: .unsubscribe, pendingG: false, focusDirective: .unchanged, isHandled: true))
        #expect(PanelContentView.routeKey(.character("u"), isSearchActive: false, pendingG: false) ==
            .init(command: .undo, pendingG: false, focusDirective: .unchanged, isHandled: true))
        #expect(PanelContentView.routeKey(.character("a"), isSearchActive: false, pendingG: false) ==
            .init(command: .toggleInboxMode, pendingG: false, focusDirective: .unchanged, isHandled: true))
    }

    @Test func routeKeyHandlesSearchFocusTransitions() {
        #expect(PanelContentView.routeKey(.character("/"), isSearchActive: false, pendingG: false) ==
            .init(command: .activateSearch, pendingG: false, focusDirective: .search, isHandled: true))
        #expect(PanelContentView.routeKey(.escape, isSearchActive: true, pendingG: false) ==
            .init(command: .deactivateSearch, pendingG: false, focusDirective: .list, isHandled: true))
        #expect(PanelContentView.routeKey(.return, isSearchActive: true, pendingG: false) ==
            .init(command: nil, pendingG: false, focusDirective: .list, isHandled: true))
        #expect(PanelContentView.routeKey(.character("j"), isSearchActive: true, pendingG: false) ==
            .init(command: nil, pendingG: false, focusDirective: .unchanged, isHandled: false))
    }

    @Test func routeKeyHandlesGgSequence() {
        #expect(PanelContentView.routeKey(.character("g"), isSearchActive: false, pendingG: false) ==
            .init(command: nil, pendingG: true, focusDirective: .unchanged, isHandled: true))
        #expect(PanelContentView.routeKey(.character("g"), isSearchActive: false, pendingG: true) ==
            .init(command: .jumpToTop, pendingG: false, focusDirective: .unchanged, isHandled: true))
        #expect(PanelContentView.routeKey(.character("j"), isSearchActive: false, pendingG: true) ==
            .init(command: .moveDown, pendingG: false, focusDirective: .unchanged, isHandled: true))
    }

    @Test func routeKeyMapsOpenRefreshAndCloseCommands() {
        #expect(PanelContentView.routeKey(.character("o"), isSearchActive: false, pendingG: false) ==
            .init(command: .open, pendingG: false, focusDirective: .unchanged, isHandled: true))
        #expect(PanelContentView.routeKey(.return, isSearchActive: false, pendingG: false) ==
            .init(command: .open, pendingG: false, focusDirective: .unchanged, isHandled: true))
        #expect(PanelContentView.routeKey(.character("r"), isSearchActive: false, pendingG: false) ==
            .init(command: .forceRefresh, pendingG: false, focusDirective: .unchanged, isHandled: true))
        #expect(PanelContentView.routeKey(.escape, isSearchActive: false, pendingG: false) ==
            .init(command: .closePanel, pendingG: false, focusDirective: .unchanged, isHandled: true))
    }

    @Test func notificationSummaryReflectsMode() {
        #expect(
            PanelContentView.notificationSummary(
                unreadCount: 3,
                totalCount: 3,
                mode: .unread
            ) == "3 unread"
        )
        #expect(
            PanelContentView.notificationSummary(
                unreadCount: 3,
                totalCount: 8,
                mode: .all
            ) == "3 unread · 8 total"
        )
    }

    @Test func searchFieldSubmitReturnsFocusToListAndKeepsFilter() {
        #expect(
            PanelContentView.searchFieldEffect(for: .submit) ==
            .init(clearsQuery: false, keepsSearchActive: false, focusDirective: .list)
        )
    }

    @Test func searchFieldCancelClearsFilterAndReturnsFocusToList() {
        #expect(
            PanelContentView.searchFieldEffect(for: .cancel) ==
            .init(clearsQuery: true, keepsSearchActive: false, focusDirective: .list)
        )
    }

    @Test func persistentQueryKeepsSearchBarVisible() {
        #expect(
            PanelContentView.shouldShowSearchBar(
                isSearchActive: true,
                query: ""
            ) == true
        )
        #expect(
            PanelContentView.shouldShowSearchBar(
                isSearchActive: false,
                query: "backup"
            ) == true
        )
        #expect(
            PanelContentView.shouldShowSearchBar(
                isSearchActive: false,
                query: "   "
            ) == false
        )
    }

    @Test func repeatIsAllowedOnlyForNavigation() {
        #expect(PanelContentView.allowsRepeat(for: .character("j")) == true)
        #expect(PanelContentView.allowsRepeat(for: .character("k")) == true)
        #expect(PanelContentView.allowsRepeat(for: .downArrow) == true)
        #expect(PanelContentView.allowsRepeat(for: .upArrow) == true)
        #expect(PanelContentView.allowsRepeat(for: .character("x")) == false)
        #expect(PanelContentView.allowsRepeat(for: .character("d")) == false)
        #expect(PanelContentView.allowsRepeat(for: .character("o")) == false)
    }

    @Test func destructiveAndActionKeysExecuteOnKeyUp() {
        #expect(PanelContentView.handlesOnKeyUp(for: .character("d")) == true)
        #expect(PanelContentView.handlesOnKeyUp(for: .character("x")) == true)
        #expect(PanelContentView.handlesOnKeyUp(for: .character("o")) == true)
        #expect(PanelContentView.handlesOnKeyUp(for: .character("r")) == true)
        #expect(PanelContentView.handlesOnKeyUp(for: .character("j")) == false)
        #expect(PanelContentView.handlesOnKeyUp(for: .character("k")) == false)
        #expect(PanelContentView.handlesOnKeyUp(for: .character("g")) == false)
    }

    @Test func singleFireDeduplicationAppliesOnlyToDestructiveAndOpenCommands() {
        #expect(PanelContentView.isSingleFireListCommand(.done) == true)
        #expect(PanelContentView.isSingleFireListCommand(.unsubscribe) == true)
        #expect(PanelContentView.isSingleFireListCommand(.open) == true)
        #expect(PanelContentView.isSingleFireListCommand(.undo) == true)
        #expect(PanelContentView.isSingleFireListCommand(.moveDown) == false)
        #expect(PanelContentView.isSingleFireListCommand(.moveUp) == false)
        #expect(PanelContentView.isSingleFireListCommand(.forceRefresh) == false)
        #expect(PanelContentView.singleFireCommandDeduplicationInterval == 0.2)
    }
}
