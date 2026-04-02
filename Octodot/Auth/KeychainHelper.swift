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
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteToken(service: String, account: String) {
        SecItemDelete(itemQuery(service: service, account: account) as CFDictionary)
    }

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
