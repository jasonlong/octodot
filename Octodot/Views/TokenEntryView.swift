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

            Text("Sign in to GitHub")
                .font(.system(size: 15, weight: .semibold))

            Text("Create a classic Personal Access Token with the\n**notifications** and **repo** scopes at GitHub → Settings → Tokens")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)

            VStack(spacing: 8) {
                SecureField("ghp_...", text: $tokenInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(maxWidth: 280)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
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
            .disabled(tokenInput.isEmpty || isValidating)
            .keyboardShortcut(.return, modifiers: [])

            Spacer()
        }
        .padding(20)
        .frame(width: 380, height: 500)
    }

    private func submit() {
        isValidating = true
        errorMessage = nil

        Task {
            do {
                await MainActor.run {
                    errorMessage = nil
                }
                try await appState.submitToken(tokenInput)
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
