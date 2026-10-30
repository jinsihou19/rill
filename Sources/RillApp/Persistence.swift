import Foundation
import Security
import RillCore

struct KeychainStore {
    private let service = "app.rill.redis.credentials"
    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }
    func password(for id: UUID) throws -> String {
        var query = query(id); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data, let password = String(data: data, encoding: .utf8) else {
            throw failure(status)
        }
        return password
    }
    func set(_ password: String, for id: UUID) throws {
        if password.isEmpty { try remove(id); return }
        let attributes = [kSecValueData as String: Data(password.utf8)]
        let status = SecItemUpdate(query(id) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var record = query(id); record[kSecValueData as String] = Data(password.utf8)
            record[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let inserted = SecItemAdd(record as CFDictionary, nil)
            guard inserted == errSecSuccess else { throw failure(inserted) }
        } else if status != errSecSuccess { throw failure(status) }
    }
    func remove(_ id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }
    private func failure(_ status: OSStatus) -> RedisError {
        RedisError.message("无法访问钥匙串：\(SecCopyErrorMessageString(status, nil) as String? ?? String(status))。")
    }
}

struct ProfileStore {
    private let directory: URL
    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Rill", isDirectory: true)) {
        self.directory = directory
    }
    private var file: URL { directory.appendingPathComponent("connections.json") }
    func load() throws -> [ConnectionProfile] {
        guard FileManager.default.fileExists(atPath: file.path) else {
            let initial = [ConnectionProfile()]; try save(initial); return initial
        }
        let profiles = try JSONDecoder().decode([ConnectionProfile].self, from: Data(contentsOf: file))
        guard Set(profiles.map(\.id)).count == profiles.count else { throw RedisError.message("连接配置中存在重复 ID。请检查 connections.json。") }
        return profiles
    }
    func save(_ profiles: [ConnectionProfile]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profiles).write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

struct BrowserPreferences: Codable, Equatable {
    var separator = ":"
    var grouped = true
    var expansion: [String: Bool] = [:]
}

struct BrowserPreferencesStore {
    var defaults = UserDefaults.standard
    private func key(_ profile: ConnectionProfile) -> String { "browser.\(profile.id.uuidString).db\(profile.database)" }
    func load(_ profile: ConnectionProfile) -> BrowserPreferences {
        guard let data = defaults.data(forKey: key(profile)), let value = try? JSONDecoder().decode(BrowserPreferences.self, from: data),
              !value.separator.isEmpty, value.separator.utf8.count <= 16 else { return BrowserPreferences() }
        return value
    }
    func save(_ value: BrowserPreferences, for profile: ConnectionProfile) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key(profile)) }
    }
}
