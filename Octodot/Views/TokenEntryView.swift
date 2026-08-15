import SwiftUI

struct TokenEntryView: View {
    @Bindable var appState: AppState
    @State private var tokenInput = ""
    @State private var isValidating = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "bell.fill")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text("Sign in to GitHub")
                .font(.system(size: 15, weight: .semibold))

            VStack(spacing: 4) {
                Text("Create a classic Personal Access Token with the **notifications** and **repo** scopes.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .frame(maxWidth: 280)

                if let tokenURL = URL(string: "https://github.com/settings/tokens") {
                    Link("Create token on GitHub →", destination: tokenURL)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.accentColor)
                }
            }

            VStack(spacing: 8) {
                SecureField("Personal Access Token", text: $tokenInput, prompt: Text("ghp_…"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(maxWidth: 280)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Sign-in failed: \(errorMessage)")
                }
            }

            Button(action: submit) {
                if isValidating {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 80)
                } else {
                    Text("Sign In")
                        .frame(width: 80)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(isTokenEmpty || isValidating)
            .keyboardShortcut(.return, modifiers: [])
            .accessibilityLabel(isValidating ? "Signing in" : "Sign In")

            Spacer()
        }
        .padding(20)
        .frame(width: 380, height: 500)
    }

    private var isTokenEmpty: Bool {
        tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        let token = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        isValidating = true
        errorMessage = nil

        Task {
            do {
                await MainActor.run {
                    errorMessage = nil
                }
                try await appState.submitToken(token)
                await MainActor.run {
                    isValidating = false
                    tokenInput = ""
                }
            } catch {
                await MainActor.run {
                    isValidating = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
