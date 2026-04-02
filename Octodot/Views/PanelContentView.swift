import SwiftUI

struct PanelContentView: View {
    @Bindable var appState: AppState
    let closePanel: () -> Void
    @State private var hasAppeared = false

    enum Focus: Hashable {
        case list
        case search
    }

    @FocusState private var focus: Focus?
    @State private var pendingG = false
    @State private var lastSingleFireCommand: PanelInput.KeyboardCommand?
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
                            PanelInput.notificationSummary(
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
            if PanelInput.shouldShowSearchBar(
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
            value: PanelInput.shouldShowSearchBar(
                isSearchActive: appState.isSearchActive,
                query: appState.searchQuery
            )
        )
    }

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        let input = PanelInput.keyInput(for: press)
        DebugTrace.log(
            "key phase=\(PanelInput.debugName(for: press.phase)) input=\(PanelInput.debugName(for: input)) " +
            "search=\(appState.isSearchActive) selected=\(appState.selectedNotificationID ?? "nil")"
        )
        if !appState.isSearchActive {
            if PanelInput.handlesOnKeyUp(for: input) {
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
                    if !PanelInput.allowsRepeat(for: input) {
                        return .handled
                    }
                case .up:
                    return .handled
                default:
                    return .handled
                }
            }
        }

        let routing = PanelInput.routeKey(
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
                DebugTrace.log("suppressed command=\(PanelInput.debugName(for: command))")
                return .handled
            }
            DebugTrace.log(
                "perform command=\(PanelInput.debugName(for: command)) selected.before=\(appState.selectedNotificationID ?? "nil") " +
                "visible.before=\(appState.filteredNotifications.map(\.id).joined(separator: ","))"
            )
            perform(command)
            DebugTrace.log(
                "performed command=\(PanelInput.debugName(for: command)) selected.after=\(appState.selectedNotificationID ?? "nil") " +
                "visible.after=\(appState.filteredNotifications.map(\.id).joined(separator: ","))"
            )
        }

        return routing.isHandled ? .handled : .ignored
    }

    private func commitSearch() {
        applySearchFieldEffect(PanelInput.searchFieldEffect(for: .submit))
    }

    private func cancelSearch() {
        applySearchFieldEffect(PanelInput.searchFieldEffect(for: .cancel))
    }

    private func applySearchFieldEffect(_ effect: PanelInput.SearchFieldEffect) {
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

    private func perform(_ command: PanelInput.KeyboardCommand) {
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

    private func shouldSuppressSingleFireCommand(_ command: PanelInput.KeyboardCommand) -> Bool {
        guard PanelInput.isSingleFireListCommand(command) else {
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

        return now.timeIntervalSince(lastSingleFireCommandAt) < PanelInput.singleFireCommandDeduplicationInterval
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

}
