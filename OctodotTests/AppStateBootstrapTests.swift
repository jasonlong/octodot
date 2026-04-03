import Foundation
import Testing
@testable import Octodot

@MainActor
struct AppStateBootstrapTests {
    @Test func submitTokenValidatesSavesAndSignsIn() async throws {
        let session = StubNetworkSession(results: [
            .success((
                Data(#"{"login":"jasonlong"}"#.utf8),
                AppStateTests.httpResponse(
                    url: "https://api.github.com/user",
                    statusCode: 200
                )
            )),
            .success((
                Data("[]".utf8),
                AppStateTests.httpResponse(
                    url: "https://api.github.com/notifications?all=false&participating=false&per_page=100",
                    statusCode: 200
                )
            )),
            .success((
                Data("[]".utf8),
                AppStateTests.httpResponse(
                    url: "https://api.github.com/notifications?all=true&participating=false&per_page=100&since=2026-04-01T00:00:00Z",
                    statusCode: 200
                )
            ))
        ])
        let client = GitHubAPIClient(token: "ghp_new", session: session)
        var savedToken: String?

        let state = AppState(
            notifications: [],
            userDefaults: AppStateTests.makeIsolatedUserDefaults(),
            tokenSaver: { savedToken = $0 },
            apiClientFactory: { _ in client }
        )

        try await state.submitToken("ghp_new")

        await AppStateTests.waitUntil {
            await session.recordedRequests().count == 3
        }

        #expect(savedToken == "ghp_new")
        #expect(state.isSignedIn)
        #expect(state.errorMessage == nil)
        #expect((await session.recordedRequests()).count == 3)
    }

    @Test func submitTokenFailureDoesNotSaveOrSignIn() async {
        let session = StubNetworkSession(results: [
            .success((
                Data(),
                AppStateTests.httpResponse(
                    url: "https://api.github.com/user",
                    statusCode: 401
                )
            ))
        ])
        let client = GitHubAPIClient(token: "ghp_bad", session: session)
        var savedToken: String?

        let state = AppState(
            notifications: [],
            userDefaults: AppStateTests.makeIsolatedUserDefaults(),
            tokenSaver: { savedToken = $0 },
            apiClientFactory: { _ in client }
        )

        do {
            try await state.submitToken("ghp_bad")
            Issue.record("Expected submitToken to throw for unauthorized token")
        } catch {}

        #expect(savedToken == nil)
        #expect(state.isSignedIn == false)
        #expect(state.errorMessage == nil)
        #expect((await session.recordedRequests()).count == 1)
    }

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
