import Foundation
import Security

enum KeychainHelper {
    private static let service = "com.octodot.app.github-token"
    private static let account = "github-token"
    private static let trustedAccessRepairVersion = 1

    private static var legacyTokenURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Octodot", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(".token")
    }

    private static var shouldManageTrustedAccess: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
    }

    static func saveToken(_ token: String) throws {
        try saveToken(token, service: service, account: account)
        try? FileManager.default.removeItem(at: legacyTokenURL)
    }

    static func loadToken() -> String? {
        if let token = loadToken(service: service, account: account) {
            return token
        }

        guard let data = try? Data(contentsOf: legacyTokenURL),
              let token = String(data: data, encoding: .utf8) else {
            return nil
        }

        try? saveToken(token, service: service, account: account)
        try? FileManager.default.removeItem(at: legacyTokenURL)
        return token
    }

    static func deleteToken() {
        deleteToken(service: service, account: account)
        try? FileManager.default.removeItem(at: legacyTokenURL)
    }

    static func saveToken(_ token: String, service: String, account: String) throws {
        guard let data = token.data(using: .utf8) else {
            throw KeychainError.invalidData
        }
        guard !data.isEmpty else {
            throw KeychainError.invalidData
        }

        deleteToken(service: service, account: account)

        var item: SecKeychainItem?
        let addStatus = service.withCString { serviceCString in
            account.withCString { accountCString in
                data.withUnsafeBytes { bytes in
                    SecKeychainAddGenericPassword(
                        nil,
                        UInt32(service.utf8.count),
                        serviceCString,
                        UInt32(account.utf8.count),
                        accountCString,
                        UInt32(data.count),
                        bytes.baseAddress!,
                        &item
                    )
                }
            }
        }
        guard addStatus == errSecSuccess else {
            throw KeychainError.unhandledStatus(addStatus)
        }

        applyTrustedAccessIfPossible(to: item, service: service, account: account)
    }

    static func loadToken(service: String, account: String) -> String? {
        var passwordLength: UInt32 = 0
        var passwordData: UnsafeMutableRawPointer?
        var item: SecKeychainItem?

        let status = service.withCString { serviceCString in
            account.withCString { accountCString in
                SecKeychainFindGenericPassword(
                    nil,
                    UInt32(service.utf8.count),
                    serviceCString,
                    UInt32(account.utf8.count),
                    accountCString,
                    &passwordLength,
                    &passwordData,
                    &item
                )
            }
        }
        defer {
            if passwordData != nil {
                SecKeychainItemFreeContent(nil, passwordData)
            }
        }

        guard status != errSecItemNotFound else { return nil }
        guard status == errSecSuccess,
              let passwordData else { return nil }

        let data = Data(bytes: passwordData, count: Int(passwordLength))
        if let token = String(data: data, encoding: .utf8) {
            repairTrustedAccessIfNeeded(for: item, service: service, account: account)
            return token
        }
        return nil
    }

    static func deleteToken(service: String, account: String) {
        var item: SecKeychainItem?
        let status = service.withCString { serviceCString in
            account.withCString { accountCString in
                SecKeychainFindGenericPassword(
                    nil,
                    UInt32(service.utf8.count),
                    serviceCString,
                    UInt32(account.utf8.count),
                    accountCString,
                    nil,
                    nil,
                    &item
                )
            }
        }
        guard status == errSecSuccess, let item else { return }
        SecKeychainItemDelete(item)
        UserDefaults.standard.removeObject(forKey: trustedAccessRepairKey(service: service, account: account))
    }

    private static func createTrustedAccess(label: String) -> SecAccess? {
        var trustedApplication: SecTrustedApplication?
        let trustedApplicationStatus = Bundle.main.bundlePath.withCString { bundlePath in
            SecTrustedApplicationCreateFromPath(bundlePath, &trustedApplication)
        }
        guard trustedApplicationStatus == errSecSuccess,
              let trustedApplication else {
            return nil
        }

        let trustedApplications = [trustedApplication] as CFArray
        var access: SecAccess?
        let accessStatus = SecAccessCreate(label as CFString, trustedApplications, &access)
        guard accessStatus == errSecSuccess else {
            return nil
        }
        return access
    }

    private static func repairTrustedAccessIfNeeded(
        for item: SecKeychainItem?,
        service: String,
        account: String
    ) {
        guard shouldManageTrustedAccess else { return }
        guard let item else { return }

        let defaultsKey = trustedAccessRepairKey(service: service, account: account)
        guard UserDefaults.standard.bool(forKey: defaultsKey) == false else { return }

        if setTrustedAccess(item, label: "\(service):\(account)") {
            UserDefaults.standard.set(true, forKey: defaultsKey)
        }
    }

    private static func applyTrustedAccessIfPossible(
        to item: SecKeychainItem?,
        service: String,
        account: String
    ) {
        guard shouldManageTrustedAccess else { return }
        guard let item else { return }

        let defaultsKey = trustedAccessRepairKey(service: service, account: account)
        if setTrustedAccess(item, label: "\(service):\(account)") {
            UserDefaults.standard.set(true, forKey: defaultsKey)
        }
    }

    private static func setTrustedAccess(_ item: SecKeychainItem, label: String) -> Bool {
        guard let access = createTrustedAccess(label: label) else {
            return false
        }

        let accessStatus = SecKeychainItemSetAccess(item, access)
        return accessStatus == errSecSuccess
    }

    private static func trustedAccessRepairKey(service: String, account: String) -> String {
        "KeychainHelper.trustedAccessRepair.v\(trustedAccessRepairVersion).\(service).\(account)"
    }

    enum KeychainError: LocalizedError {
        case invalidData
        case unhandledStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .invalidData:
                return "Failed to encode token"
            case .unhandledStatus(let status):
                let message = SecCopyErrorMessageString(status, nil) as String?
                return message ?? "Keychain error (\(status))"
            }
        }
    }
}
