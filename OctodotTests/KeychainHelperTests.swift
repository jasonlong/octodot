import Foundation
import Testing
@testable import Octodot

struct KeychainHelperTests {
    @Test func savesAndLoadsTokenFromKeychain() throws {
        let service = "com.octodot.tests.\(UUID().uuidString)"
        let account = UUID().uuidString
        defer { KeychainHelper.deleteToken(service: service, account: account) }

        try KeychainHelper.saveToken("ghp_test_token", service: service, account: account)

        #expect(KeychainHelper.loadToken(service: service, account: account) == "ghp_test_token")
    }

    @Test func saveTokenOverwritesExistingValue() throws {
        let service = "com.octodot.tests.\(UUID().uuidString)"
        let account = UUID().uuidString
        defer { KeychainHelper.deleteToken(service: service, account: account) }

        try KeychainHelper.saveToken("ghp_first", service: service, account: account)
        try KeychainHelper.saveToken("ghp_second", service: service, account: account)

        #expect(KeychainHelper.loadToken(service: service, account: account) == "ghp_second")
    }

    @Test func deleteTokenRemovesSavedValue() throws {
        let service = "com.octodot.tests.\(UUID().uuidString)"
        let account = UUID().uuidString

        try KeychainHelper.saveToken("ghp_delete_me", service: service, account: account)
        KeychainHelper.deleteToken(service: service, account: account)

        #expect(KeychainHelper.loadToken(service: service, account: account) == nil)
    }
}
