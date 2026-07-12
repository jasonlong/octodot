import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class UpdateChecker {
    private static let lastCheckDateKey = "UpdateChecker.lastCheckDate.v1"
    private static let dismissedVersionKey = "UpdateChecker.dismissedVersion.v1"
    private static let checkIntervalSeconds: TimeInterval = 24 * 60 * 60
    private static let releasesURL = URL(string: "https://api.github.com/repos/jasonlong/octodot/releases/latest")!

    struct ProcessResult: Sendable {
        let status: Int32
        let output: String
    }

    typealias ProcessRunner = @Sendable (_ executablePath: String, _ arguments: [String]) throws -> ProcessResult
    typealias AppRelauncher = @MainActor (URL) async throws -> Void
    typealias AppTerminator = @MainActor () -> Void

    private struct CodeSignatureIdentity: Equatable {
        let bundleIdentifier: String
        let teamIdentifier: String
    }

    private enum CheckError: Error {
        case invalidResponse
    }

    enum InstallState: Equatable {
        case idle
        case downloading(progress: Double)
        case installing
        case failed(String)
    }

    private(set) var availableVersion: String?
    private(set) var releaseURL: URL?
    private(set) var isChecking = false
    private(set) var installState: InstallState = .idle
    private(set) var showingUpToDate = false

    private var downloadURL: URL?
    private var upToDateDismissTask: Task<Void, Never>?
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
        processRunner: @escaping ProcessRunner = UpdateChecker.defaultProcessRunner,
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

    private static func defaultProcessRunner(_ executablePath: String, _ arguments: [String]) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        return ProcessResult(status: process.terminationStatus, output: output + errorOutput)
    }

    func checkForUpdatesIfNeeded() {
        let lastCheck = userDefaults.double(forKey: Self.lastCheckDateKey)
        let elapsed = Date().timeIntervalSince1970 - lastCheck
        guard elapsed >= Self.checkIntervalSeconds else { return }
        Task { await performCheck() }
    }

    func checkForUpdatesNow() {
        Task { await performCheck(showUpToDate: true) }
    }

    var canInstallUpdate: Bool {
        availableVersion != nil && downloadURL != nil
    }

    func dismissUpdate() {
        guard let availableVersion else { return }
        userDefaults.set(availableVersion, forKey: Self.dismissedVersionKey)
        clearAvailableUpdate()
        installState = .idle
    }

    func installUpdate() {
        guard canInstallUpdate, let downloadURL else {
            installState = .failed("Update download is unavailable")
            return
        }
        Task { await performInstall(downloadURL: downloadURL) }
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
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            showingUpToDate = false
        }
    }

    private func fetchLatestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: Self.releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw CheckError.invalidResponse
        }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    @discardableResult
    private func applyRelease(_ release: GitHubRelease) -> Bool {
        guard !release.draft, !release.prerelease else { return true }

        guard let remoteVersion = SemanticVersion(release.tagName),
              let currentVersion = bundleVersion.flatMap(SemanticVersion.init) else {
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

        guard let assetURL = Self.macOSAssetURL(from: release) else {
            clearAvailableUpdate()
            clearInstallFailure()
            return true
        }

        availableVersion = remoteVersion.description
        releaseURL = URL(string: release.htmlURL)
        downloadURL = assetURL
        clearInstallFailure()
        return true
    }

    private static func macOSAssetURL(from release: GitHubRelease) -> URL? {
        release.assets.first { $0.name.hasSuffix("-macos.zip") }
            .flatMap { URL(string: $0.browserDownloadURL) }
    }

    private func clearAvailableUpdate() {
        availableVersion = nil
        releaseURL = nil
        downloadURL = nil
    }

    // MARK: - Install

    private func performInstall(downloadURL: URL) async {
        switch installState {
        case .idle, .failed:
            break
        case .downloading, .installing:
            return
        }
        installState = .downloading(progress: 0)

        do {
            let zipPath = try await downloadZip(from: downloadURL)
            installState = .installing
            let extractedAppPath = try extractApp(from: zipPath)
            try verifyUpdateCandidate(at: extractedAppPath)
            try await replaceAndRelaunch(with: extractedAppPath)
        } catch {
            installState = .failed(error.localizedDescription)
        }
    }

    private func downloadZip(from url: URL) async throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.octodot.update", isDirectory: true)
        try? FileManager.default.removeItem(at: tempDir)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let zipPath = tempDir.appendingPathComponent("Octodot-update.zip")
        var request = URLRequest(url: url)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.downloadFailed
        }
        try data.write(to: zipPath)
        installState = .downloading(progress: 1.0)
        return zipPath
    }

    private func extractApp(from zipPath: URL) throws -> URL {
        let extractDir = zipPath.deletingLastPathComponent()
            .appendingPathComponent("extract", isDirectory: true)
        try? FileManager.default.removeItem(at: extractDir)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

        let result = try processRunner("/usr/bin/ditto", ["-x", "-k", zipPath.path, extractDir.path])

        guard result.status == 0 else {
            throw UpdateError.extractionFailed
        }

        let appPath = extractDir.appendingPathComponent("Octodot.app")
        guard FileManager.default.fileExists(atPath: appPath.path) else {
            throw UpdateError.appBundleNotFound
        }
        return appPath
    }

    func verifyUpdateCandidate(at appPath: URL) throws {
        let verifyResult = try processRunner("/usr/bin/codesign", ["--verify", "--deep", "--strict", appPath.path])
        guard verifyResult.status == 0 else {
            throw UpdateError.invalidSignature
        }

        let candidateDisplay = try processRunner("/usr/bin/codesign", ["--display", "--verbose=4", appPath.path])
        guard candidateDisplay.status == 0,
              let candidateIdentity = Self.codeSignatureIdentity(from: candidateDisplay.output),
              Self.isValidTeamIdentifier(candidateIdentity.teamIdentifier) else {
            throw UpdateError.invalidSignature
        }

        let currentDisplay = try processRunner("/usr/bin/codesign", ["--display", "--verbose=4", currentAppPath])
        guard currentDisplay.status == 0,
              let currentIdentity = Self.codeSignatureIdentity(from: currentDisplay.output),
              Self.isValidTeamIdentifier(currentIdentity.teamIdentifier) else {
            throw UpdateError.unverifiableCurrentSignature
        }

        guard candidateIdentity == currentIdentity else {
            throw UpdateError.signatureIdentityMismatch
        }

        let assessment = try processRunner("/usr/sbin/spctl", ["--assess", "--type", "execute", "--verbose=4", appPath.path])
        guard assessment.status == 0 else {
            throw UpdateError.notarizationCheckFailed
        }
    }

    private static func codeSignatureIdentity(from output: String) -> CodeSignatureIdentity? {
        var identifier: String?
        var teamIdentifier: String?

        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("Identifier=") {
                identifier = String(trimmed.dropFirst("Identifier=".count))
            } else if trimmed.hasPrefix("TeamIdentifier=") {
                teamIdentifier = String(trimmed.dropFirst("TeamIdentifier=".count))
            }
        }

        guard let identifier, !identifier.isEmpty,
              let teamIdentifier else {
            return nil
        }

        return CodeSignatureIdentity(bundleIdentifier: identifier, teamIdentifier: teamIdentifier)
    }

    private static func isValidTeamIdentifier(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.lowercased() != "not set"
    }

    func replaceAndRelaunch(with newAppPath: URL) async throws {
        let currentAppURL = URL(fileURLWithPath: currentAppPath)
        let backupPath = currentAppPath + ".old"
        let backupURL = URL(fileURLWithPath: backupPath)
        let fm = FileManager.default

        try? fm.removeItem(at: backupURL)
        try fm.moveItem(at: currentAppURL, to: backupURL)

        do {
            try fm.moveItem(at: newAppPath, to: currentAppURL)
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
        try? fm.removeItem(at: newAppPath.deletingLastPathComponent().deletingLastPathComponent())
        appTerminator()
    }

    enum UpdateError: LocalizedError, Equatable {
        case downloadFailed
        case extractionFailed
        case appBundleNotFound
        case invalidSignature
        case signatureIdentityMismatch
        case unverifiableCurrentSignature
        case notarizationCheckFailed
        case replacementFailed
        case relaunchFailed
        case rollbackFailed

        var errorDescription: String? {
            switch self {
            case .downloadFailed: "Download failed"
            case .extractionFailed: "Failed to extract update"
            case .appBundleNotFound: "Update archive is missing the app"
            case .invalidSignature: "Update has an invalid code signature"
            case .signatureIdentityMismatch: "Update signature does not match Octodot"
            case .unverifiableCurrentSignature: "Current app signature could not be verified"
            case .notarizationCheckFailed: "Update was not accepted by Gatekeeper"
            case .replacementFailed: "Failed to replace the app"
            case .relaunchFailed: "Failed to relaunch the update; the previous version was restored"
            case .rollbackFailed: "Failed to restore the previous version after update installation failed"
            }
        }
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
