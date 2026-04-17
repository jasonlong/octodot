import AppKit
import SwiftUI

struct PanelContentView: View {
    @Bindable var appState: AppState
    var updateChecker: UpdateChecker
    let closePanel: () -> Void
    let showSettings: () -> Void
    @State private var hasAppeared = false
    @State private var windowFocusBridge = PanelWindowFocusBridge()
    @State private var isSearchFieldFocused = false
    @State private var pendingG = false
    @State private var lastSingleFireCommand: PanelInput.KeyboardCommand?
    @State private var lastSingleFireCommandAt = Date.distantPast
    @State private var suppressedKeyUpInput: PanelInput.KeyInput?

    private var displayedSelectedNotificationID: String? {
        isSearchFieldFocused ? nil : appState.selectedNotificationID
    }

    private var summaryText: Text {
        let base = Text(
            PanelInput.notificationSummary(
                unreadCount: appState.panelUnreadCount,
                totalCount: appState.notifications.count,
                mode: appState.inboxMode
            )
        )
        .foregroundColor(.secondary)

        let selectedCount = appState.checkedThreadIDs.count
        guard selectedCount > 0 else { return base }
        return base + Text(" · \(selectedCount) selected").foregroundColor(.accentColor)
    }

    var body: some View {
        Group {
            if appState.isSignedIn {
                notificationView
            } else {
                TokenEntryView(appState: appState)
            }
        }
        .background(
            PanelWindowFocusReader(
                bridge: windowFocusBridge,
                onKeyEvent: handleAppKitKeyEvent
            )
        )
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
                    HStack(spacing: 4) {
                        Text("Notifications")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                        #if DEBUG
                        Text("[DEV]")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        #endif
                    }

                    Spacer()

                    Picker(
                        "Inbox mode",
                        selection: Binding(
                            get: { appState.inboxMode },
                            set: { appState.setInboxMode($0) }
                        )
                    ) {
                        Text("Inbox").tag(AppState.InboxMode.inbox)
                        Text("Unread").tag(AppState.InboxMode.unread)
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
                        summaryText
                            .font(.system(size: 11))
                    }

                    Spacer()
                }
                .frame(height: 16, alignment: .center)
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
                    isFocused: isSearchFieldFocused,
                    onSubmit: commitSearch,
                    onCancel: cancelSearch
                )
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
                    selectedNotificationID: displayedSelectedNotificationID,
                    checkedIDs: appState.checkedThreadIDs,
                    groupByRepo: appState.groupByRepo,
                    onSelect: { appState.selectNotification(id: $0) },
                    onToggleCheck: { appState.toggleChecked(id: $0) },
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
            } else if let warning = appState.warningMessage {
                HStack {
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 10))
                        Text(warning)
                            .font(.system(size: 11))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.yellow)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.yellow.opacity(0.08), in: Capsule())
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
            } else if updateChecker.availableVersion != nil || updateChecker.installState != .idle || updateChecker.showingUpToDate {
                UpdateBanner(updateChecker: updateChecker)
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
            }

            // Footer
            HStack(spacing: 10) {
                shortcutHint(key: "j/k", label: "nav")
                shortcutHint(key: "d", label: "done")
                shortcutHint(key: "u", label: "unsub")
                shortcutHint(key: "o", label: "open")
                shortcutHint(key: "/", label: "search")

                Spacer()

                Menu {
                    Button("Check for Updates…") {
                        updateChecker.checkForUpdatesNow()
                    }
                    Button("Settings…") {
                        showSettings()
                    }
                    Divider()
                    Button("Quit Octodot") {
                        NSApp.terminate(nil)
                    }
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 10))
                        .foregroundStyle(.quaternary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
        .onAppear {
            guard !hasAppeared else { return }
            hasAppeared = true
            focusListAndRefresh()
            updateChecker.checkForUpdatesIfNeeded()
        }
        .onChange(of: appState.isPanelVisible) { _, visible in
            if visible {
                focusListAndRefresh()
                updateChecker.checkForUpdatesIfNeeded()
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

    private func handleAppKitKeyEvent(_ event: NSEvent, phase: PanelKeyEventPhase) -> Bool {
        let input = PanelInput.keyInput(for: event)
        if phase == .up, suppressedKeyUpInput == input {
            suppressedKeyUpInput = nil
            DebugTrace.log("suppressed trailing keyUp input=\(PanelInput.debugName(for: input))")
            return true
        }
        DebugTrace.log(
            "key phase=\(debugName(for: phase)) input=\(PanelInput.debugName(for: input)) " +
            "search=\(appState.isSearchActive) selected=\(appState.selectedNotificationID ?? "nil")"
        )
        if !appState.isSearchActive {
            if PanelInput.handlesOnKeyUp(for: input) {
                switch phase {
                case .down, .repeat:
                    return true
                case .up:
                    break
                }
            } else {
                switch phase {
                case .down:
                    break
                case .repeat:
                    if !PanelInput.allowsRepeat(for: input) {
                        return true
                    }
                case .up:
                    return true
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
            focusListSoon()
        case .search:
            focusSearchSoon()
        }

        if let command = routing.command {
            if shouldSuppressSingleFireCommand(command) {
                DebugTrace.log("suppressed command=\(PanelInput.debugName(for: command))")
                return true
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

        return routing.isHandled
    }

    private func commitSearch() {
        suppressedKeyUpInput = .return
        applySearchFieldEffect(PanelInput.searchFieldEffect(for: .submit))
    }

    private func cancelSearch() {
        suppressedKeyUpInput = .escape
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
            isSearchFieldFocused = false
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
        case .pageDown:
            appState.pageDown()
        case .pageUp:
            appState.pageUp()
        case .halfPageDown:
            appState.halfPageDown()
        case .halfPageUp:
            appState.halfPageUp()
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
        case .toggleChecked:
            appState.toggleChecked()
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
            isSearchFieldFocused = false
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
            windowFocusBridge.focusHostingView()
            isSearchFieldFocused = false
            appState.refresh(force: appState.inboxMode.includesReadNotifications)
        }
    }

    private func focusListSoon() {
        Task { @MainActor in
            await Task.yield()
            windowFocusBridge.focusHostingView()
            isSearchFieldFocused = false
        }
    }

    private func focusSearchSoon() {
        Task { @MainActor in
            await Task.yield()
            isSearchFieldFocused = true
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
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    private func debugName(for phase: PanelKeyEventPhase) -> String {
        switch phase {
        case .down: return "down"
        case .repeat: return "repeat"
        case .up: return "up"
        }
    }
}

private struct UpdateBanner: View {
    var updateChecker: UpdateChecker

    private static let isHomebrewInstall: Bool = {
        let path = Bundle.main.bundlePath
        return path.contains("/Homebrew/") || path.contains("/Caskroom/")
    }()

    private var bannerColor: Color {
        if updateChecker.showingUpToDate { return .secondary }
        if updateChecker.installState == .idle { return .green }
        return .secondary
    }

    var body: some View {
        HStack {
            Spacer()
            HStack(spacing: 6) {
                switch updateChecker.installState {
                case .idle where updateChecker.showingUpToDate:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                    Text("No updates available")
                        .font(.system(size: 11))
                        .lineLimit(1)

                case .idle where Self.isHomebrewInstall:
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 10))
                    if let version = updateChecker.availableVersion {
                        Text("v\(version) available · brew upgrade octodot")
                            .font(.system(size: 11))
                            .lineLimit(1)
                    }
                    Button {
                        updateChecker.dismissUpdate()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .opacity(0.6)

                case .idle:
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 10))
                    if let version = updateChecker.availableVersion {
                        Text("v\(version) available")
                            .font(.system(size: 11))
                            .lineLimit(1)
                    }
                    Button("Update") {
                        updateChecker.installUpdate()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .underline()
                    Button {
                        updateChecker.dismissUpdate()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .opacity(0.6)

                case .downloading(let progress):
                    ProgressView(value: progress)
                        .frame(width: 60)
                        .controlSize(.small)
                    Text("Downloading…")
                        .font(.system(size: 11))
                        .lineLimit(1)

                case .installing:
                    ProgressView()
                        .controlSize(.small)
                    Text("Installing…")
                        .font(.system(size: 11))
                        .lineLimit(1)

                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                    Text(message)
                        .font(.system(size: 11))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(bannerColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(bannerColor.opacity(0.08), in: Capsule())
        }
    }
}

private enum PanelKeyEventPhase {
    case down
    case `repeat`
    case up
}

@MainActor
private final class PanelWindowFocusBridge {
    weak var hostingView: PanelKeyResponderView?

    func focusHostingView() {
        guard let hostingView, let window = hostingView.window else { return }
        window.makeFirstResponder(hostingView)
    }
}

private struct PanelWindowFocusReader: NSViewRepresentable {
    let bridge: PanelWindowFocusBridge
    let onKeyEvent: (NSEvent, PanelKeyEventPhase) -> Bool

    func makeNSView(context: Context) -> PanelKeyResponderView {
        let view = PanelKeyResponderView()
        view.keyHandler = onKeyEvent
        DispatchQueue.main.async {
            bridge.hostingView = view
        }
        return view
    }

    func updateNSView(_ nsView: PanelKeyResponderView, context: Context) {
        nsView.keyHandler = onKeyEvent
        DispatchQueue.main.async {
            bridge.hostingView = nsView
        }
    }
}

private final class PanelKeyResponderView: NSView {
    var keyHandler: ((NSEvent, PanelKeyEventPhase) -> Bool)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let phase: PanelKeyEventPhase = event.isARepeat ? .repeat : .down
        if keyHandler?(event, phase) == true {
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if keyHandler?(event, .up) == true {
            return
        }
        super.keyUp(with: event)
    }
}
