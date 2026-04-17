import SwiftUI
import AppKit

enum PanelInput {
    enum KeyInput: Equatable {
        case character(String)
        case space
        case controlF
        case controlB
        case controlD
        case controlU
        case commandDown
        case commandUp
        case downArrow
        case upArrow
        case escape
        case `return`
        case other
    }

    enum KeyboardCommand: Equatable {
        case moveDown
        case moveUp
        case pageDown
        case pageUp
        case halfPageDown
        case halfPageUp
        case jumpToBottom
        case jumpToTop
        case done
        case unsubscribe
        case open
        case copyURL
        case toggleChecked
        case toggleInboxMode
        case toggleGrouping
        case forceRefresh
        case activateSearch
        case deactivateSearch
        case closePanel
    }

    enum FocusDirective: Equatable {
        case unchanged
        case list
        case search
    }

    enum SearchFieldAction: Equatable {
        case submit
        case cancel
    }

    struct SearchFieldEffect: Equatable {
        let clearsQuery: Bool
        let keepsSearchActive: Bool
        let focusDirective: FocusDirective
    }

    struct KeyRouting: Equatable {
        let command: KeyboardCommand?
        let pendingG: Bool
        let focusDirective: FocusDirective
        let isHandled: Bool
    }

    static let singleFireCommandDeduplicationInterval: TimeInterval = 0.05

    static func notificationSummary(
        unreadCount: Int,
        totalCount: Int,
        mode: AppState.InboxMode
    ) -> String {
        switch mode {
        case .unread:
            return "\(unreadCount) unread"
        case .inbox:
            return "\(unreadCount) unread · \(totalCount) in inbox"
        }
    }

    static func searchFieldEffect(for action: SearchFieldAction) -> SearchFieldEffect {
        switch action {
        case .submit:
            return SearchFieldEffect(
                clearsQuery: false,
                keepsSearchActive: false,
                focusDirective: .list
            )
        case .cancel:
            return SearchFieldEffect(
                clearsQuery: true,
                keepsSearchActive: false,
                focusDirective: .list
            )
        }
    }

    static func shouldShowSearchBar(isSearchActive: Bool, query: String) -> Bool {
        if isSearchActive {
            return true
        }

        return !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func isSingleFireListCommand(_ command: KeyboardCommand) -> Bool {
        switch command {
        case .done, .unsubscribe, .open, .copyURL, .toggleChecked:
            return true
        case .moveDown,
             .moveUp,
             .pageDown,
             .pageUp,
             .halfPageDown,
             .halfPageUp,
             .jumpToBottom,
             .jumpToTop,
             .toggleInboxMode,
             .toggleGrouping,
             .forceRefresh,
             .activateSearch,
             .deactivateSearch,
             .closePanel:
            return false
        }
    }

    static func allowsRepeat(for input: KeyInput) -> Bool {
        switch input {
        case .character("j"), .character("k"), .space, .controlF, .controlB, .controlD, .controlU, .downArrow, .upArrow:
            return true
        case .character, .commandDown, .commandUp, .escape, .return, .other:
            return false
        }
    }

    static func handlesOnKeyUp(for input: KeyInput) -> Bool {
        switch input {
        case .character("d"),
             .character("x"),
             .character("o"),
             .character("y"),
             .character("u"),
             .character("a"),
             .character("s"),
             .character("r"),
             .character("/"),
             .escape,
             .return:
            return true
        case .character, .commandDown, .commandUp, .space, .controlF, .controlB, .controlD, .controlU, .downArrow, .upArrow, .other:
            return false
        }
    }

    static func keyInput(for press: KeyPress) -> KeyInput {
        if press.modifiers.contains(.control) {
            switch press.key {
            case KeyEquivalent("f"), KeyEquivalent("F"):
                return .controlF
            case KeyEquivalent("b"), KeyEquivalent("B"):
                return .controlB
            case KeyEquivalent("d"), KeyEquivalent("D"):
                return .controlD
            case KeyEquivalent("u"), KeyEquivalent("U"):
                return .controlU
            default:
                break
            }
        }

        switch press.key {
        case .downArrow:
            return .downArrow
        case .upArrow:
            return .upArrow
        case .escape:
            return .escape
        case .return:
            return .return
        case KeyEquivalent(" "):
            return .space
        case KeyEquivalent("g"):
            return .character("g")
        case KeyEquivalent("G"):
            return .character("G")
        case KeyEquivalent("j"):
            return .character("j")
        case KeyEquivalent("k"):
            return .character("k")
        case KeyEquivalent("d"):
            return .character("d")
        case KeyEquivalent("x"):
            return .character("x")
        case KeyEquivalent("o"):
            return .character("o")
        case KeyEquivalent("y"):
            return .character("y")
        case KeyEquivalent("u"):
            return .character("u")
        case KeyEquivalent("a"):
            return .character("a")
        case KeyEquivalent("s"):
            return .character("s")
        case KeyEquivalent("r"):
            return .character("r")
        case KeyEquivalent("/"):
            return .character("/")
        default:
            return .other
        }
    }

    static func keyInput(for event: NSEvent) -> KeyInput {
        if event.modifierFlags.contains(.command) {
            switch event.keyCode {
            case 125: return .commandDown
            case 126: return .commandUp
            default: break
            }
        }

        if event.modifierFlags.contains(.control) {
            switch event.charactersIgnoringModifiers {
            case "f", "F":
                return .controlF
            case "b", "B":
                return .controlB
            case "d", "D":
                return .controlD
            case "u", "U":
                return .controlU
            default:
                break
            }
        }

        switch event.keyCode {
        case 125:
            return .downArrow
        case 126:
            return .upArrow
        case 53:
            return .escape
        case 36, 76:
            return .return
        default:
            break
        }

        guard let characters = event.characters, !characters.isEmpty else {
            return .other
        }

        switch characters {
        case " ":
            return .space
        case "G":
            return .character("G")
        case "g":
            return .character("g")
        case "j":
            return .character("j")
        case "k":
            return .character("k")
        case "d":
            return .character("d")
        case "x":
            return .character("x")
        case "o":
            return .character("o")
        case "y":
            return .character("y")
        case "u":
            return .character("u")
        case "a":
            return .character("a")
        case "s":
            return .character("s")
        case "r":
            return .character("r")
        case "/":
            return .character("/")
        default:
            return .other
        }
    }

    static func debugName(for input: KeyInput) -> String {
        switch input {
        case .character(let value): return "char(\(value))"
        case .space: return "space"
        case .controlF: return "ctrl-f"
        case .controlB: return "ctrl-b"
        case .controlD: return "ctrl-d"
        case .controlU: return "ctrl-u"
        case .commandDown: return "cmd-down"
        case .commandUp: return "cmd-up"
        case .downArrow: return "down"
        case .upArrow: return "up"
        case .escape: return "escape"
        case .return: return "return"
        case .other: return "other"
        }
    }

    static func debugName(for command: KeyboardCommand) -> String {
        switch command {
        case .moveDown: return "moveDown"
        case .moveUp: return "moveUp"
        case .pageDown: return "pageDown"
        case .pageUp: return "pageUp"
        case .halfPageDown: return "halfPageDown"
        case .halfPageUp: return "halfPageUp"
        case .jumpToBottom: return "jumpToBottom"
        case .jumpToTop: return "jumpToTop"
        case .done: return "done"
        case .unsubscribe: return "unsubscribe"
        case .open: return "open"
        case .copyURL: return "copyURL"
        case .toggleChecked: return "toggleChecked"
        case .toggleInboxMode: return "toggleInboxMode"
        case .toggleGrouping: return "toggleGrouping"
        case .forceRefresh: return "forceRefresh"
        case .activateSearch: return "activateSearch"
        case .deactivateSearch: return "deactivateSearch"
        case .closePanel: return "closePanel"
        }
    }

    static func debugName(for phase: KeyPress.Phases) -> String {
        switch phase {
        case .down: return "down"
        case .repeat: return "repeat"
        case .up: return "up"
        default: return "other"
        }
    }

    static func routeKey(_ input: KeyInput, isSearchActive: Bool, pendingG: Bool) -> KeyRouting {
        if isSearchActive {
            switch input {
            case .escape:
                return KeyRouting(command: .deactivateSearch, pendingG: false, focusDirective: .list, isHandled: true)
            case .return:
                return KeyRouting(command: nil, pendingG: false, focusDirective: .list, isHandled: true)
            default:
                return KeyRouting(command: nil, pendingG: false, focusDirective: .unchanged, isHandled: false)
            }
        }

        if pendingG, input == .character("g") {
            return KeyRouting(command: .jumpToTop, pendingG: false, focusDirective: .unchanged, isHandled: true)
        }

        switch input {
        case .character("j"), .downArrow:
            return KeyRouting(command: .moveDown, pendingG: false, focusDirective: .unchanged, isHandled: true)
        case .character("k"), .upArrow:
            return KeyRouting(command: .moveUp, pendingG: false, focusDirective: .unchanged, isHandled: true)
        case .space, .controlF:
            return KeyRouting(command: .pageDown, pendingG: false, focusDirective: .unchanged, isHandled: true)
        case .controlB:
            return KeyRouting(command: .pageUp, pendingG: false, focusDirective: .unchanged, isHandled: true)
        case .controlD:
            return KeyRouting(command: .halfPageDown, pendingG: false, focusDirective: .unchanged, isHandled: true)
        case .controlU:
            return KeyRouting(command: .halfPageUp, pendingG: false, focusDirective: .unchanged, isHandled: true)
        case .character("G"), .commandDown:
            return KeyRouting(command: .jumpToBottom, pendingG: false, focusDirective: .unchanged, isHandled: true)
        case .commandUp:
            return KeyRouting(command: .jumpToTop, pendingG: false, focusDirective: .unchanged, isHandled: true)
        case .character("g"):
            return KeyRouting(command: nil, pendingG: true, focusDirective: .unchanged, isHandled: true)
        case .character("d"):
            return KeyRouting(command: .done, pendingG: false, focusDirective: .unchanged, isHandled: true)
        case .character("x"):
            return KeyRouting(command: .toggleChecked, pendingG: false, focusDirective: .unchanged, isHandled: true)
        case .character("o"), .return:
            return KeyRouting(command: .open, pendingG: false, focusDirective: .unchanged, isHandled: true)
        case .character("y"):
            return KeyRouting(command: .copyURL, pendingG: false, focusDirective: .unchanged, isHandled: true)
        case .character("u"):
            return KeyRouting(command: .unsubscribe, pendingG: false, focusDirective: .unchanged, isHandled: true)
        case .character("a"):
            return KeyRouting(command: .toggleInboxMode, pendingG: false, focusDirective: .unchanged, isHandled: true)
        case .character("s"):
            return KeyRouting(command: .toggleGrouping, pendingG: false, focusDirective: .unchanged, isHandled: true)
        case .character("r"):
            return KeyRouting(command: .forceRefresh, pendingG: false, focusDirective: .unchanged, isHandled: true)
        case .character("/"):
            return KeyRouting(command: .activateSearch, pendingG: false, focusDirective: .search, isHandled: true)
        case .escape:
            return KeyRouting(command: .closePanel, pendingG: false, focusDirective: .unchanged, isHandled: true)
        case .other:
            return KeyRouting(command: nil, pendingG: false, focusDirective: .unchanged, isHandled: false)
        case .character:
            return KeyRouting(command: nil, pendingG: false, focusDirective: .unchanged, isHandled: false)
        }
    }
}
