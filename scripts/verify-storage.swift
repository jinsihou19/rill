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
        print("PASS: profile round trip, 0600 permissions, no password in JSON; native Keychain create/read/update/delete.")
    }
}
