import Foundation
import Security

/// Secrets and provider URLs live in a flat JSON dictionary at
/// `<Application Support>/<AppName>/.settings` (0600). One-time migration
/// pulls legacy values out of the Keychain on first read.
enum AppSettingsStorage {
    private static let migrationKey = "keychain_migration_done"
    private static let fallbackAppName = "OmniFlow"
    private static let fallbackService = "com.nick8cyber.omniflow"

    static func load(account: String) -> String? {
        var dictionary = readDictionary()
        migrateFromKeychainIfNeeded(account: account, dictionary: &dictionary)
        return dictionary[account]
    }

    static func save(_ value: String, account: String) {
        var dictionary = readDictionary()
        dictionary[account] = value
        writeDictionary(dictionary)
    }

    static func delete(account: String) {
        var dictionary = readDictionary()
        dictionary.removeValue(forKey: account)
        writeDictionary(dictionary)
    }

    // MARK: - File plumbing

    private static var settingsURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent(appName, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true,
                                                 attributes: nil)
        return directory.appendingPathComponent(".settings")
    }

    private static var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? fallbackAppName
    }

    private static func readDictionary() -> [String: String] {
        guard let data = try? Data(contentsOf: settingsURL),
              let dictionary = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dictionary
    }

    private static func writeDictionary(_ dictionary: [String: String]) {
        guard let data = try? JSONEncoder().encode(dictionary) else { return }
        try? data.write(to: settingsURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: settingsURL.path)
    }

    // MARK: - Keychain migration

    private static func migrateFromKeychainIfNeeded(account: String,
                                                    dictionary: inout [String: String]) {
        guard dictionary[migrationKey] == nil else { return }
        let service = Bundle.main.bundleIdentifier ?? fallbackService
        if let data = keychainData(account: account, service: service),
           let value = String(data: data, encoding: .utf8) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                dictionary[account] = value
                dictionary[migrationKey] = "true"
                writeDictionary(dictionary)
                SecItemDelete(keychainQuery(account: account, service: service) as CFDictionary)
                return
            }
        }
        dictionary[migrationKey] = "true"
        writeDictionary(dictionary)
    }

    private static func keychainQuery(account: String, service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private static func keychainData(account: String, service: String) -> Data? {
        var query = keychainQuery(account: account, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }
}
