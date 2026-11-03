import Foundation
import RillCore

@main
struct VerifyStorage {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rill-storage-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profiles = ProfileStore(directory: directory)
        var list = try profiles.load()
        precondition(list.count == 1)
        list.append(ConnectionProfile(name: "Storage fixture", tls: true, readOnly: true))
        try profiles.save(list)
        let loaded = try profiles.load(); precondition(loaded == list)
        let file = directory.appendingPathComponent("connections.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let json = try Data(contentsOf: file); precondition(!String(decoding: json, as: UTF8.self).contains("password"))
        let keychain = KeychainStore(), id = UUID(), secret = "Synthetic-Rill-Fixture-" + UUID().uuidString
        defer { try? keychain.remove(id) }
        try keychain.set(secret, for: id)
        let read = try keychain.password(for: id); precondition(read == secret)
        try keychain.set(secret + "-updated", for: id)
        let updated = try keychain.password(for: id); precondition(updated == secret + "-updated")
        try keychain.set("", for: id)
        let removed = try keychain.password(for: id); precondition(removed == "")
        let suite = "rill-preferences-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let browser = BrowserPreferencesStore(defaults: defaults)
        precondition(BrowserPreferences().searchMode == .fuzzy)
        var preferences = BrowserPreferences(); preferences.separator = "::"; preferences.expansion["folder:test"] = false
        preferences.searchMode = .hex; preferences.search = "00 FF"; preferences.kind = "string"
        preferences.selectedKey = Data([0, 255]); preferences.codec = .base64Gzip; preferences.format = "JSON"
        preferences.searches = [SavedKeySearch(mode: .fuzzy, text: " literal * key ", kind: "")]
        let legacy = try JSONDecoder().decode(BrowserPreferences.self, from: Data(#"{"separator":"/","grouped":false,"expansion":{}}"#.utf8))
        precondition(legacy.separator == "/" && legacy.searchMode == .pattern && legacy.searches.isEmpty)
        var exact = preferences; exact.searchMode = .exact; exact.searches[0].mode = .exact
        let migrated = try JSONDecoder().decode(BrowserPreferences.self, from: JSONEncoder().encode(exact))
        precondition(migrated.searchMode == .fuzzy && migrated.search == exact.search)
        precondition(migrated.searches[0].mode == .fuzzy && migrated.searches[0].text == exact.searches[0].text)
        browser.save(preferences, for: list[0]); precondition(browser.load(list[0]) == preferences)
        var otherDB = list[0]; otherDB.database = 1
        precondition(browser.load(otherDB) == BrowserPreferences())
        precondition(browser.load(list[1]) == BrowserPreferences())
        print("PASS: profile round trip, 0600 permissions, no password in JSON; native Keychain CRUD; browser search/selection/codec preferences isolated by connection and DB, legacy decoding.")
    }
}
