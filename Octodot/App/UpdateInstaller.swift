import Foundation

enum UpdateInstaller {
    static let maximumExtractedSize = 1024 * 1024 * 1024
    static let maximumArchiveEntries = 50_000

    struct ProcessResult: Sendable {
        let status: Int32
        let output: String
    }

    typealias ProcessRunner = @Sendable (_ executablePath: String, _ arguments: [String]) throws -> ProcessResult

    private struct CodeSignatureIdentity: Equatable {
        let bundleIdentifier: String
        let teamIdentifier: String
    }

    static let systemProcessRunner: ProcessRunner = { executablePath, arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        process.environment = environment

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return ProcessResult(
            status: process.terminationStatus,
            output: String(decoding: outputData, as: UTF8.self)
        )
    }

    static func extractApp(
        from zipPath: URL,
        processRunner: ProcessRunner
    ) throws -> URL {
        let extractDir = zipPath.deletingLastPathComponent()
            .appendingPathComponent("extract", isDirectory: true)
        try? FileManager.default.removeItem(at: extractDir)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

        let summary = try processRunner("/usr/bin/zipinfo", ["-t", zipPath.path])
        guard summary.status == 0 else {
            throw UpdateError.extractionFailed
        }
        let summaryValues = try archiveSummary(from: summary.output)
        guard summaryValues.entryCount <= maximumArchiveEntries,
              summaryValues.uncompressedSize <= maximumExtractedSize else {
            throw UpdateError.extractionFailed
        }

        let listing = try processRunner("/usr/bin/zipinfo", ["-1", zipPath.path])
        guard listing.status == 0 else {
            throw UpdateError.extractionFailed
        }
        try validateArchiveEntries(listing.output, expectedCount: summaryValues.entryCount)

        let typeListing = try processRunner("/usr/bin/zipinfo", ["-l", zipPath.path])
        guard typeListing.status == 0 else {
            throw UpdateError.extractionFailed
        }
        try validateArchiveEntryTypes(typeListing.output, expectedCount: summaryValues.entryCount)

        let result = try processRunner("/usr/bin/ditto", ["-x", "-k", zipPath.path, extractDir.path])

        guard result.status == 0 else {
            throw UpdateError.extractionFailed
        }

        let appPath = extractDir.appendingPathComponent("Octodot.app")
        let resourceValues = try? appPath.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard FileManager.default.fileExists(atPath: appPath.path),
              resourceValues?.isDirectory == true,
              resourceValues?.isSymbolicLink != true else {
            throw UpdateError.appBundleNotFound
        }
        return appPath
    }

    private static func archiveSummary(
        from output: String
    ) throws -> (entryCount: Int, uncompressedSize: Int) {
        let fields = output.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 4,
              let entryCount = Int(fields[0]),
              fields[1] == "file," || fields[1] == "files,",
              let uncompressedSize = Int(fields[2]),
              fields[3] == "bytes",
              entryCount > 0,
              uncompressedSize > 0 else {
            throw UpdateError.extractionFailed
        }
        return (entryCount, uncompressedSize)
    }

    static func validateArchiveEntries(
        _ output: String,
        expectedCount: Int
    ) throws {
        let entries = output.split(
            omittingEmptySubsequences: false,
            whereSeparator: \.isNewline
        )
        let normalizedEntries = entries.last?.isEmpty == true ? Array(entries.dropLast()) : Array(entries)
        guard normalizedEntries.count == expectedCount,
              normalizedEntries.contains(where: { $0 == "Octodot.app/" }) else {
            throw UpdateError.extractionFailed
        }

        for entry in normalizedEntries {
            let name = String(entry)
            guard !name.isEmpty,
                  !name.hasPrefix("/"),
                  !name.contains("\\"),
                  !name.contains(":"),
                  !name.unicodeScalars.contains(where: { $0.value == 0 }) else {
                throw UpdateError.extractionFailed
            }

            let pathComponents = name.split(
                separator: "/",
                omittingEmptySubsequences: false
            )
            let meaningfulComponents = pathComponents.last?.isEmpty == true
                ? pathComponents.dropLast()
                : pathComponents[...]
            guard let topLevel = pathComponents.first,
                  topLevel == "Octodot.app" || topLevel == "__MACOSX",
                  meaningfulComponents.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                throw UpdateError.extractionFailed
            }
        }
    }

    static func validateArchiveEntryTypes(
        _ output: String,
        expectedCount: Int
    ) throws {
        let allowedEntryTypes: Set<Character> = ["-", "d"]
        let entryTypes = output.split(whereSeparator: \.isNewline).compactMap { line -> Character? in
            guard let permissions = line.split(maxSplits: 1, whereSeparator: \.isWhitespace).first,
                  permissions.count == 10,
                  let type = permissions.first,
                  "-dlcbps".contains(type) else {
                return nil
            }
            return type
        }
        guard entryTypes.count == expectedCount,
              entryTypes.allSatisfy(allowedEntryTypes.contains) else {
            throw UpdateError.extractionFailed
        }
    }

    static func verifyUpdateCandidate(
        at appPath: URL,
        expectedVersion: String?,
        currentAppPath: String,
        processRunner: ProcessRunner
    ) throws {
        let verifyResult = try processRunner("/usr/bin/codesign", ["--verify", "--deep", "--strict", appPath.path])
        guard verifyResult.status == 0 else {
            throw UpdateError.invalidSignature
        }

        let candidateDisplay = try processRunner("/usr/bin/codesign", ["--display", "--verbose=4", appPath.path])
        guard candidateDisplay.status == 0,
              let candidateIdentity = codeSignatureIdentity(from: candidateDisplay.output),
              isValidTeamIdentifier(candidateIdentity.teamIdentifier) else {
            throw UpdateError.invalidSignature
        }

        let currentVerify = try processRunner(
            "/usr/bin/codesign",
            ["--verify", "--deep", "--strict", currentAppPath]
        )
        guard currentVerify.status == 0 else {
            throw UpdateError.unverifiableCurrentSignature
        }

        let currentDisplay = try processRunner("/usr/bin/codesign", ["--display", "--verbose=4", currentAppPath])
        guard currentDisplay.status == 0,
              let currentIdentity = codeSignatureIdentity(from: currentDisplay.output),
              isValidTeamIdentifier(currentIdentity.teamIdentifier) else {
            throw UpdateError.unverifiableCurrentSignature
        }

        guard candidateIdentity == currentIdentity else {
            throw UpdateError.signatureIdentityMismatch
        }

        let assessment = try processRunner("/usr/sbin/spctl", ["--assess", "--type", "execute", "--verbose=4", appPath.path])
        guard assessment.status == 0 else {
            throw UpdateError.notarizationCheckFailed
        }

        if let expectedVersion {
            let infoPlist = appPath
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Info.plist")
            guard let data = try? Data(contentsOf: infoPlist),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
                  let dictionary = plist as? [String: Any],
                  let rawCandidateVersion = dictionary["CFBundleShortVersionString"] as? String,
                  let candidateVersion = SemanticVersion(rawCandidateVersion),
                  let expectedVersion = SemanticVersion(expectedVersion),
                  candidateVersion == expectedVersion else {
                throw UpdateError.versionMismatch
            }
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

    enum UpdateError: LocalizedError, Equatable {
        case downloadFailed
        case extractionFailed
        case appBundleNotFound
        case invalidSignature
        case signatureIdentityMismatch
        case unverifiableCurrentSignature
        case notarizationCheckFailed
        case untrustedDownloadURL
        case versionMismatch
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
            case .untrustedDownloadURL: "Update download URL is not trusted"
            case .versionMismatch: "Downloaded update version does not match the release"
            case .replacementFailed: "Failed to replace the app"
            case .relaunchFailed: "Failed to relaunch the update; the previous version was restored"
            case .rollbackFailed: "Failed to restore the previous version after update installation failed"
            }
        }
    }
}
