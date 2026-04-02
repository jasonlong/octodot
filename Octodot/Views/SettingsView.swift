import SwiftUI

struct SettingsView: View {
    @Bindable var appState: AppState
    @Bindable var preferences: AppPreferences

    var body: some View {
        TabView {
            AccountSettingsPane(appState: appState)
                .tabItem {
                    Label("Account", systemImage: "person.crop.circle")
                }

            AppearanceSettingsPane(preferences: preferences)
                .tabItem {
                    Label("Appearance", systemImage: "circle.lefthalf.filled")
                }

            ShortcutsSettingsPane(preferences: preferences)
                .tabItem {
                    Label("Shortcuts", systemImage: "keyboard")
                }
        }
        .padding(20)
        .frame(width: 540, height: 390)
        .preferredColorScheme(preferences.appearanceMode.colorScheme)
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
                LabeledContent("Status") {
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
                let client = GitHubAPIClient(token: tokenInput)
                let username = try await client.validateToken()
                try KeychainHelper.saveToken(tokenInput)
                await MainActor.run {
                    appState.signIn(token: tokenInput, username: username)
                    isSaving = false
                    tokenInput = ""
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    errorMessage = error.localizedDescription
                }
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
                Picker("Toggle Panel", selection: $preferences.globalShortcut) {
                    ForEach(AppPreferences.GlobalShortcut.allCases) { shortcut in
                        Text(shortcut.title).tag(shortcut)
                    }
                }

                Text("This opens or closes the panel from anywhere.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
