import Testing
import Foundation
@testable import Octodot

@MainActor
struct UpdateCheckerTests {
    private func makeRelease(
        tag: String,
        url: String = "https://github.com/jasonlong/octodot/releases/tag/v1.0.0",
        draft: Bool = false,
        prerelease: Bool = false,
        assets: [[String: Any]]? = nil
    ) -> Data {
        let releaseAssets = assets ?? [
            [
                "name": "Octodot-\(tag)-macos.zip",
                "browser_download_url": "https://github.com/jasonlong/octodot/releases/download/\(tag)/Octodot-\(tag)-macos.zip",
            ]
        ]
        let json: [String: Any] = [
            "tag_name": tag,
            "html_url": url,
            "draft": draft,
            "prerelease": prerelease,
            "assets": releaseAssets,
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    private func stubSession(
        tag: String,
        url: String = "https://github.com/jasonlong/octodot/releases/tag/v1.0.0",
        draft: Bool = false,
        prerelease: Bool = false,
        assets: [[String: Any]]? = nil
    ) -> StubNetworkSession {
        let data = makeRelease(tag: tag, url: url, draft: draft, prerelease: prerelease, assets: assets)
        let response = HTTPURLResponse(url: URL(string: "https://api.github.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return StubNetworkSession(results: [.success((data, response))])
    }

    private func errorSession() -> StubNetworkSession {
        StubNetworkSession(results: [.failure(URLError(.notConnectedToInternet))])
    }

    private func waitForCheckToComplete(_ checker: UpdateChecker) async {
        // Wait for the check to start (isChecking becomes true) then finish
        for _ in 0..<10 {
            if checker.isChecking { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        for _ in 0..<50 {
            if !checker.isChecking { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func waitForInstallFailure(_ checker: UpdateChecker) async {
        for _ in 0..<100 {
            if case .failed = checker.installState { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func waitUntilRequests(_ session: StubNetworkSession, count: Int) async {
        for _ in 0..<100 {
            if await session.recordedRequests().count == count { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func signingOutput(identifier: String = "com.octodot.app", teamIdentifier: String = "TEAM12345") -> String {
        """
        Executable=/tmp/Octodot.app/Contents/MacOS/Octodot
        Identifier=\(identifier)
        TeamIdentifier=\(teamIdentifier)
        Runtime Version=14.0.0
        """
    }

    private func verificationRunner(
        candidateIdentifier: String = "com.octodot.app",
        candidateTeamIdentifier: String = "TEAM12345",
        currentIdentifier: String = "com.octodot.app",
        currentTeamIdentifier: String = "TEAM12345",
        spctlStatus: Int32 = 0,
        currentOutput: String? = nil
    ) -> UpdateChecker.ProcessRunner {
        let candidateOutput = signingOutput(identifier: candidateIdentifier, teamIdentifier: candidateTeamIdentifier)
        let currentSigningOutput = currentOutput ?? signingOutput(identifier: currentIdentifier, teamIdentifier: currentTeamIdentifier)
        return { executable, arguments in
            if executable == "/usr/bin/codesign", arguments.first == "--verify" {
                return UpdateChecker.ProcessResult(status: 0, output: "")
            }
            if executable == "/usr/bin/codesign", arguments.contains("/tmp/candidate/Octodot.app") {
                return UpdateChecker.ProcessResult(status: 0, output: candidateOutput)
            }
            if executable == "/usr/bin/codesign", arguments.contains("/tmp/current/Octodot.app") {
                return UpdateChecker.ProcessResult(status: 0, output: currentSigningOutput)
            }
            if executable == "/usr/sbin/spctl" {
                return UpdateChecker.ProcessResult(status: spctlStatus, output: "")
            }
            return UpdateChecker.ProcessResult(status: 1, output: "unexpected command")
        }
    }

    @Test func detectsNewerVersion() async {
        let session = stubSession(tag: "v1.0.0", url: "https://github.com/jasonlong/octodot/releases/tag/v1.0.0")
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let checker = UpdateChecker(session: session, userDefaults: defaults, bundleVersion: "0.3.0")

        checker.checkForUpdatesNow()
        await waitForCheckToComplete(checker)

        #expect(checker.availableVersion == "1.0.0")
        #expect(checker.releaseURL?.absoluteString == "https://github.com/jasonlong/octodot/releases/tag/v1.0.0")
        #expect(checker.canInstallUpdate)
    }

    @Test func newerVersionWithoutMacOSAssetIsNotInstallable() async {
        let session = stubSession(
            tag: "v1.0.0",
            assets: [[
                "name": "Octodot-v1.0.0-source.zip",
                "browser_download_url": "https://github.com/jasonlong/octodot/releases/download/v1.0.0/source.zip",
            ]]
        )
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let checker = UpdateChecker(session: session, userDefaults: defaults, bundleVersion: "0.3.0")

        checker.checkForUpdatesNow()
        await waitForCheckToComplete(checker)

        #expect(checker.availableVersion == nil)
        #expect(checker.releaseURL == nil)
        #expect(checker.canInstallUpdate == false)
    }

    @Test func noUpdateWhenCurrent() async {
        let session = stubSession(tag: "v0.3.0")
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let checker = UpdateChecker(session: session, userDefaults: defaults, bundleVersion: "0.3.0")

        checker.checkForUpdatesNow()
        await waitForCheckToComplete(checker)

        #expect(checker.availableVersion == nil)
    }

    @Test func skipsDraftRelease() async {
        let session = stubSession(tag: "v2.0.0", draft: true)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let checker = UpdateChecker(session: session, userDefaults: defaults, bundleVersion: "0.3.0")

        checker.checkForUpdatesNow()
        await waitForCheckToComplete(checker)

        #expect(checker.availableVersion == nil)
    }

    @Test func skipsPrereleaseRelease() async {
        let session = stubSession(tag: "v2.0.0", prerelease: true)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let checker = UpdateChecker(session: session, userDefaults: defaults, bundleVersion: "0.3.0")

        checker.checkForUpdatesNow()
        await waitForCheckToComplete(checker)

        #expect(checker.availableVersion == nil)
    }

    @Test func networkErrorIsSilent() async {
        let session = errorSession()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let checker = UpdateChecker(session: session, userDefaults: defaults, bundleVersion: "0.3.0")

        checker.checkForUpdatesNow()
        await waitForCheckToComplete(checker)

        #expect(checker.availableVersion == nil)
        #expect(checker.isChecking == false)
    }

    @Test func dismissPersistsVersion() async {
        let session = stubSession(tag: "v1.0.0")
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let checker = UpdateChecker(session: session, userDefaults: defaults, bundleVersion: "0.3.0")

        checker.checkForUpdatesNow()
        await waitForCheckToComplete(checker)
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
        await waitForCheckToComplete(checker)

        #expect(checker.availableVersion == nil)
    }

    @Test func newerThanDismissedIsShown() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set("0.9.0", forKey: "UpdateChecker.dismissedVersion.v1")

        let session = stubSession(tag: "v1.0.0")
        let checker = UpdateChecker(session: session, userDefaults: defaults, bundleVersion: "0.3.0")

        checker.checkForUpdatesNow()
        await waitForCheckToComplete(checker)

        #expect(checker.availableVersion == "1.0.0")
    }

    @Test func installUpdateWithoutDownloadURLFailsActionably() {
        let checker = UpdateChecker(session: errorSession(), userDefaults: UserDefaults(suiteName: UUID().uuidString)!, bundleVersion: "0.3.0")

        checker.installUpdate()

        #expect(checker.installState == .failed("Update download is unavailable"))
    }

    @Test func clearInstallFailureResetsFailedState() {
        let checker = UpdateChecker(session: errorSession(), userDefaults: UserDefaults(suiteName: UUID().uuidString)!, bundleVersion: "0.3.0")

        checker.installUpdate()
        checker.clearInstallFailure()

        #expect(checker.installState == .idle)
    }

    @Test func installFailureCanBeRetried() async {
        let releaseData = makeRelease(tag: "v1.0.0")
        let releaseResponse = HTTPURLResponse(url: URL(string: "https://api.github.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let downloadResponse = HTTPURLResponse(
            url: URL(string: "https://github.com/jasonlong/octodot/releases/download/v1.0.0/Octodot-v1.0.0-macos.zip")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        let session = StubNetworkSession(results: [
            .success((releaseData, releaseResponse)),
            .failure(URLError(.notConnectedToInternet)),
            .success((Data("fake zip".utf8), downloadResponse)),
        ])
        let checker = UpdateChecker(
            session: session,
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            bundleVersion: "0.3.0",
            processRunner: { _, _ in UpdateChecker.ProcessResult(status: 1, output: "ditto failed") }
        )

        checker.checkForUpdatesNow()
        await waitForCheckToComplete(checker)
        #expect(checker.canInstallUpdate)

        checker.installUpdate()
        await waitForInstallFailure(checker)

        checker.installUpdate()
        await waitUntilRequests(session, count: 3)
        await waitForInstallFailure(checker)

        let requests = await session.recordedRequests()
        #expect(requests.count == 3)
        #expect(requests[1].url?.absoluteString.contains("Octodot-v1.0.0-macos.zip") == true)
        #expect(requests[2].url?.absoluteString.contains("Octodot-v1.0.0-macos.zip") == true)
    }

    @Test func verificationSucceedsForMatchingIdentityAndGatekeeperAssessment() throws {
        let checker = UpdateChecker(
            session: errorSession(),
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            bundleVersion: "0.3.0",
            processRunner: verificationRunner(),
            currentAppPath: "/tmp/current/Octodot.app"
        )

        try checker.verifyUpdateCandidate(at: URL(fileURLWithPath: "/tmp/candidate/Octodot.app"))
    }

    @Test func verificationRejectsDifferentTeamIdentifier() throws {
        let checker = UpdateChecker(
            session: errorSession(),
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            bundleVersion: "0.3.0",
            processRunner: verificationRunner(candidateTeamIdentifier: "OTHERTEAM"),
            currentAppPath: "/tmp/current/Octodot.app"
        )

        do {
            try checker.verifyUpdateCandidate(at: URL(fileURLWithPath: "/tmp/candidate/Octodot.app"))
            Issue.record("Expected verification to reject a different team identifier")
        } catch UpdateChecker.UpdateError.signatureIdentityMismatch {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func verificationRejectsDifferentBundleIdentifier() throws {
        let checker = UpdateChecker(
            session: errorSession(),
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            bundleVersion: "0.3.0",
            processRunner: verificationRunner(candidateIdentifier: "com.example.malicious"),
            currentAppPath: "/tmp/current/Octodot.app"
        )

        do {
            try checker.verifyUpdateCandidate(at: URL(fileURLWithPath: "/tmp/candidate/Octodot.app"))
            Issue.record("Expected verification to reject a different bundle identifier")
        } catch UpdateChecker.UpdateError.signatureIdentityMismatch {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func verificationRejectsGatekeeperFailure() throws {
        let checker = UpdateChecker(
            session: errorSession(),
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            bundleVersion: "0.3.0",
            processRunner: verificationRunner(spctlStatus: 3),
            currentAppPath: "/tmp/current/Octodot.app"
        )

        do {
            try checker.verifyUpdateCandidate(at: URL(fileURLWithPath: "/tmp/candidate/Octodot.app"))
            Issue.record("Expected verification to reject a Gatekeeper failure")
        } catch UpdateChecker.UpdateError.notarizationCheckFailed {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func verificationRejectsUnparseableCurrentSignature() throws {
        let checker = UpdateChecker(
            session: errorSession(),
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            bundleVersion: "0.3.0",
            processRunner: verificationRunner(currentOutput: "Identifier=com.octodot.app\n"),
            currentAppPath: "/tmp/current/Octodot.app"
        )

        do {
            try checker.verifyUpdateCandidate(at: URL(fileURLWithPath: "/tmp/candidate/Octodot.app"))
            Issue.record("Expected verification to reject an unparseable current signature")
        } catch UpdateChecker.UpdateError.unverifiableCurrentSignature {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func throttlesRepeatedChecks() async {
        let session = stubSession(tag: "v1.0.0")
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let checker = UpdateChecker(session: session, userDefaults: defaults, bundleVersion: "0.3.0")

        checker.checkForUpdatesNow()
        await waitForCheckToComplete(checker)

        #expect(checker.availableVersion == "1.0.0")

        checker.checkForUpdatesIfNeeded()
        #expect(checker.isChecking == false)
    }
}
