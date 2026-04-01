import Foundation

enum KeychainHelper {
    private static var tokenURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Octodot", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(".token")
    }

    static func saveToken(_ token: String) throws {
        let data = Data(token.utf8)
        try data.write(to: tokenURL, options: [.atomic, .completeFileProtection])
    }

    static func loadToken() -> String? {
        guard let data = try? Data(contentsOf: tokenURL) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteToken() {
        try? FileManager.default.removeItem(at: tokenURL)
    }
}
