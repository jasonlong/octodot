import SwiftUI

struct PanelContentView: View {
    @Bindable var appState: AppState
    let closePanel: () -> Void
    @State private var hasAppeared = false

    enum Focus: Hashable {
        case list
        case search
    }

    enum KeyInput: Equatable {
        case character(String)
        case downArrow
        case upArrow
        case escape
        case `return`
        case other
    }

    enum KeyboardCommand: Equatable {
        case moveDown
        case moveUp
        case jumpToBottom
        case jumpToTop
        case done
        case unsubscribe
        case open
        case copyURL
        case undo
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

    @FocusState private var focus: Focus?
    @State private var pendingG = false
    @State private var lastSingleFireCommand: KeyboardCommand?
    @State private var lastSingleFireCommandAt = Date.distantPast

    var body: some View {
        Group {
            if appState.isSignedIn {
                notificationView
            } else {
                TokenEntryView(appState: appState)
            }
        }
        .frame(width: 380, height: 500)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .ignoresSafeArea()
    }

    private var notificationView: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                HStack(alignment: .center, spacing: 10) {
                    Text("Notifications")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)

                    Spacer()

                    Picker(
                        "Inbox mode",
                        selection: Binding(
                            get: { appState.inboxMode },
                            set: { appState.setInboxMode($0) }
                        )
                    ) {
                        Text("Unread").tag(AppState.InboxMode.unread)
                        Text("All").tag(AppState.InboxMode.all)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .frame(width: 104)
                }

                HStack {
                    if appState.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(
                            Self.notificationSummary(
                                unreadCount: appState.unreadNotificationCount,
                                totalCount: appState.notifications.count,
                                mode: appState.inboxMode
                            )
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Search bar (conditional)
            if Self.shouldShowSearchBar(
                isSearchActive: appState.isSearchActive,
                query: appState.searchQuery
            ) {
                SearchBarView(
                    query: $appState.searchQuery,
                    onSubmit: commitSearch,
                    onCancel: cancelSearch
                )
                    .focused($focus, equals: .search)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            Divider().opacity(0.5)

            // Notification list or empty state
            if appState.filteredNotifications.isEmpty && !appState.isLoading {
                Spacer()
                VStack(spacing: 6) {
                    Image(systemName: appState.searchQuery.isEmpty ? "bell.slash" : "magnifyingglass")
                        .font(.system(size: 24))
                        .foregroundStyle(.tertiary)
                    Text(appState.searchQuery.isEmpty ? "All caught up" : "No matches")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                NotificationListView(
                    notifications: appState.filteredNotifications,
                    selectedNotificationID: appState.selectedNotificationID,
                    groupByRepo: appState.groupByRepo,
                    onSelect: { appState.selectNotification(id: $0) },
                    onNotificationVisible: { appState.notificationBecameVisible(id: $0) }
                )
            }

            Divider().opacity(0.5)

            if let error = appState.errorMessage {
                HStack {
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                        Text(error)
                            .font(.system(size: 11))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.orange.opacity(0.08), in: Capsule())
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
            }

            // Footer
            HStack(spacing: 10) {
                shortcutHint(key: "j/k", label: "nav")
                shortcutHint(key: "d", label: "done")
                shortcutHint(key: "x", label: "unsub")
                shortcutHint(key: "u", label: "undo")
                shortcutHint(key: "o", label: "open")
                shortcutHint(key: "/", label: "search")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
        .focusable()
        .focused($focus, equals: .list)
        .focusEffectDisabled()
        .onKeyPress(phases: [.down, .repeat, .up]) { press in
            handleKeyPress(press)
        }
        .onAppear {
            guard !hasAppeared else { return }
            hasAppeared = true
            focusListAndRefresh()
        }
        .onChange(of: appState.isPanelVisible) { _, visible in
            if visible {
                focusListAndRefresh()
            }
        }
        .animation(
            .easeOut(duration: 0.15),
            value: Self.shouldShowSearchBar(
                isSearchActive: appState.isSearchActive,
                query: appState.searchQuery
            )
        )
    }

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        let input = Self.keyInput(for: press)
        DebugTrace.log(
            "key phase=\(Self.debugName(for: press.phase)) input=\(Self.debugName(for: input)) " +
            "search=\(appState.isSearchActive) selected=\(appState.selectedNotificationID ?? "nil")"
        )
        if !appState.isSearchActive {
            if Self.handlesOnKeyUp(for: input) {
                switch press.phase {
                case .down, .repeat:
                    return .handled
                case .up:
                    break
                default:
                    return .handled
                }
            } else {
                switch press.phase {
                case .down:
                    break
                case .repeat:
                    if !Self.allowsRepeat(for: input) {
                        return .handled
                    }
                case .up:
                    return .handled
                default:
                    return .handled
                }
            }
        }

        let routing = Self.routeKey(
            input,
            isSearchActive: appState.isSearchActive,
            pendingG: pendingG
        )
        pendingG = routing.pendingG

        switch routing.focusDirective {
        case .unchanged:
            break
        case .list:
            focus = .list
        case .search:
            focus = .search
        }

        if let command = routing.command {
            if shouldSuppressSingleFireCommand(command) {
                DebugTrace.log("suppressed command=\(Self.debugName(for: command))")
                return .handled
            }
            DebugTrace.log(
                "perform command=\(Self.debugName(for: command)) selected.before=\(appState.selectedNotificationID ?? "nil") " +
                "visible.before=\(appState.filteredNotifications.map(\.id).joined(separator: ","))"
            )
            perform(command)
            DebugTrace.log(
                "performed command=\(Self.debugName(for: command)) selected.after=\(appState.selectedNotificationID ?? "nil") " +
                "visible.after=\(appState.filteredNotifications.map(\.id).joined(separator: ","))"
            )
        }

        return routing.isHandled ? .handled : .ignored
    }

    private func commitSearch() {
        applySearchFieldEffect(Self.searchFieldEffect(for: .submit))
    }

    private func cancelSearch() {
        applySearchFieldEffect(Self.searchFieldEffect(for: .cancel))
    }

    private func applySearchFieldEffect(_ effect: SearchFieldEffect) {
        if effect.clearsQuery {
            appState.deactivateSearch()
        } else if !effect.keepsSearchActive {
            appState.isSearchActive = false
        }

        switch effect.focusDirective {
        case .unchanged:
            break
        case .list:
            focus = nil
            focusListSoon()
        case .search:
            focusSearchSoon()
        }
    }

    private func perform(_ command: KeyboardCommand) {
        switch command {
        case .moveDown:
            appState.moveDown()
        case .moveUp:
            appState.moveUp()
        case .jumpToBottom:
            appState.jumpToBottom()
        case .jumpToTop:
            appState.jumpToTop()
        case .done:
            appState.done()
        case .unsubscribe:
            appState.unsubscribeFromThread()
        case .open:
            if appState.openInBrowser() {
                appState.flushPendingActions()
                closePanel()
            }
        case .copyURL:
            appState.copyURL()
        case .undo:
            appState.undo()
        case .toggleInboxMode:
            appState.toggleInboxMode()
        case .toggleGrouping:
            appState.toggleGroupByRepo()
        case .forceRefresh:
            appState.refresh(force: true)
        case .activateSearch:
            appState.activateSearch()
            focusSearchSoon()
        case .deactivateSearch:
            appState.deactivateSearch()
            focus = nil
            focusListSoon()
        case .closePanel:
            appState.flushPendingActions()
            closePanel()
        }
    }

    private func shouldSuppressSingleFireCommand(_ command: KeyboardCommand) -> Bool {
        guard Self.isSingleFireListCommand(command) else {
            return false
        }

        let now = Date()
        defer {
            lastSingleFireCommand = command
            lastSingleFireCommandAt = now
        }

        guard lastSingleFireCommand == command else {
            return false
        }

        return now.timeIntervalSince(lastSingleFireCommandAt) < Self.singleFireCommandDeduplicationInterval
    }

    private func focusListAndRefresh() {
        Task { @MainActor in
            await Task.yield()
            focus = .list
            appState.refresh(force: appState.inboxMode.includesReadNotifications)
        }
    }

    private func focusListSoon() {
        Task { @MainActor in
            await Task.yield()
            focus = .list
        }
    }

    private func focusSearchSoon() {
        Task { @MainActor in
            await Task.yield()
            focus = .search
        }
    }

    private func shortcutHint(key: String, label: String) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.white.opacity(0.1))
                .cornerRadius(3)

            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    static func notificationSummary(
        unreadCount: Int,
        totalCount: Int,
        mode: AppState.InboxMode
    ) -> String {
        switch mode {
        case .unread:
            return "\(unreadCount) unread"
        case .all:
            return "\(unreadCount) unread · \(totalCount) total"
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

    static let singleFireCommandDeduplicationInterval: TimeInterval = 0.2

    static func isSingleFireListCommand(_ command: KeyboardCommand) -> Bool {
        switch command {
        case .done, .unsubscribe, .open, .copyURL, .undo:
            return true
        case .moveDown,
             .moveUp,
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
        case .character("j"), .character("k"), .downArrow, .upArrow:
            return true
        case .character, .escape, .return, .other:
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
        case .character, .downArrow, .upArrow, .other:
            return false
        }
    }

    static func keyInput(for press: KeyPress) -> KeyInput {
        switch press.key {
        case .downArrow:
            return .downArrow
        case .upArrow:
            return .upArrow
        case .escape:
            return .escape
        case .return:
            return .return
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

    static func debugName(for input: KeyInput) -> String {
        switch input {
        case .character(let value): return "char(\(value))"
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
        case .jumpToBottom: return "jumpToBottom"
        case .jumpToTop: return "jumpToTop"
        case .done: return "done"
        case .unsubscribe: return "unsubscribe"
        case .open: return "open"
        case .copyURL: return "copyURL"
        case .undo: return "undo"
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

        if pendingG {
            if input == .character("g") {
                return KeyRouting(command: .jumpToTop, pendingG: false, focusDirective: .unchanged, isHandled: true)
            }
        }

        switch input {
        case .character("j"), .downArrow:
            return KeyRouting(command: .moveDown, pendingG: false, focusDirective: .unchanged, isHandled: true)
        case .character("k"), .upArrow:
            return KeyRouting(command: .moveUp, pendingG: false, focusDirective: .unchanged, isHandled: true)
        case .character("G"):
            return KeyRouting(command: .jumpToBottom, pendingG: false, focusDirective: .unchanged, isHandled: true)
        case .character("g"):
            return KeyRouting(command: nil, pendingG: true, focusDirective: .unchanged, isHandled: true)
        case .character("d"):
            return KeyRouting(command: .done, pendingG: false, focusDirective: .unchanged, isHandled: true)
        case .character("x"):
            return KeyRouting(command: .unsubscribe, pendingG: false, focusDirective: .unchanged, isHandled: true)
        case .character("o"), .return:
            return KeyRouting(command: .open, pendingG: false, focusDirective: .unchanged, isHandled: true)
        case .character("y"):
            return KeyRouting(command: .copyURL, pendingG: false, focusDirective: .unchanged, isHandled: true)
        case .character("u"):
            return KeyRouting(command: .undo, pendingG: false, focusDirective: .unchanged, isHandled: true)
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
