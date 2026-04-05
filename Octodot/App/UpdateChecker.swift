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

    private var downloadURL: URL?
    private let session: any NetworkSession
    private let userDefaults: UserDefaults
    private let bundleVersion: String?

    init(
        session: any NetworkSession = URLSession.shared,
        userDefaults: UserDefaults = .standard,
        bundleVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    ) {
        self.session = session
        self.userDefaults = userDefaults
        self.bundleVersion = bundleVersion
    }

    func checkForUpdatesIfNeeded() {
        let lastCheck = userDefaults.double(forKey: Self.lastCheckDateKey)
        let elapsed = Date().timeIntervalSince1970 - lastCheck
        DebugTrace.log("update checkIfNeeded elapsed=\(Int(elapsed))s threshold=\(Int(Self.checkIntervalSeconds))s")
        guard elapsed >= Self.checkIntervalSeconds else { return }
        Task { await performCheck() }
    }

    func checkForUpdatesNow() {
        Task { await performCheck() }
    }

    func dismissUpdate() {
        guard let availableVersion else { return }
        userDefaults.set(availableVersion, forKey: Self.dismissedVersionKey)
        self.availableVersion = nil
        self.releaseURL = nil
        self.downloadURL = nil
    }

    func installUpdate() {
        guard let downloadURL else { return }
        Task { await performInstall(downloadURL: downloadURL) }
    }

    // MARK: - Check

    private func performCheck() async {
        guard !isChecking else { return }
        isChecking = true
        defer {
            isChecking = false
            userDefaults.set(Date().timeIntervalSince1970, forKey: Self.lastCheckDateKey)
        }

        do {
            let release = try await fetchLatestRelease()
            DebugTrace.log("update check got tag=\(release.tagName) current=\(bundleVersion ?? "nil") assets=\(release.assets.count)")
            applyRelease(release)
            DebugTrace.log("update check result: available=\(availableVersion ?? "nil")")
        } catch {
            DebugTrace.log("update check failed: \(error)")
        }
    }

    private func fetchLatestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: Self.releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, _) = try await session.data(for: request)
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    private func applyRelease(_ release: GitHubRelease) {
        guard !release.draft, !release.prerelease else { return }

        guard let remoteVersion = SemanticVersion(release.tagName),
              let currentVersion = bundleVersion.flatMap(SemanticVersion.init) else {
            return
        }

        guard remoteVersion > currentVersion else {
            availableVersion = nil
            releaseURL = nil
            downloadURL = nil
            return
        }

        let dismissedTag = userDefaults.string(forKey: Self.dismissedVersionKey)
        if let dismissedTag, let dismissed = SemanticVersion(dismissedTag), remoteVersion <= dismissed {
            return
        }

        availableVersion = remoteVersion.description
        releaseURL = URL(string: release.htmlURL)
        downloadURL = release.assets.first { $0.name.hasSuffix("-macos.zip") }
            .flatMap { URL(string: $0.browserDownloadURL) }
    }

    // MARK: - Install

    private func performInstall(downloadURL: URL) async {
        guard case .idle = installState else { return }
        installState = .downloading(progress: 0)

        do {
            let zipPath = try await downloadZip(from: downloadURL)
            installState = .installing
            let extractedAppPath = try extractApp(from: zipPath)
            try verifyCodeSignature(at: extractedAppPath)
            try replaceAndRelaunch(with: extractedAppPath)
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

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zipPath.path, extractDir.path]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw UpdateError.extractionFailed
        }

        let appPath = extractDir.appendingPathComponent("Octodot.app")
        guard FileManager.default.fileExists(atPath: appPath.path) else {
            throw UpdateError.appBundleNotFound
        }
        return appPath
    }

    private func verifyCodeSignature(at appPath: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--deep", "--strict", appPath.path]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw UpdateError.invalidSignature
        }
    }

    private func replaceAndRelaunch(with newAppPath: URL) throws {
        let currentAppPath = Bundle.main.bundlePath
        let currentAppURL = URL(fileURLWithPath: currentAppPath)
        let backupPath = currentAppPath + ".old"
        let fm = FileManager.default

        // Remove any leftover backup
        try? fm.removeItem(atPath: backupPath)

        // Move current app to backup
        try fm.moveItem(atPath: currentAppPath, toPath: backupPath)

        do {
            // Move new app into place
            try fm.moveItem(at: newAppPath, to: currentAppURL)
        } catch {
            // Restore from backup on failure
            try? fm.moveItem(atPath: backupPath, toPath: currentAppPath)
            throw UpdateError.replacementFailed
        }

        // Clean up backup and temp files
        try? fm.removeItem(atPath: backupPath)
        try? fm.removeItem(at: newAppPath.deletingLastPathComponent().deletingLastPathComponent())

        // Relaunch the new version
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: currentAppURL, configuration: config) { _, _ in
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    enum UpdateError: LocalizedError {
        case downloadFailed
        case extractionFailed
        case appBundleNotFound
        case invalidSignature
        case replacementFailed

        var errorDescription: String? {
            switch self {
            case .downloadFailed: "Download failed"
            case .extractionFailed: "Failed to extract update"
            case .appBundleNotFound: "Update archive is missing the app"
            case .invalidSignature: "Update has an invalid code signature"
            case .replacementFailed: "Failed to replace the app"
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
