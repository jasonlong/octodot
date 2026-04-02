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
        #expect(PanelContentView.routeKey(.character("m"), isSearchActive: false, pendingG: false) ==
            .init(command: .markRead, pendingG: false, focusDirective: .unchanged, isHandled: true))
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
}
