import Foundation
import Testing
@testable import Octodot

@MainActor
struct AppStateBootstrapTests {
    @Test func startupUnauthorizedDeletesSavedTokenAndSignsOut() async {
        let session = StubNetworkSession(results: [
            .success((
                Data(),
                AppStateTests.httpResponse(
                    url: "https://api.github.com/user",
                    statusCode: 401
                )
            ))
        ])
        let client = GitHubAPIClient(token: "ghp_saved", session: session)
        var deletedTokenCount = 0

        let state = AppState(
            notifications: [],
            userDefaults: AppStateTests.makeIsolatedUserDefaults(),
            tokenDeleter: { deletedTokenCount += 1 },
            apiClientFactory: { _ in client },
            bootstrapToken: "ghp_saved"
        )

        await AppStateTests.waitUntil {
            await MainActor.run {
                state.authStatus == .signedOut
            }
        }

        #expect(state.isSignedIn == false)
        #expect(state.errorMessage == nil)
        #expect(state.notifications.isEmpty)
        #expect(deletedTokenCount == 1)
        #expect((await session.recordedRequests()).count == 1)
    }

    @Test func startupTransientValidationFailureKeepsSavedToken() async {
        let session = StubNetworkSession(results: [
            .success((
                Data(),
                AppStateTests.httpResponse(
                    url: "https://api.github.com/user",
                    statusCode: 500
                )
            ))
        ])
        let client = GitHubAPIClient(token: "ghp_saved", session: session)
        var deletedTokenCount = 0

        let state = AppState(
            notifications: [],
            userDefaults: AppStateTests.makeIsolatedUserDefaults(),
            tokenDeleter: { deletedTokenCount += 1 },
            apiClientFactory: { _ in client },
            bootstrapToken: "ghp_saved"
        )

        await AppStateTests.waitUntil {
            await MainActor.run {
                state.errorMessage == "GitHub API error (500)"
            }
        }

        #expect(state.isSignedIn == true)
        #expect(state.notifications.isEmpty)
        #expect(deletedTokenCount == 0)
        #expect((await session.recordedRequests()).count == 1)
    }
}
