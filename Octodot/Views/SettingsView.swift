import SwiftUI

struct SettingsView: View {
    enum Tab: String, Hashable {
        case account
        case appearance
        case shortcuts
    }

    @Bindable var appState: AppState
    @Bindable var preferences: AppPreferences
    @Binding var selection: Tab

    var body: some View {
        TabView(selection: $selection) {
            AccountSettingsPane(appState: appState)
                .tag(Tab.account)
                .tabItem {
                    Label("Account", systemImage: "person.crop.circle")
                }

            AppearanceSettingsPane(preferences: preferences)
                .tag(Tab.appearance)
                .tabItem {
                    Label("Appearance", systemImage: "circle.lefthalf.filled")
                }

            ShortcutsSettingsPane(preferences: preferences)
                .tag(Tab.shortcuts)
                .tabItem {
                    Label("Shortcuts", systemImage: "keyboard")
                }
        }
        .padding(20)
        .frame(width: 540, height: 390)
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
                shortcutRow("a", "Toggle Unread / All")
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
