import Testing
@testable import Octodot

struct PanelContentViewTests {
    @Test func routeKeyMapsCoreListCommands() {
        #expect(PanelInput.routeKey(.character("j"), isSearchActive: false, pendingG: false) ==
            .init(command: .moveDown, pendingG: false, focusDirective: .unchanged, isHandled: true))
        #expect(PanelInput.routeKey(.character("k"), isSearchActive: false, pendingG: false) ==
            .init(command: .moveUp, pendingG: false, focusDirective: .unchanged, isHandled: true))
        #expect(PanelInput.routeKey(.character("d"), isSearchActive: false, pendingG: false) ==
            .init(command: .done, pendingG: false, focusDirective: .unchanged, isHandled: true))
        #expect(PanelInput.routeKey(.character("x"), isSearchActive: false, pendingG: false) ==
            .init(command: .unsubscribe, pendingG: false, focusDirective: .unchanged, isHandled: true))
        #expect(PanelInput.routeKey(.character("u"), isSearchActive: false, pendingG: false) ==
            .init(command: .undo, pendingG: false, focusDirective: .unchanged, isHandled: true))
        #expect(PanelInput.routeKey(.character("a"), isSearchActive: false, pendingG: false) ==
            .init(command: .toggleInboxMode, pendingG: false, focusDirective: .unchanged, isHandled: true))
    }

    @Test func routeKeyHandlesSearchFocusTransitions() {
        #expect(PanelInput.routeKey(.character("/"), isSearchActive: false, pendingG: false) ==
            .init(command: .activateSearch, pendingG: false, focusDirective: .search, isHandled: true))
        #expect(PanelInput.routeKey(.escape, isSearchActive: true, pendingG: false) ==
            .init(command: .deactivateSearch, pendingG: false, focusDirective: .list, isHandled: true))
        #expect(PanelInput.routeKey(.return, isSearchActive: true, pendingG: false) ==
            .init(command: nil, pendingG: false, focusDirective: .list, isHandled: true))
        #expect(PanelInput.routeKey(.character("j"), isSearchActive: true, pendingG: false) ==
            .init(command: nil, pendingG: false, focusDirective: .unchanged, isHandled: false))
    }

    @Test func routeKeyHandlesGgSequence() {
        #expect(PanelInput.routeKey(.character("g"), isSearchActive: false, pendingG: false) ==
            .init(command: nil, pendingG: true, focusDirective: .unchanged, isHandled: true))
        #expect(PanelInput.routeKey(.character("g"), isSearchActive: false, pendingG: true) ==
            .init(command: .jumpToTop, pendingG: false, focusDirective: .unchanged, isHandled: true))
        #expect(PanelInput.routeKey(.character("j"), isSearchActive: false, pendingG: true) ==
            .init(command: .moveDown, pendingG: false, focusDirective: .unchanged, isHandled: true))
    }

    @Test func routeKeyMapsOpenRefreshAndCloseCommands() {
        #expect(PanelInput.routeKey(.character("o"), isSearchActive: false, pendingG: false) ==
            .init(command: .open, pendingG: false, focusDirective: .unchanged, isHandled: true))
        #expect(PanelInput.routeKey(.return, isSearchActive: false, pendingG: false) ==
            .init(command: .open, pendingG: false, focusDirective: .unchanged, isHandled: true))
        #expect(PanelInput.routeKey(.character("r"), isSearchActive: false, pendingG: false) ==
            .init(command: .forceRefresh, pendingG: false, focusDirective: .unchanged, isHandled: true))
        #expect(PanelInput.routeKey(.escape, isSearchActive: false, pendingG: false) ==
            .init(command: .closePanel, pendingG: false, focusDirective: .unchanged, isHandled: true))
    }

    @Test func notificationSummaryReflectsMode() {
        #expect(
            PanelInput.notificationSummary(
                unreadCount: 3,
                totalCount: 3,
                mode: .unread
            ) == "3 unread"
        )
        #expect(
            PanelInput.notificationSummary(
                unreadCount: 3,
                totalCount: 8,
                mode: .all
            ) == "3 unread · 8 total"
        )
    }

    @Test func searchFieldSubmitReturnsFocusToListAndKeepsFilter() {
        #expect(
            PanelInput.searchFieldEffect(for: .submit) ==
            .init(clearsQuery: false, keepsSearchActive: false, focusDirective: .list)
        )
    }

    @Test func searchFieldCancelClearsFilterAndReturnsFocusToList() {
        #expect(
            PanelInput.searchFieldEffect(for: .cancel) ==
            .init(clearsQuery: true, keepsSearchActive: false, focusDirective: .list)
        )
    }

    @Test func persistentQueryKeepsSearchBarVisible() {
        #expect(
            PanelInput.shouldShowSearchBar(
                isSearchActive: true,
                query: ""
            ) == true
        )
        #expect(
            PanelInput.shouldShowSearchBar(
                isSearchActive: false,
                query: "backup"
            ) == true
        )
        #expect(
            PanelInput.shouldShowSearchBar(
                isSearchActive: false,
                query: "   "
            ) == false
        )
    }

    @Test func repeatIsAllowedOnlyForNavigation() {
        #expect(PanelInput.allowsRepeat(for: .character("j")) == true)
        #expect(PanelInput.allowsRepeat(for: .character("k")) == true)
        #expect(PanelInput.allowsRepeat(for: .downArrow) == true)
        #expect(PanelInput.allowsRepeat(for: .upArrow) == true)
        #expect(PanelInput.allowsRepeat(for: .character("x")) == false)
        #expect(PanelInput.allowsRepeat(for: .character("d")) == false)
        #expect(PanelInput.allowsRepeat(for: .character("o")) == false)
    }

    @Test func destructiveAndActionKeysExecuteOnKeyUp() {
        #expect(PanelInput.handlesOnKeyUp(for: .character("d")) == true)
        #expect(PanelInput.handlesOnKeyUp(for: .character("x")) == true)
        #expect(PanelInput.handlesOnKeyUp(for: .character("o")) == true)
        #expect(PanelInput.handlesOnKeyUp(for: .character("r")) == true)
        #expect(PanelInput.handlesOnKeyUp(for: .character("j")) == false)
        #expect(PanelInput.handlesOnKeyUp(for: .character("k")) == false)
        #expect(PanelInput.handlesOnKeyUp(for: .character("g")) == false)
    }

    @Test func singleFireDeduplicationAppliesOnlyToDestructiveAndOpenCommands() {
        #expect(PanelInput.isSingleFireListCommand(.done) == true)
        #expect(PanelInput.isSingleFireListCommand(.unsubscribe) == true)
        #expect(PanelInput.isSingleFireListCommand(.open) == true)
        #expect(PanelInput.isSingleFireListCommand(.undo) == true)
        #expect(PanelInput.isSingleFireListCommand(.moveDown) == false)
        #expect(PanelInput.isSingleFireListCommand(.moveUp) == false)
        #expect(PanelInput.isSingleFireListCommand(.forceRefresh) == false)
        #expect(PanelInput.singleFireCommandDeduplicationInterval == 0.2)
    }
}
