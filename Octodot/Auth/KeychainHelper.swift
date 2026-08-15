import Foundation
import Security

enum KeychainHelper {
    private static let service = "com.octodot.app.github-token"
    private static let account = "github-token"

    private static func normalizedToken(_ token: String) -> String? {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.utf8.count <= 4_096,
              normalized.utf8.allSatisfy({ (33...126).contains($0) }) else {
            return nil
        }
        return normalized
    }

    private static var applicationSupportDirectoryURL: URL {
        URL.applicationSupportDirectory
            .appendingPathComponent("Octodot", isDirectory: true)
    }

    private static var legacyTokenURL: URL {
        applicationSupportDirectoryURL.appendingPathComponent(".token")
    }

#if DEBUG
    private static var debugTokenURL: URL {
        applicationSupportDirectoryURL.appendingPathComponent(".debug-token")
    }
#endif

    static func saveToken(_ token: String) throws {
#if DEBUG
        try saveDebugToken(token)
#else
        try saveToken(token, service: service, account: account)
#endif
        removeLegacyTokenIfPresent()
    }

    static func loadToken() -> String? {
        hardenApplicationSupportDirectoryPermissionsIfPresent()
#if DEBUG
        if let token = loadDebugToken() {
            return token
        }
#endif
        if let token = loadToken(service: service, account: account) {
#if DEBUG
            do {
                try saveDebugToken(token)
            } catch {
                DebugTrace.log("keychain-debug-cache-save-failed error=\(error.localizedDescription)")
            }
#endif
            return token
        }

        guard FileManager.default.fileExists(atPath: legacyTokenURL.path) else {
            return nil
        }

        let data: Data
        do {
            data = try Data(contentsOf: legacyTokenURL)
        } catch {
            DebugTrace.log("keychain-legacy-token-read-failed error=\(error.localizedDescription)")
            return nil
        }

        guard let rawToken = String(data: data, encoding: .utf8),
              let token = normalizedToken(rawToken) else {
            DebugTrace.log("keychain-legacy-token-invalid")
            return nil
        }

        do {
            try saveToken(token)
            removeLegacyTokenIfPresent()
        } catch {
            DebugTrace.log("keychain-legacy-token-migration-failed error=\(error.localizedDescription)")
        }
        return token
    }

    static func deleteToken() {
        deleteToken(service: service, account: account)
        removeLegacyTokenIfPresent()
#if DEBUG
        removeDebugTokenIfPresent()
#endif
    }

    static func saveToken(_ token: String, service: String, account: String) throws {
        guard !service.isEmpty, !account.isEmpty,
              let token = normalizedToken(token),
              let data = token.data(using: .utf8) else {
            throw KeychainError.invalidData
        }

        var addQuery = itemQuery(service: service, account: account)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let attributesToUpdate = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ] as CFDictionary
            let updateStatus = SecItemUpdate(itemQuery(service: service, account: account) as CFDictionary, attributesToUpdate)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.unhandledStatus(updateStatus)
            }
        default:
            throw KeychainError.unhandledStatus(status)
        }
    }

    static func loadToken(service: String, account: String) -> String? {
        var query = itemQuery(service: service, account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            DebugTrace.log("keychain-load-failed service=\(service) account=\(account) status=\(status)")
            return nil
        }
        guard let token = String(data: data, encoding: .utf8),
              let normalized = normalizedToken(token) else {
            DebugTrace.log("keychain-load-invalid-data service=\(service) account=\(account)")
            return nil
        }
        return normalized
    }

    static func deleteToken(service: String, account: String) {
        let status = SecItemDelete(itemQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            DebugTrace.log("keychain-delete-failed service=\(service) account=\(account) status=\(status)")
            return
        }
    }

#if DEBUG
    private static func saveDebugToken(_ token: String) throws {
        guard let token = normalizedToken(token),
              let data = token.data(using: .utf8) else {
            throw KeychainError.invalidData
        }
        try prepareApplicationSupportDirectory()
        try data.write(to: debugTokenURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: debugTokenURL.path
        )
    }

    private static func loadDebugToken() -> String? {
        guard let data = try? Data(contentsOf: debugTokenURL),
              let token = String(data: data, encoding: .utf8),
              let normalized = normalizedToken(token) else {
            return nil
        }
        return normalized
    }
#endif

    private static func prepareApplicationSupportDirectory() throws {
        try FileManager.default.createDirectory(
            at: applicationSupportDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: applicationSupportDirectoryURL.path
        )
    }

    private static func hardenApplicationSupportDirectoryPermissionsIfPresent() {
        guard FileManager.default.fileExists(atPath: applicationSupportDirectoryURL.path) else {
            return
        }
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: applicationSupportDirectoryURL.path
            )
        } catch {
            DebugTrace.log("keychain-token-directory-permissions-failed error=\(error.localizedDescription)")
        }
    }

    private static func removeLegacyTokenIfPresent() {
        guard FileManager.default.fileExists(atPath: legacyTokenURL.path) else {
            return
        }

        do {
            try FileManager.default.removeItem(at: legacyTokenURL)
        } catch {
            DebugTrace.log("keychain-legacy-token-remove-failed error=\(error.localizedDescription)")
        }
    }

#if DEBUG
    private static func removeDebugTokenIfPresent() {
        guard FileManager.default.fileExists(atPath: debugTokenURL.path) else {
            return
        }

        do {
            try FileManager.default.removeItem(at: debugTokenURL)
        } catch {
            DebugTrace.log("keychain-debug-token-remove-failed error=\(error.localizedDescription)")
        }
    }
#endif

    private static func itemQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
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
