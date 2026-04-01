import SwiftUI

struct PanelContentView: View {
    @Bindable var appState: AppState
    let closePanel: () -> Void

    enum Focus: Hashable {
        case list
        case search
    }

    @FocusState private var focus: Focus?

    var body: some View {
        Group {
            if appState.isSignedIn {
                notificationView
            } else {
                TokenEntryView(appState: appState)
            }
        }
        .frame(width: 380, height: 500)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .ignoresSafeArea()
    }

    private var notificationView: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Notifications")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer()

                if appState.isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    let unreadCount = appState.filteredNotifications.filter(\.isUnread).count
                    Text("\(unreadCount) unread")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Error banner
            if let error = appState.errorMessage {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                    Text(error)
                        .font(.system(size: 11))
                        .lineLimit(1)
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
            }

            // Search bar (conditional)
            if appState.isSearchActive {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    TextField("Filter notifications…", text: $appState.searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($focus, equals: .search)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.05))
                .transition(.move(edge: .top).combined(with: .opacity))
                .onChange(of: appState.searchQuery) { _, _ in
                    appState.clampSelection()
                }
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
                    selectedIndex: appState.selectedIndex,
                    onSelect: { appState.selectedIndex = $0 }
                )
            }

            Divider().opacity(0.5)

            // Footer
            HStack(spacing: 12) {
                shortcutHint(key: "j/k", label: "navigate")
                shortcutHint(key: "e", label: "done")
                shortcutHint(key: "o", label: "open")
                shortcutHint(key: "/", label: "search")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
        .focusable()
        .focused($focus, equals: .list)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in
            handleKeyPress(press)
        }
        .onAppear {
            focus = .list
            appState.refresh()
        }
        .onChange(of: appState.isPanelVisible) { _, visible in
            if visible {
                focus = .list
                appState.refresh()
            }
        }
        .animation(.easeOut(duration: 0.15), value: appState.isSearchActive)
    }

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        if appState.isSearchActive {
            switch press.key {
            case .escape:
                appState.deactivateSearch()
                focus = .list
                return .handled
            case .return:
                focus = .list
                return .handled
            default:
                return .ignored
            }
        }

        switch press.key {
        case KeyEquivalent("j"), .downArrow:
            appState.moveDown()
            return .handled
        case KeyEquivalent("k"), .upArrow:
            appState.moveUp()
            return .handled
        case KeyEquivalent("e"):
            appState.markReadAndAdvance()
            return .handled
        case KeyEquivalent("o"), .return:
            appState.openInBrowser()
            return .handled
        case KeyEquivalent("r"):
            appState.refresh()
            return .handled
        case KeyEquivalent("/"):
            appState.activateSearch()
            focus = .search
            return .handled
        case .escape:
            closePanel()
            return .handled
        default:
            return .ignored
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
