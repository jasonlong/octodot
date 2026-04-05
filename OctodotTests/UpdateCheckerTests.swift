import Testing
import Foundation
@testable import Octodot

@MainActor
struct UpdateCheckerTests {
    private func makeRelease(tag: String, url: String = "https://github.com/jasonlong/octodot/releases/tag/v1.0.0", draft: Bool = false, prerelease: Bool = false) -> Data {
        let json: [String: Any] = [
            "tag_name": tag,
            "html_url": url,
            "draft": draft,
            "prerelease": prerelease,
            "assets": [
                [
                    "name": "Octodot-\(tag)-macos.zip",
                    "browser_download_url": "https://github.com/jasonlong/octodot/releases/download/\(tag)/Octodot-\(tag)-macos.zip",
                ]
            ] as [[String: Any]],
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    private func stubSession(tag: String, url: String = "https://github.com/jasonlong/octodot/releases/tag/v1.0.0", draft: Bool = false, prerelease: Bool = false) -> StubNetworkSession {
        let data = makeRelease(tag: tag, url: url, draft: draft, prerelease: prerelease)
        let response = HTTPURLResponse(url: URL(string: "https://api.github.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return StubNetworkSession(results: [.success((data, response))])
    }

    private func errorSession() -> StubNetworkSession {
        StubNetworkSession(results: [.failure(URLError(.notConnectedToInternet))])
    }

    @Test func detectsNewerVersion() async {
        let session = stubSession(tag: "v1.0.0", url: "https://github.com/jasonlong/octodot/releases/tag/v1.0.0")
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let checker = UpdateChecker(session: session, userDefaults: defaults, bundleVersion: "0.3.0")

        checker.checkForUpdatesNow()
        // Wait for the async task to complete
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(checker.availableVersion == "1.0.0")
        #expect(checker.releaseURL?.absoluteString == "https://github.com/jasonlong/octodot/releases/tag/v1.0.0")
    }

    @Test func noUpdateWhenCurrent() async {
        let session = stubSession(tag: "v0.3.0")
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let checker = UpdateChecker(session: session, userDefaults: defaults, bundleVersion: "0.3.0")

        checker.checkForUpdatesNow()
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(checker.availableVersion == nil)
    }

    @Test func skipsDraftRelease() async {
        let session = stubSession(tag: "v2.0.0", draft: true)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let checker = UpdateChecker(session: session, userDefaults: defaults, bundleVersion: "0.3.0")

        checker.checkForUpdatesNow()
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(checker.availableVersion == nil)
    }

    @Test func skipsPrereleaseRelease() async {
        let session = stubSession(tag: "v2.0.0", prerelease: true)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let checker = UpdateChecker(session: session, userDefaults: defaults, bundleVersion: "0.3.0")

        checker.checkForUpdatesNow()
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(checker.availableVersion == nil)
    }

    @Test func networkErrorIsSilent() async {
        let session = errorSession()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let checker = UpdateChecker(session: session, userDefaults: defaults, bundleVersion: "0.3.0")

        checker.checkForUpdatesNow()
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(checker.availableVersion == nil)
        #expect(checker.isChecking == false)
    }

    @Test func dismissPersistsVersion() async {
        let session = stubSession(tag: "v1.0.0")
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let checker = UpdateChecker(session: session, userDefaults: defaults, bundleVersion: "0.3.0")

        checker.checkForUpdatesNow()
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(checker.availableVersion == "1.0.0")

        checker.dismissUpdate()
        #expect(checker.availableVersion == nil)
        #expect(defaults.string(forKey: "UpdateChecker.dismissedVersion.v1") == "1.0.0")
    }

    @Test func dismissedVersionIsSkipped() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set("1.0.0", forKey: "UpdateChecker.dismissedVersion.v1")

        let session = stubSession(tag: "v1.0.0")
        let checker = UpdateChecker(session: session, userDefaults: defaults, bundleVersion: "0.3.0")

        checker.checkForUpdatesNow()
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(checker.availableVersion == nil)
    }

    @Test func newerThanDismissedIsShown() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set("1.0.0", forKey: "UpdateChecker.dismissedVersion.v1")

        let session = stubSession(tag: "v1.1.0", url: "https://github.com/jasonlong/octodot/releases/tag/v1.1.0")
        let checker = UpdateChecker(session: session, userDefaults: defaults, bundleVersion: "0.3.0")

        checker.checkForUpdatesNow()
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(checker.availableVersion == "1.1.0")
    }

    @Test func throttlesRepeatedChecks() async {
        let data = makeRelease(tag: "v1.0.0")
        let response = HTTPURLResponse(url: URL(string: "https://api.github.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let session = StubNetworkSession(results: [.success((data, response))])

        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        // Simulate a recent check
        defaults.set(Date().timeIntervalSince1970, forKey: "UpdateChecker.lastCheckDate.v1")

        let checker = UpdateChecker(session: session, userDefaults: defaults, bundleVersion: "0.3.0")

        checker.checkForUpdatesIfNeeded()
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Should not have checked — session result not consumed
        #expect(checker.availableVersion == nil)
        let requests = await session.recordedRequests()
        #expect(requests.isEmpty)
    }
}
