import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class UpdateChecker {
    private static let lastCheckDateKey = "UpdateChecker.lastCheckDate.v1"
    private static let dismissedVersionKey = "UpdateChecker.dismissedVersion.v1"
    private static let checkIntervalSeconds: TimeInterval = 24 * 60 * 60
    private static let maximumArchiveSize = 200 * 1024 * 1024
    private static let releasesURL = URL(string: "https://api.github.com/repos/jasonlong/octodot/releases/latest")!
    private static let trustedDownloadResponseHosts: Set<String> = [
        "github.com",
        "objects.githubusercontent.com",
        "release-assets.githubusercontent.com",
    ]

    typealias ProcessResult = UpdateInstaller.ProcessResult
    typealias ProcessRunner = UpdateInstaller.ProcessRunner
    typealias UpdateError = UpdateInstaller.UpdateError
    typealias AppRelauncher = @MainActor (URL) async throws -> Void
    typealias AppTerminator = @MainActor () -> Void
    typealias TerminationSleepHandler = @Sendable (_ nanoseconds: UInt64) async -> Void

    private enum CheckError: Error {
        case invalidResponse
    }

    struct AvailableUpdate: Equatable {
        let version: String
        let releaseURL: URL
        let downloadURL: URL
    }

    enum InstallState: Equatable {
        case idle
        case downloading(progress: Double)
        case installing
        case failed(String)
    }

    private(set) var availableUpdate: AvailableUpdate?
    private(set) var isChecking = false
    private(set) var installState: InstallState = .idle
    private(set) var showingUpToDate = false
    private(set) var isTerminatingAfterSuccessfulUpdate = false

    var availableVersion: String? {
        availableUpdate?.version
    }

    var releaseURL: URL? {
        availableUpdate?.releaseURL
    }

    private var upToDateDismissTask: Task<Void, Never>?
    private var installTask: Task<Void, Never>?
    private let session: any NetworkSession
    private let userDefaults: UserDefaults
    private let bundleVersion: String?
    private let processRunner: ProcessRunner
    private let currentAppPath: String
    private let appRelauncher: AppRelauncher
    private let appTerminator: AppTerminator

    init(
        session: any NetworkSession = URLSession.shared,
        userDefaults: UserDefaults = .standard,
        bundleVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
        processRunner: @escaping ProcessRunner = UpdateInstaller.systemProcessRunner,
        currentAppPath: String = Bundle.main.bundlePath,
        appRelauncher: @escaping AppRelauncher = UpdateChecker.defaultAppRelauncher,
        appTerminator: @escaping AppTerminator = UpdateChecker.defaultAppTerminator
    ) {
        self.session = session
        self.userDefaults = userDefaults
        self.bundleVersion = bundleVersion
        self.processRunner = processRunner
        self.currentAppPath = currentAppPath
        self.appRelauncher = appRelauncher
        self.appTerminator = appTerminator
    }

    private static func defaultAppRelauncher(_ appURL: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { application, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if application == nil {
                    continuation.resume(throwing: UpdateError.relaunchFailed)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private static func defaultAppTerminator() {
        NSApplication.shared.terminate(nil)
    }

    func checkForUpdatesIfNeeded() {
        let lastCheck = userDefaults.double(forKey: Self.lastCheckDateKey)
        let now = Date().timeIntervalSince1970
        if lastCheck.isFinite, lastCheck <= now,
           now - lastCheck < Self.checkIntervalSeconds {
            return
        }
        Task { await performCheck() }
    }

    func checkForUpdatesNow() {
        Task { await performCheck(showUpToDate: true) }
    }

    var canInstallUpdate: Bool {
        availableUpdate != nil
    }

    var isInstallingUpdate: Bool {
        installTask != nil
    }

    func dismissUpdate() {
        guard let availableUpdate else { return }
        userDefaults.set(availableUpdate.version, forKey: Self.dismissedVersionKey)
        clearAvailableUpdate()
        installState = .idle
    }

    func installUpdate() {
        guard installTask == nil else { return }
        guard let availableUpdate else {
            installState = .failed("Update download is unavailable")
            return
        }
        installTask = Task { [weak self] in
            guard let self else { return }
            await self.performInstall(
                downloadURL: availableUpdate.downloadURL,
                expectedVersion: availableUpdate.version
            )
            self.installTask = nil
        }
    }

    /// Cancels a user-initiated install and gives its cleanup a bounded opportunity
    /// to complete before application termination proceeds.
    func cancelInstallForApplicationTermination(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        pollIntervalNanoseconds: UInt64 = 25_000_000,
        sleepHandler: @escaping TerminationSleepHandler = UpdateChecker.defaultTerminationSleepHandler
    ) async -> Bool {
        guard let installTask else { return true }
        installTask.cancel()

        guard timeoutNanoseconds > 0 else { return false }
        let pollInterval = max(1, min(pollIntervalNanoseconds, timeoutNanoseconds))
        var remainingNanoseconds = timeoutNanoseconds

        while self.installTask != nil {
            let sleepNanoseconds = min(pollInterval, remainingNanoseconds)
            await sleepHandler(sleepNanoseconds)

            guard self.installTask != nil else { return true }
            guard remainingNanoseconds > sleepNanoseconds else { return false }
            remainingNanoseconds -= sleepNanoseconds
        }

        return true
    }

    nonisolated static let defaultTerminationSleepHandler: TerminationSleepHandler = { nanoseconds in
        let clampedNanoseconds = min(nanoseconds, UInt64(Int64.max))
        try? await Task.sleep(for: .nanoseconds(Int64(clampedNanoseconds)))
    }

    func clearInstallFailure() {
        if case .failed = installState {
            installState = .idle
        }
    }

    // MARK: - Check

    private func performCheck(showUpToDate: Bool = false) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        do {
            let release = try await fetchLatestRelease()
            guard applyRelease(release) else { return }
            userDefaults.set(Date().timeIntervalSince1970, forKey: Self.lastCheckDateKey)
            if showUpToDate, availableVersion == nil {
                flashUpToDate()
            }
        } catch {
            // Silent failure — don't disrupt the user for update-check errors
        }
    }

    private func flashUpToDate() {
        upToDateDismissTask?.cancel()
        showingUpToDate = true
        upToDateDismissTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            showingUpToDate = false
        }
    }

    private func fetchLatestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: Self.releasesURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Octodot", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              Self.isTrustedReleaseResponseURL(httpResponse.url),
              (200...299).contains(httpResponse.statusCode) else {
            throw CheckError.invalidResponse
        }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    @discardableResult
    private func applyRelease(_ release: GitHubRelease) -> Bool {
        guard !release.draft, !release.prerelease else {
            clearAvailableUpdate()
            clearInstallFailure()
            return true
        }

        guard let remoteVersion = SemanticVersion(release.tagName),
              let currentVersion = bundleVersion.flatMap(SemanticVersion.init) else {
            clearAvailableUpdate()
            clearInstallFailure()
            return false
        }

        guard remoteVersion > currentVersion else {
            clearAvailableUpdate()
            clearInstallFailure()
            return true
        }

        let dismissedTag = userDefaults.string(forKey: Self.dismissedVersionKey)
        if let dismissedTag, let dismissed = SemanticVersion(dismissedTag), remoteVersion <= dismissed {
            clearAvailableUpdate()
            clearInstallFailure()
            return true
        }

        guard let releaseURL = Self.trustedReleaseURL(
            from: release.htmlURL,
            expectedTag: release.tagName
        ),
              let assetURL = Self.macOSAssetURL(from: release) else {
            clearAvailableUpdate()
            clearInstallFailure()
            return true
        }

        availableUpdate = AvailableUpdate(
            version: remoteVersion.description,
            releaseURL: releaseURL,
            downloadURL: assetURL
        )
        clearInstallFailure()
        return true
    }

    private static func macOSAssetURL(from release: GitHubRelease) -> URL? {
        let expectedAssetName = "Octodot-\(release.tagName)-macos.zip"
        guard let asset = release.assets.first(where: { $0.name == expectedAssetName }),
              let url = URL(string: asset.browserDownloadURL),
              isTrustedReleaseDownloadURL(url),
              url.pathComponents[5] == release.tagName,
              url.lastPathComponent == expectedAssetName else {
            return nil
        }
        return url
    }

    private static func trustedReleaseURL(from string: String, expectedTag: String) -> URL? {
        guard let url = URL(string: string),
              isSecureURL(url, allowedHosts: ["github.com"]),
              url.query == nil,
              url.pathComponents.count == 6,
              url.pathComponents[1] == "jasonlong",
              url.pathComponents[2] == "octodot",
              url.pathComponents[3] == "releases",
              url.pathComponents[4] == "tag",
              url.pathComponents[5] == expectedTag else {
            return nil
        }
        return url
    }

    private static func isTrustedReleaseDownloadURL(_ url: URL) -> Bool {
        let parts = url.pathComponents
        return isSecureURL(url, allowedHosts: ["github.com"])
            && url.query == nil
            && parts.count == 7
            && parts[1] == "jasonlong"
            && parts[2] == "octodot"
            && parts[3] == "releases"
            && parts[4] == "download"
            && !parts[5].isEmpty
            && !parts[6].isEmpty
    }

    private static func isTrustedDownloadResponseURL(_ url: URL?) -> Bool {
        guard let url else { return false }
        return isSecureURL(url, allowedHosts: trustedDownloadResponseHosts)
    }

    private static func isTrustedReleaseResponseURL(_ url: URL?) -> Bool {
        guard let url else { return false }
        return isSecureURL(url, allowedHosts: ["api.github.com"])
            && url.path == releasesURL.path
            && url.query == nil
    }

    private static func isSecureURL(_ url: URL, allowedHosts: Set<String>) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return url.scheme?.lowercased() == "https"
            && allowedHosts.contains(host)
            && url.user == nil
            && url.password == nil
            && url.port == nil
            && url.fragment == nil
    }

    private func clearAvailableUpdate() {
        availableUpdate = nil
    }

    // MARK: - Install

    private func performInstall(downloadURL: URL, expectedVersion: String) async {
        switch installState {
        case .idle, .failed:
            break
        case .downloading, .installing:
            return
        }
        installState = .downloading(progress: 0)

        var temporaryRoot: URL?
        defer {
            if let temporaryRoot {
                try? FileManager.default.removeItem(at: temporaryRoot)
            }
        }

        do {
            try Task.checkCancellation()
            let zipPath = try await downloadZip(from: downloadURL)
            temporaryRoot = zipPath.deletingLastPathComponent()
            try Task.checkCancellation()
            installState = .installing
            let processRunner = self.processRunner
            let extractedAppPath = try await Task.detached(priority: .userInitiated) {
                try UpdateInstaller.extractApp(from: zipPath, processRunner: processRunner)
            }.value
            try Task.checkCancellation()
            try await replaceAndRelaunch(
                with: extractedAppPath,
                expectedVersion: expectedVersion
            )
        } catch {
            if Task.isCancelled || error is CancellationError {
                installState = .idle
            } else {
                installState = .failed(error.localizedDescription)
            }
        }
    }

    private func downloadZip(from url: URL) async throws -> URL {
        guard Self.isTrustedReleaseDownloadURL(url) else {
            throw UpdateError.untrustedDownloadURL
        }
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.octodot.update.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        var downloadedFileURL: URL?
        do {
            let zipPath = tempDir.appendingPathComponent("Octodot-update.zip")
            var request = URLRequest(url: url)
            request.timeoutInterval = 5 * 60
            request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
            request.setValue("Octodot", forHTTPHeaderField: "User-Agent")

            let (temporaryDownloadURL, response) = try await session.downloadFile(for: request)
            downloadedFileURL = temporaryDownloadURL
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  Self.isTrustedDownloadResponseURL(http.url),
                  http.expectedContentLength < 0 || http.expectedContentLength <= Int64(Self.maximumArchiveSize) else {
                throw UpdateError.downloadFailed
            }

            let downloadedValues = try temporaryDownloadURL.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
            guard downloadedValues.isRegularFile == true,
                  downloadedValues.isSymbolicLink != true,
                  let fileSize = downloadedValues.fileSize,
                  fileSize > 0,
                  fileSize <= Self.maximumArchiveSize,
                  http.expectedContentLength < 0 || http.expectedContentLength == Int64(fileSize) else {
                throw UpdateError.downloadFailed
            }

            try FileManager.default.moveItem(at: temporaryDownloadURL, to: zipPath)
            downloadedFileURL = nil
            installState = .downloading(progress: 1.0)
            return zipPath
        } catch {
            if let downloadedFileURL {
                try? FileManager.default.removeItem(at: downloadedFileURL)
            }
            try? FileManager.default.removeItem(at: tempDir)
            throw error
        }
    }

    nonisolated static func validateArchiveEntries(
        _ output: String,
        expectedCount: Int
    ) throws {
        try UpdateInstaller.validateArchiveEntries(output, expectedCount: expectedCount)
    }

    nonisolated static func validateArchiveEntryTypes(
        _ output: String,
        expectedCount: Int
    ) throws {
        try UpdateInstaller.validateArchiveEntryTypes(output, expectedCount: expectedCount)
    }

    func verifyUpdateCandidate(at appPath: URL, expectedVersion: String) throws {
        try UpdateInstaller.verifyUpdateCandidate(
            at: appPath,
            expectedVersion: expectedVersion,
            currentAppPath: currentAppPath,
            processRunner: processRunner
        )
    }

    func verifyUpdateCandidate(at appPath: URL) throws {
        try UpdateInstaller.verifyUpdateCandidate(
            at: appPath,
            expectedVersion: nil,
            currentAppPath: currentAppPath,
            processRunner: processRunner
        )
    }

    func replaceAndRelaunch(with newAppPath: URL) async throws {
        try await replaceAndRelaunch(with: newAppPath, expectedVersion: nil)
    }

    private func replaceAndRelaunch(
        with newAppPath: URL,
        expectedVersion: String?
    ) async throws {
        let currentAppURL = URL(fileURLWithPath: currentAppPath)
        let currentAppParentURL = currentAppURL.deletingLastPathComponent()
        let backupPath = currentAppPath + ".old"
        let backupURL = URL(fileURLWithPath: backupPath)
        let stagedAppURL = currentAppParentURL.appendingPathComponent(
            ".Octodot.update-stage.app",
            isDirectory: true
        )
        // Copy across any volume boundary off-main while the current app remains
        // intact. The subsequent replacement uses only sibling renames on the
        // destination volume.
        do {
            try await Task.detached(priority: .utility) {
                do {
                    if FileManager.default.fileExists(atPath: stagedAppURL.path) {
                        try FileManager.default.removeItem(at: stagedAppURL)
                    }
                    try FileManager.default.copyItem(at: newAppPath, to: stagedAppURL)
                } catch {
                    try? FileManager.default.removeItem(at: stagedAppURL)
                    throw error
                }
            }.value
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: stagedAppURL)
            throw CancellationError()
        } catch {
            try? FileManager.default.removeItem(at: stagedAppURL)
            throw UpdateError.replacementFailed
        }
        let fm = FileManager.default
        defer {
            if fm.fileExists(atPath: stagedAppURL.path) {
                try? fm.removeItem(at: stagedAppURL)
            }
        }
        try Task.checkCancellation()

        if let expectedVersion {
            let processRunner = self.processRunner
            let currentAppPath = self.currentAppPath
            try await Task.detached(priority: .userInitiated) {
                try UpdateInstaller.verifyUpdateCandidate(
                    at: stagedAppURL,
                    expectedVersion: expectedVersion,
                    currentAppPath: currentAppPath,
                    processRunner: processRunner
                )
            }.value
            try Task.checkCancellation()
        }

        do {
            if fm.fileExists(atPath: backupPath) {
                try fm.removeItem(at: backupURL)
            }
            try fm.moveItem(at: currentAppURL, to: backupURL)
        } catch {
            throw UpdateError.replacementFailed
        }

        do {
            try fm.moveItem(at: stagedAppURL, to: currentAppURL)
        } catch {
            do {
                try fm.moveItem(at: backupURL, to: currentAppURL)
            } catch {
                throw UpdateError.rollbackFailed
            }
            throw UpdateError.replacementFailed
        }

        do {
            try await appRelauncher(currentAppURL)
        } catch {
            do {
                if fm.fileExists(atPath: currentAppPath) {
                    try fm.removeItem(at: currentAppURL)
                }
                try fm.moveItem(at: backupURL, to: currentAppURL)
            } catch {
                throw UpdateError.rollbackFailed
            }
            throw UpdateError.relaunchFailed
        }

        try? fm.removeItem(at: backupURL)
        isTerminatingAfterSuccessfulUpdate = true
        appTerminator()
    }

}

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: String
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case draft
        case prerelease
        case assets
    }
}
