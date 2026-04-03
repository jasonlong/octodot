import SwiftUI

struct SettingsView: View {
    enum Tab: String, Hashable {
        case account
        case appearance
        case shortcuts

        var title: String {
            switch self {
            case .account:
                "Account"
            case .appearance:
                "Appearance"
            case .shortcuts:
                "Shortcuts"
            }
        }

        var systemImage: String {
            switch self {
            case .account:
                "person.crop.circle"
            case .appearance:
                "circle.lefthalf.filled"
            case .shortcuts:
                "keyboard"
            }
        }
    }

    @Bindable var appState: AppState
    @Bindable var preferences: AppPreferences
    @AppStorage("SettingsView.selectedTab") private var selectedTabRawValue = Tab.account.rawValue

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(selection: selection)

            Divider()

            Group {
                switch selection.wrappedValue {
                case .account:
                    AccountSettingsPane(appState: appState)
                case .appearance:
                    AppearanceSettingsPane(preferences: preferences)
                case .shortcuts:
                    ShortcutsSettingsPane(preferences: preferences)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 540, height: 390)
    }

    private var selection: Binding<Tab> {
        Binding(
            get: { Tab(rawValue: selectedTabRawValue) ?? .account },
            set: { selectedTabRawValue = $0.rawValue }
        )
    }
}

private struct SettingsTabBar: View {
    @Binding var selection: SettingsView.Tab

    var body: some View {
        HStack(spacing: 12) {
            Spacer()

            ForEach([
                SettingsView.Tab.account,
                .appearance,
                .shortcuts
            ], id: \.self) { tab in
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 18, weight: .medium))
                        Text(tab.title)
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .frame(width: 96, height: 56)
                    .foregroundStyle(selection == tab ? Color.accentColor : Color.primary)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(selection == tab ? Color.accentColor.opacity(0.14) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(Color(nsColor: .windowBackgroundColor))
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

                SecureField("ghp_...", text: $tokenInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                Text("Use a classic Personal Access Token with the notifications scope.")
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

private struct AppearanceSettingsPane: View {
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
        }
        .formStyle(.grouped)
    }
}

private struct ShortcutsSettingsPane: View {
    @Bindable var preferences: AppPreferences

    var body: some View {
        Form {
            Section("Global Shortcut") {
                SettingsControlRow(
                    title: "Toggle Octodot",
                    description: "Click the recorder, then press a key combination. Escape cancels. A modifier key is required."
                ) {
                    HotkeyRecorderView(shortcut: $preferences.globalShortcut)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Section("Panel Keybindings") {
                shortcutRow("j / k", "Move selection")
                shortcutRow("gg / G", "Jump to top or bottom")
                shortcutRow("o", "Open and mark read")
                shortcutRow("d", "Done")
                shortcutRow("x", "Unsubscribe")
                shortcutRow("u", "Undo pending actions")
                shortcutRow("/", "Search")
                shortcutRow("r", "Refresh")
                shortcutRow("a", "Toggle Inbox / Unread")
                shortcutRow("Esc", "Exit search or close panel")
            }
        }
        .formStyle(.grouped)
    }

    private func shortcutRow(_ shortcut: String, _ description: String) -> some View {
        LabeledContent(shortcut) {
            Text(description)
                .foregroundStyle(.secondary)
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
