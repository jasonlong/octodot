import SwiftUI

struct SettingsView: View {
    enum Tab: String, Hashable {
        case general
        case shortcuts
        case account
        case about

        var title: String {
            switch self {
            case .general: "General"
            case .shortcuts: "Shortcuts"
            case .account: "Account"
            case .about: "About"
            }
        }

        var systemImage: String {
            switch self {
            case .general: "gearshape"
            case .shortcuts: "keyboard"
            case .account: "person.crop.circle"
            case .about: "info.circle"
            }
        }
    }

    @Bindable var appState: AppState
    @Bindable var preferences: AppPreferences
    var updateChecker: UpdateChecker
    @State private var selectedTab: Tab = .general

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(selection: $selectedTab)

            Divider()

            Group {
                switch selectedTab {
                case .general:
                    GeneralSettingsPane(preferences: preferences)
                case .shortcuts:
                    ShortcutsSettingsPane(preferences: preferences)
                case .account:
                    AccountSettingsPane(appState: appState)
                case .about:
                    AboutSettingsPane(updateChecker: updateChecker)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 600, height: 560)
    }
}

private struct SettingsTabBar: View {
    @Binding var selection: SettingsView.Tab

    var body: some View {
        HStack(spacing: 12) {
            Spacer()

            ForEach([
                SettingsView.Tab.general,
                .shortcuts,
                .account,
                .about
            ], id: \.self) { tab in
                SettingsTabItem(
                    tab: tab,
                    isSelected: selection == tab
                ) {
                    withAnimation(.easeInOut(duration: 0.14)) {
                        selection = tab
                    }
                }
            }

            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct SettingsTabItem: View {
    let tab: SettingsView.Tab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 18, weight: .medium))
                Text(tab.title)
                    .font(.system(size: 11.5, weight: .medium))
            }
            .frame(width: 96, height: 56)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(SettingsTabButtonStyle(isSelected: isSelected))
        .focusEffectDisabled()
        .accessibilityElement()
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SettingsTabButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(backgroundColor(isPressed: configuration.isPressed))
            )
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return Color.accentColor.opacity(isSelected ? 0.20 : 0.08)
        }
        return isSelected ? Color.accentColor.opacity(0.14) : Color.clear
    }
}

private struct AccountSettingsPane: View {
    @Bindable var appState: AppState
    @State private var tokenInput = ""
    @State private var errorMessage: String?
    @State private var isSaving = false

    var body: some View {
        Form {
            Section("GitHub Account") {
                LabeledContent("Account") {
                    Text(statusText)
                        .foregroundStyle(.secondary)
                }

                SecureField("Personal Access Token", text: $tokenInput, prompt: Text("ghp_..."))
                    .textFieldStyle(.roundedBorder)

                Text("Use a classic Personal Access Token with the notifications and repo scopes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                HStack {
                    Button(isSaving ? "Saving…" : (appState.isSignedIn ? "Update Token" : "Sign In"), action: submit)
                        .disabled(tokenInput.isEmpty || isSaving)

                    if appState.isSignedIn {
                        Button("Sign Out", role: .destructive) {
                            appState.signOut()
                            tokenInput = ""
                            errorMessage = nil
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var statusText: String {
        switch appState.authStatus {
        case .signedOut:
            "Signed out"
        case .signedIn(let username):
            username.isEmpty ? "Signed in" : "@\(username)"
        }
    }

    private func submit() {
        isSaving = true
        errorMessage = nil

        Task {
            do {
                try await appState.submitToken(tokenInput)
                isSaving = false
                tokenInput = ""
            } catch {
                isSaving = false
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct GeneralSettingsPane: View {
    @Bindable var preferences: AppPreferences

    var body: some View {
        Form {
            Section("Theme") {
                Picker("Appearance", selection: $preferences.appearanceMode) {
                    ForEach(AppPreferences.AppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text("The panel and settings window will follow this appearance.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: $preferences.launchAtLogin)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ShortcutsSettingsPane: View {
    @Bindable var preferences: AppPreferences
    private let vimColumnWidth: CGFloat = 138
    private let standardColumnWidth: CGFloat = 120

    private struct BindingRow: Identifiable {
        let id: String
        let action: String
        let vim: String
        let standard: String
    }

    private let bindingRows: [BindingRow] = [
        .init(id: "move", action: "Move selection", vim: "j / k", standard: "Up / Down"),
        .init(id: "page-down", action: "Page down", vim: "ctrl-f / space", standard: "Page Down"),
        .init(id: "page-up", action: "Page up", vim: "ctrl-b", standard: "Page Up"),
        .init(id: "half-down", action: "Half page down", vim: "ctrl-d", standard: "—"),
        .init(id: "half-up", action: "Half page up", vim: "ctrl-u", standard: "—"),
        .init(id: "top", action: "Jump to top", vim: "gg", standard: "Cmd-Up / Home"),
        .init(id: "bottom", action: "Jump to bottom", vim: "G", standard: "Cmd-Down / End"),
        .init(id: "open", action: "Open selected", vim: "o", standard: "Return"),
        .init(id: "done", action: "Done", vim: "d", standard: "—"),
        .init(id: "unsub", action: "Unsubscribe", vim: "x", standard: "—"),
        .init(id: "undo", action: "Undo pending action", vim: "u", standard: "Cmd-Z"),
        .init(id: "copy", action: "Copy URL", vim: "y", standard: "—"),
        .init(id: "search", action: "Focus search", vim: "/", standard: "—"),
        .init(id: "search-submit", action: "Apply search and return to list", vim: "return / tab", standard: "Return / Tab"),
        .init(id: "search-cancel", action: "Cancel search", vim: "esc", standard: "Escape"),
        .init(id: "refresh", action: "Refresh", vim: "r", standard: "—"),
        .init(id: "mode", action: "Toggle Inbox / Unread", vim: "a", standard: "—"),
        .init(id: "group", action: "Toggle repo grouping", vim: "s", standard: "—"),
        .init(id: "close", action: "Close panel", vim: "esc", standard: "Escape"),
    ]

    var body: some View {
        Form {
            Section("Global Shortcut") {
                SettingsControlRow(
                    title: "Toggle Octodot",
                    description: "Click the recorder, then press a key combination. Escape cancels. A modifier key is required."
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        HotkeyRecorderView(shortcut: $preferences.globalShortcut)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if let errorMessage = preferences.globalShortcutErrorMessage {
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            Section("Panel Keybindings") {
                VStack(alignment: .leading, spacing: 0) {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                        GridRow {
                            tableHeader("Action")
                            tableHeader("Vim")
                            tableHeader("Standard")
                        }

                        ForEach(bindingRows) { row in
                            Divider()
                                .gridCellColumns(3)

                            GridRow(alignment: .top) {
                                Text(row.action)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .lineLimit(1)

                                shortcutText(row.vim)
                                    .frame(width: vimColumnWidth, alignment: .leading)

                                shortcutText(row.standard)
                                    .frame(width: standardColumnWidth, alignment: .leading)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func tableHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func shortcutText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(text == "—" ? .tertiary : .primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lineLimit(1)
    }
}

private struct AboutSettingsPane: View {
    var updateChecker: UpdateChecker

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
        #if DEBUG
        return "\(version)-dev"
        #else
        return version
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 16) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 96, height: 96)
                }

                VStack(spacing: 4) {
                    Text("Octodot")
                        .font(.system(size: 20, weight: .semibold))

                    Text("v\(appVersion)")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 8) {
                    Button {
                        updateChecker.checkForUpdatesNow()
                    } label: {
                        HStack(spacing: 6) {
                            if updateChecker.isChecking {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                            Text("Check for Updates")
                        }
                        .frame(width: 180)
                    }
                    .disabled(updateChecker.isChecking)

                    Group {
                        if let version = updateChecker.availableVersion {
                            Text("v\(version) is available")
                                .foregroundStyle(.green)
                        } else if updateChecker.showingUpToDate {
                            Text("You're up to date")
                                .foregroundStyle(.secondary)
                        } else {
                            Text(" ")
                        }
                    }
                    .font(.system(size: 12))
                }

                HStack(spacing: 6) {
                    Text("Made by [Jason Long](https://github.com/jasonlong)")
                    Text("·")
                    Text("[GitHub repository](https://github.com/jasonlong/octodot)")
                }
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .tint(.primary)

                Text("Icons by [GitHub Octicons](https://github.com/primer/octicons)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .tint(.secondary)
            }
            .frame(maxWidth: .infinity)

            Spacer()
        }
    }
}

private struct SettingsControlRow<Control: View>: View {
    private let labelWidth: CGFloat = 128

    let title: String
    let description: String
    let control: Control

    init(
        title: String,
        description: String,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.description = description
        self.control = control()
    }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
            GridRow(alignment: .center) {
                Text(title)
                    .frame(width: labelWidth, alignment: .leading)

                control
            }

            GridRow {
                Color.clear
                    .frame(width: labelWidth, height: 0)

                Text(description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
