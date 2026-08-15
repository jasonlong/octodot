import Testing
import Foundation
@testable import Octodot

@MainActor
struct UpdateCheckerTests {
    private actor CancellableDownloadSession: NetworkSession {
        private let releaseData: Data
        private var didStartDownload = false

        init(releaseData: Data) {
            self.releaseData = releaseData
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            (
                releaseData,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/repos/jasonlong/octodot/releases/latest")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }

        func downloadFile(for request: URLRequest) async throws -> (URL, URLResponse) {
            didStartDownload = true
            try await Task.sleep(for: .seconds(60))
            throw StubNetworkSession.StubError.missingResponse
        }

        func downloadStarted() -> Bool {
            didStartDownload
        }
    }

    private actor SparseDownloadSession: NetworkSession {
        private let releaseData: Data
        private let downloadSize: UInt64
        private var requests: [URLRequest] = []

        init(releaseData: Data, downloadSize: UInt64) {
            self.releaseData = releaseData
            self.downloadSize = downloadSize
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            requests.append(request)
            return (
                releaseData,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/repos/jasonlong/octodot/releases/latest")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }

        func downloadFile(for request: URLRequest) async throws -> (URL, URLResponse) {
            requests.append(request)
            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("com.octodot.oversized-download.\(UUID().uuidString)")
            guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
                throw StubNetworkSession.StubError.missingResponse
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.truncate(atOffset: downloadSize)
            try handle.close()
            return (
                fileURL,
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }
    }

    private func makeRelease(
        tag: String,
        url: String? = nil,
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
            "html_url": url ?? "https://github.com/jasonlong/octodot/releases/tag/\(tag)",
            "draft": draft,
            "prerelease": prerelease,
            "assets": releaseAssets,
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    private func stubSession(
        tag: String,
        url: String? = nil,
        draft: Bool = false,
        prerelease: Bool = false,
        assets: [[String: Any]]? = nil
    ) -> StubNetworkSession {
        let data = makeRelease(tag: tag, url: url, draft: draft, prerelease: prerelease, assets: assets)
        let response = HTTPURLResponse(
            url: URL(string: "https://api.github.com/repos/jasonlong/octodot/releases/latest")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
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
        currentOutput: String? = nil,
        candidatePath: String = "/tmp/candidate/Octodot.app",
        currentVerifyStatus: Int32 = 0
    ) -> UpdateChecker.ProcessRunner {
        let candidateOutput = signingOutput(identifier: candidateIdentifier, teamIdentifier: candidateTeamIdentifier)
        let currentSigningOutput = currentOutput ?? signingOutput(identifier: currentIdentifier, teamIdentifier: currentTeamIdentifier)
        return { executable, arguments in
            if executable == "/usr/bin/codesign", arguments.first == "--verify",
               arguments.contains("/tmp/current/Octodot.app") {
                return UpdateChecker.ProcessResult(status: currentVerifyStatus, output: "")
            }
            if executable == "/usr/bin/codesign", arguments.first == "--verify" {
                return UpdateChecker.ProcessResult(status: 0, output: "")
            }
            if executable == "/usr/bin/codesign", arguments.contains(candidatePath) {
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

    private func makeReplacementFixture() throws -> (root: URL, current: URL, replacement: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("octodot-relaunch-test-\(UUID().uuidString)", isDirectory: true)
        let current = root.appendingPathComponent("Applications/Octodot.app", isDirectory: true)
        let replacement = root.appendingPathComponent("download/extract/Octodot.app", isDirectory: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: current.appendingPathComponent("version"))
        try Data("new".utf8).write(to: replacement.appendingPathComponent("version"))
        return (root, current, replacement)
    }

    private func writeInfoPlist(version: String, to appURL: URL) throws {
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleShortVersionString": version],
            format: .xml,
            options: 0
        )
        try data.write(to: contentsURL.appendingPathComponent("Info.plist"))
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

    @Test func releaseWithExternalDownloadURLIsNotInstallable() async {
        let session = stubSession(
            tag: "v1.0.0",
            assets: [[
                "name": "Octodot-v1.0.0-macos.zip",
                "browser_download_url": "https://example.com/Octodot-v1.0.0-macos.zip",
            ]]
        )
        let checker = UpdateChecker(
            session: session,
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            bundleVersion: "0.3.0"
        )

        checker.checkForUpdatesNow()
        await waitForCheckToComplete(checker)

        #expect(checker.availableVersion == nil)
        #expect(checker.releaseURL == nil)
        #expect(!checker.canInstallUpdate)
    }

    @Test func releaseWithExternalWebURLIsRejected() async {
        let session = stubSession(tag: "v1.0.0", url: "https://example.com/releases/v1.0.0")
        let checker = UpdateChecker(
            session: session,
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            bundleVersion: "0.3.0"
        )

        checker.checkForUpdatesNow()
        await waitForCheckToComplete(checker)

        #expect(checker.availableVersion == nil)
        #expect(!checker.canInstallUpdate)
    }

    @Test func releaseMetadataFromExternalFinalResponseURLIsRejected() async {
        let session = StubNetworkSession(results: [
            .success((
                makeRelease(tag: "v1.0.0"),
                HTTPURLResponse(
                    url: URL(string: "https://example.com/releases/latest")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
            ))
        ])
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let checker = UpdateChecker(
            session: session,
            userDefaults: defaults,
            bundleVersion: "0.3.0"
        )

        checker.checkForUpdatesNow()
        await waitForCheckToComplete(checker)

        #expect(checker.availableVersion == nil)
        #expect(checker.releaseURL == nil)
        #expect(defaults.object(forKey: "UpdateChecker.lastCheckDate.v1") == nil)
    }

    @Test func noUpdateWhenCurrent() async {
        let session = stubSession(tag: "v0.3.0")
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let checker = UpdateChecker(session: session, userDefaults: defaults, bundleVersion: "0.3.0")

        checker.checkForUpdatesNow()
        await waitForCheckToComplete(checker)

        #expect(checker.availableVersion == nil)
        #expect(checker.showingUpToDate)
        #expect(defaults.object(forKey: "UpdateChecker.lastCheckDate.v1") != nil)
    }

    @Test func skipsDraftRelease() async {
        let session = stubSession(tag: "v2.0.0", draft: true)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let checker = UpdateChecker(session: session, userDefaults: defaults, bundleVersion: "0.3.0")

        checker.checkForUpdatesNow()
        await waitForCheckToComplete(checker)

        #expect(checker.availableVersion == nil)
    }

    @Test func draftResponseClearsPreviouslyAvailableUpdate() async {
        let response = HTTPURLResponse(
            url: URL(string: "https://api.github.com/repos/jasonlong/octodot/releases/latest")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        let session = StubNetworkSession(results: [
            .success((makeRelease(tag: "v1.0.0"), response)),
            .success((makeRelease(tag: "v1.0.0", draft: true), response)),
        ])
        let checker = UpdateChecker(
            session: session,
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            bundleVersion: "0.3.0"
        )

        checker.checkForUpdatesNow()
        await waitForCheckToComplete(checker)
        #expect(checker.availableVersion == "1.0.0")

        checker.checkForUpdatesNow()
        await waitForCheckToComplete(checker)

        #expect(checker.availableVersion == nil)
        #expect(!checker.canInstallUpdate)
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
        #expect(checker.showingUpToDate == false)
        #expect(checker.isChecking == false)
        #expect(defaults.object(forKey: "UpdateChecker.lastCheckDate.v1") == nil)
    }

    @Test func httpFailureWithValidReleaseIsSilentAndInconclusive() async {
        let response = HTTPURLResponse(
            url: URL(string: "https://api.github.com/repos/jasonlong/octodot/releases/latest")!,
            statusCode: 500,
            httpVersion: nil,
            headerFields: nil
        )!
        let session = StubNetworkSession(results: [
            .success((makeRelease(tag: "v1.0.0"), response))
        ])
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let checker = UpdateChecker(session: session, userDefaults: defaults, bundleVersion: "0.3.0")

        checker.checkForUpdatesNow()
        await waitForCheckToComplete(checker)

        #expect(checker.availableVersion == nil)
        #expect(checker.showingUpToDate == false)
        #expect(checker.isChecking == false)
        #expect(defaults.object(forKey: "UpdateChecker.lastCheckDate.v1") == nil)
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
        let releaseResponse = HTTPURLResponse(
            url: URL(string: "https://api.github.com/repos/jasonlong/octodot/releases/latest")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
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

    @Test func applicationTerminationCancelsTrackedInstallBeforeReplacement() async {
        let session = CancellableDownloadSession(releaseData: makeRelease(tag: "v1.0.0"))
        let checker = UpdateChecker(
            session: session,
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            bundleVersion: "0.3.0"
        )

        checker.checkForUpdatesNow()
        await waitForCheckToComplete(checker)
        checker.installUpdate()

        for _ in 0..<100 where !(await session.downloadStarted()) {
            await Task.yield()
        }
        #expect(await session.downloadStarted())
        #expect(checker.isInstallingUpdate)

        let cleanedUp = await checker.cancelInstallForApplicationTermination(
            timeoutNanoseconds: 1_000,
            pollIntervalNanoseconds: 1,
            sleepHandler: { _ in await Task.yield() }
        )

        #expect(cleanedUp)
        #expect(checker.isInstallingUpdate == false)
        #expect(checker.installState == .idle)
        #expect(checker.isTerminatingAfterSuccessfulUpdate == false)
    }

    @Test func oversizedArchiveIsRejectedBeforeWritingOrExtracting() async {
        let releaseData = makeRelease(tag: "v1.0.0")
        let releaseResponse = HTTPURLResponse(
            url: URL(string: "https://api.github.com/repos/jasonlong/octodot/releases/latest")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        let downloadURL = URL(
            string: "https://github.com/jasonlong/octodot/releases/download/v1.0.0/Octodot-v1.0.0-macos.zip"
        )!
        let downloadResponse = HTTPURLResponse(
            url: downloadURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Length": "500000000"]
        )!
        let session = StubNetworkSession(results: [
            .success((releaseData, releaseResponse)),
            .success((Data("not really large".utf8), downloadResponse)),
        ])
        let checker = UpdateChecker(
            session: session,
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            bundleVersion: "0.3.0"
        )

        checker.checkForUpdatesNow()
        await waitForCheckToComplete(checker)
        checker.installUpdate()
        await waitForInstallFailure(checker)

        #expect(checker.installState == .failed("Download failed"))
    }

    @Test func oversizedArchiveWithoutContentLengthIsRejectedFromDisk() async {
        let session = SparseDownloadSession(
            releaseData: makeRelease(tag: "v1.0.0"),
            downloadSize: UInt64(200 * 1024 * 1024 + 1)
        )
        let checker = UpdateChecker(
            session: session,
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            bundleVersion: "0.3.0"
        )

        checker.checkForUpdatesNow()
        await waitForCheckToComplete(checker)
        checker.installUpdate()
        await waitForInstallFailure(checker)

        #expect(checker.installState == .failed("Download failed"))
    }

    @Test func archivePreflightAcceptsExpectedAppLayout() throws {
        try UpdateChecker.validateArchiveEntries(
            """
            Octodot.app/
            Octodot.app/Contents/
            Octodot.app/Contents/MacOS/Octodot
            __MACOSX/
            """,
            expectedCount: 4
        )
    }

    @Test func archivePreflightRejectsTraversalAndUnexpectedTopLevelEntries() {
        #expect(throws: UpdateChecker.UpdateError.extractionFailed) {
            try UpdateChecker.validateArchiveEntries(
                """
                Octodot.app/
                Octodot.app/Contents/../../escape
                """,
                expectedCount: 2
            )
        }
        #expect(throws: UpdateChecker.UpdateError.extractionFailed) {
            try UpdateChecker.validateArchiveEntries(
                """
                Octodot.app/
                Surprise.app/payload
                """,
                expectedCount: 2
            )
        }
    }

    @Test func archiveTypePreflightAcceptsRegularFilesAndDirectories() throws {
        try UpdateChecker.validateArchiveEntryTypes(
            """
            drwxr-xr-x  3.0 unx        0 bx stor 26-Aug-15 10:00 Octodot.app/
            drwxr-xr-x  3.0 unx        0 bx stor 26-Aug-15 10:00 Octodot.app/Contents/
            -rwxr-xr-x  3.0 unx   123456 bx defN 26-Aug-15 10:00 Octodot.app/Contents/MacOS/Octodot
            """,
            expectedCount: 3
        )
    }

    @Test func archiveTypePreflightRejectsSymbolicLinks() {
        #expect(throws: UpdateChecker.UpdateError.extractionFailed) {
            try UpdateChecker.validateArchiveEntryTypes(
                """
                drwxr-xr-x  3.0 unx        0 bx stor 26-Aug-15 10:00 Octodot.app/
                lrwxr-xr-x  3.0 unx       21 bx stor 26-Aug-15 10:00 Octodot.app/Contents/link
                """,
                expectedCount: 2
            )
        }
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

    @Test func verificationRejectsInvalidCurrentCodeSignature() throws {
        let checker = UpdateChecker(
            session: errorSession(),
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            bundleVersion: "0.3.0",
            processRunner: verificationRunner(currentVerifyStatus: 1),
            currentAppPath: "/tmp/current/Octodot.app"
        )

        do {
            try checker.verifyUpdateCandidate(at: URL(fileURLWithPath: "/tmp/candidate/Octodot.app"))
            Issue.record("Expected invalid current app signature to be rejected")
        } catch UpdateChecker.UpdateError.unverifiableCurrentSignature {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func verificationRejectsCandidateWithUnexpectedVersion() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("octodot-version-check-\(UUID().uuidString)", isDirectory: true)
        let candidate = root.appendingPathComponent("Octodot.app", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try writeInfoPlist(version: "0.9.0", to: candidate)

        let checker = UpdateChecker(
            session: errorSession(),
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            bundleVersion: "0.3.0",
            processRunner: verificationRunner(candidatePath: candidate.path),
            currentAppPath: "/tmp/current/Octodot.app"
        )

        do {
            try checker.verifyUpdateCandidate(at: candidate, expectedVersion: "1.0.0")
            Issue.record("Expected candidate version mismatch")
        } catch UpdateChecker.UpdateError.versionMismatch {
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

    @Test func futureLastCheckDateDoesNotDisableUpdateChecks() async {
        let session = stubSession(tag: "v1.0.0")
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(
            Date().addingTimeInterval(7 * 24 * 60 * 60).timeIntervalSince1970,
            forKey: "UpdateChecker.lastCheckDate.v1"
        )
        let checker = UpdateChecker(session: session, userDefaults: defaults, bundleVersion: "0.3.0")

        checker.checkForUpdatesIfNeeded()
        await waitForCheckToComplete(checker)

        #expect(checker.availableVersion == "1.0.0")
        #expect(await session.recordedRequests().count == 1)
    }

    @Test func relaunchFailureRestoresPreviousAppAndKeepsProcessAlive() async throws {
        let fixture = try makeReplacementFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var didTerminate = false
        let checker = UpdateChecker(
            session: errorSession(),
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            bundleVersion: "0.3.0",
            currentAppPath: fixture.current.path,
            appRelauncher: { _ in
                throw NSError(domain: "UpdateCheckerTests", code: 1)
            },
            appTerminator: {
                didTerminate = true
            }
        )

        do {
            try await checker.replaceAndRelaunch(with: fixture.replacement)
            Issue.record("Expected relaunch failure")
        } catch let error as UpdateChecker.UpdateError {
            #expect(error == .relaunchFailed)
            #expect(error.errorDescription == "Failed to relaunch the update; the previous version was restored")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let restoredVersion = try String(
            contentsOf: fixture.current.appendingPathComponent("version"),
            encoding: .utf8
        )
        #expect(restoredVersion == "old")
        #expect(FileManager.default.fileExists(atPath: fixture.replacement.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.current.path + ".old"))
        let stagedArtifacts = try FileManager.default.contentsOfDirectory(
            at: fixture.current.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".Octodot.update-stage.") }
        #expect(stagedArtifacts.isEmpty)
        #expect(!didTerminate)
    }

    @Test func rollbackFailureIsActionableAndKeepsProcessAlive() async throws {
        let fixture = try makeReplacementFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let backupURL = URL(fileURLWithPath: fixture.current.path + ".old")
        var didTerminate = false
        let checker = UpdateChecker(
            session: errorSession(),
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            bundleVersion: "0.3.0",
            currentAppPath: fixture.current.path,
            appRelauncher: { _ in
                try FileManager.default.removeItem(at: backupURL)
                throw NSError(domain: "UpdateCheckerTests", code: 2)
            },
            appTerminator: {
                didTerminate = true
            }
        )

        do {
            try await checker.replaceAndRelaunch(with: fixture.replacement)
            Issue.record("Expected rollback failure")
        } catch let error as UpdateChecker.UpdateError {
            #expect(error == .rollbackFailed)
            #expect(error.errorDescription == "Failed to restore the previous version after update installation failed")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(!didTerminate)
    }

    @Test func acceptedRelaunchTerminatesOnlyAfterLaunchSucceeds() async throws {
        let fixture = try makeReplacementFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let staleStage = fixture.current.deletingLastPathComponent()
            .appendingPathComponent(".Octodot.update-stage.app", isDirectory: true)
        try FileManager.default.createDirectory(at: staleStage, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: staleStage.appendingPathComponent("version"))
        var events: [String] = []
        var checkerReference: UpdateChecker?
        let checker = UpdateChecker(
            session: errorSession(),
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            bundleVersion: "0.3.0",
            currentAppPath: fixture.current.path,
            appRelauncher: { appURL in
                #expect(appURL == fixture.current)
                events.append("relaunched")
            },
            appTerminator: {
                #expect(checkerReference?.isTerminatingAfterSuccessfulUpdate == true)
                events.append("terminated")
            }
        )
        checkerReference = checker

        try await checker.replaceAndRelaunch(with: fixture.replacement)

        let installedVersion = try String(
            contentsOf: fixture.current.appendingPathComponent("version"),
            encoding: .utf8
        )
        #expect(installedVersion == "new")
        #expect(events == ["relaunched", "terminated"])
        #expect(checker.isTerminatingAfterSuccessfulUpdate)
        #expect(FileManager.default.fileExists(atPath: fixture.replacement.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.current.path + ".old"))
        let stagedArtifacts = try FileManager.default.contentsOfDirectory(
            at: fixture.current.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".Octodot.update-stage.") }
        #expect(stagedArtifacts.isEmpty)
    }
}
