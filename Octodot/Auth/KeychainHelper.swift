import Foundation
import Security

enum KeychainHelper {
    private static let service = "com.octodot.app.github-token"
    private static let account = "github-token"

    private static var legacyTokenURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Octodot", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(".token")
    }

#if DEBUG
    private static var debugTokenURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Octodot", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(".debug-token")
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

        guard let token = String(data: data, encoding: .utf8), !token.isEmpty else {
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
        guard let data = token.data(using: .utf8), !data.isEmpty else {
            throw KeychainError.invalidData
        }

        var addQuery = itemQuery(service: service, account: account)
        addQuery[kSecValueData as String] = data

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let attributesToUpdate = [kSecValueData as String: data] as CFDictionary
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
        return String(data: data, encoding: .utf8)
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
        guard let data = token.data(using: .utf8), !data.isEmpty else {
            throw KeychainError.invalidData
        }
        try data.write(to: debugTokenURL, options: .atomic)
    }

    private static func loadDebugToken() -> String? {
        guard let data = try? Data(contentsOf: debugTokenURL),
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else {
            return nil
        }
        return token
    }
#endif

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
