import Foundation
import CryptoKit
import Darwin

public struct KeyExportHeader: Codable, Sendable {
    public let version: Int
    public let keyBase64: String
    public let kind: KeyKind
    public let count: Int64
    public let collectedAt: Date
    public let consistency: String
    public let expiryMode: String
    public let expiresAtUnixMilliseconds: Int64?
    public let excludedState: [String]
}
public struct KeyExportEntry: Codable, Sendable {
    public var offset: Int64?
    public var index: Int?
    public var field: Data?
    public var value: Data?
    public var score: String?
    public var streamFields: [Data]?
}
public struct KeyExportFooter: Codable, Sendable {
    public let complete: Bool
    public let entries: Int
    public let payloadBytes: Int64
    public let sha256: String
    public let finishedAt: Date
    public let failure: String?
}
public struct KeyExportLine: Codable, Sendable {
    public enum Record: String, Codable, Sendable { case header, entry, footer }
    public let record: Record
    public var header: KeyExportHeader?
    public var entry: KeyExportEntry?
    public var footer: KeyExportFooter?
}
public struct KeyExportLimits: Sendable {
    public var maximumFileBytes = 256 * 1024 * 1024
    public var maximumRecords = 1_000_000
    public var maximumPages = 10_000
    public var milliseconds = 60_000
    public init() {}
}
public struct KeyExportProgress: Sendable {
    public let entries: Int
    public let fileBytes: Int
    public let payloadBytes: Int64
}
public struct KeyExportResult: Sendable {
    public let url: URL
    public let footer: KeyExportFooter
}

public enum KeyExporter {
    public static func export(key: Data, database: RedisDatabase, limits: KeyExportLimits = KeyExportLimits(),
                              write: @Sendable (Data) throws -> Void,
                              update: @Sendable (KeyExportProgress) async -> Void = { _ in }) async throws -> KeyExportFooter {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(max(1, limits.milliseconds)))
        var bytes = 0, entries = 0, pages = 0, payload: Int64 = 0, digest = SHA256()
        func emit(_ line: KeyExportLine, footer: Bool = false) throws {
            var data = try encoder.encode(line); data.append(10)
            guard data.count <= 1024 * 1024, bytes + data.count <= max(4096, limits.maximumFileBytes) - (footer ? 0 : 2048) else {
                throw RedisError.message("导出超过文件或单条 1 MiB 上限。")
            }
            try write(data); bytes += data.count
            if !footer { digest.update(data: data) }
        }
        func checkBudget(newPage: Bool = false) throws {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline, (newPage ? pages < max(1, limits.maximumPages) : pages <= max(1, limits.maximumPages)), entries <= max(1, limits.maximumRecords) else {
                throw RedisError.message("导出达到时间、分页或条数预算，文件不完整。")
            }
        }
        func emitEntry(_ entry: KeyExportEntry) throws {
            try checkBudget()
            guard entries < max(1, limits.maximumRecords) else { throw RedisError.message("导出达到记录条数上限，文件不完整。") }
            try emit(KeyExportLine(record: .entry, entry: entry)); entries += 1
            payload += Int64((entry.field?.count ?? 0) + (entry.value?.count ?? 0) + (entry.streamFields?.reduce(0) { $0 + $1.count } ?? 0))
        }
        var failure: String?
        do {
            try checkBudget()
            let before = try await fingerprint(key, database: database)
            let expiry = try await expiration(key, database: database)
            try emit(KeyExportLine(record: .header, header: KeyExportHeader(version: 1, keyBase64: key.base64EncodedString(), kind: before.kind, count: before.count,
                         collectedAt: Date(), consistency: "live-segmented-read-not-snapshot", expiryMode: expiry.0, expiresAtUnixMilliseconds: expiry.1,
                         excludedState: ["stream-consumer-groups-and-PEL", "hash-field-expiration", "module-and-server-internal-state"])))
            if before.kind == .string {
                var offset: Int64 = 0
                while offset < before.count {
                    try checkBudget(newPage: true); pages += 1
                    let end = min(offset + 256 * 1024, before.count)
                    let result = try await database.wire.execute([Data("GETRANGE".utf8), key, Data(String(offset).utf8), Data(String(end - 1).utf8)])
                    guard let data = result.data, data.count == end - offset else { throw RedisError.message("导出期间 String 长度变化或键已消失。") }
                    try emitEntry(KeyExportEntry(offset: offset, value: data)); offset = end
                    await update(KeyExportProgress(entries: entries, fileBytes: bytes, payloadBytes: payload))
                }
            } else {
                var cursor = "0", offset = 0, seen: Set<Data> = [], identityBytes = 0
                var query = MemberQuery(); query.newestFirst = false
                if before.kind == .stream {
                    let last = try await database.wire.execute([Data("XREVRANGE".utf8), key, Data("+".utf8), Data("-".utf8), Data("COUNT".utf8), Data("1".utf8)])
                    if let id = last.elements?.first?.elements?.first?.string { query.streamEnd = id }
                }
                while true {
                    try checkBudget(newPage: true); pages += 1
                    let page = try await database.inspect(key, cursor: cursor, offset: offset, query: query)
                    guard page.key.kind == before.kind else { throw RedisError.message("导出期间数据类型已变化。") }
                    for row in page.rows {
                        if [.hash, .set, .zset].contains(before.kind) {
                            if seen.contains(row.field) { continue }
                            guard identityBytes + row.field.count <= 32 * 1024 * 1024 else { throw RedisError.message("成员去重身份超过 32 MiB，导出不完整。") }
                            seen.insert(row.field); identityBytes += row.field.count
                        }
                        let entry: KeyExportEntry
                        switch before.kind {
                        case .hash: entry = KeyExportEntry(field: row.field, value: row.value)
                        case .set: entry = KeyExportEntry(value: row.value)
                        case .zset: entry = KeyExportEntry(field: row.field, score: row.score)
                        case .list: entry = KeyExportEntry(index: row.index, value: row.value)
                        case .stream: entry = KeyExportEntry(field: row.field, streamFields: row.streamFields)
                        default: throw RedisError.message("此类型尚不支持完整导出。")
                        }
                        try emitEntry(entry)
                    }
                    await update(KeyExportProgress(entries: entries, fileBytes: bytes, payloadBytes: payload))
                    cursor = page.cursor; offset = page.nextOffset
                    if !page.hasMore { break }
                }
                guard Int64(entries) == before.count else { throw RedisError.message("读取成员数量与开始时不同，数据可能已变化。") }
            }
            try Task.checkCancellation()
            let after = try await fingerprint(key, database: database)
            guard before.kind == after.kind, before.count == after.count else { throw RedisError.message("导出前后类型/长度变化，文件不完整。") }
        } catch {
            failure = error is CancellationError ? "用户停止，文件不完整。" : String(error.localizedDescription.prefix(500))
        }
        let footer = KeyExportFooter(complete: failure == nil, entries: entries, payloadBytes: payload,
                                     sha256: digest.finalize().map { String(format: "%02x", $0) }.joined(), finishedAt: Date(), failure: failure)
        try emit(KeyExportLine(record: .footer, footer: footer), footer: true)
        return footer
    }

    public static func exportFile(key: Data, database: RedisDatabase, destination: URL, limits: KeyExportLimits = KeyExportLimits(),
                                  update: @Sendable (KeyExportProgress) async -> Void = { _ in }) async throws -> KeyExportResult {
        let partial = destination.appendingPathExtension(UUID().uuidString + ".partial")
        guard FileManager.default.createFile(atPath: partial.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw RedisError.message("无法创建导出文件。") }
        let handle = try FileHandle(forWritingTo: partial)
        do {
            let footer = try await export(key: key, database: database, limits: limits, write: { try handle.write(contentsOf: $0) }, update: update)
            try handle.synchronize(); try handle.close()
            if footer.complete {
                guard Darwin.rename(partial.path, destination.path) == 0 else { throw RedisError.message("无法完成导出文件替换：\(String(cString: strerror(errno)))") }
                return KeyExportResult(url: destination, footer: footer)
            }
            return KeyExportResult(url: partial, footer: footer)
        } catch {
            try? handle.close()
            throw RedisError.message("导出失败：\(error.localizedDescription)\n未完成文件：\(partial.path)")
        }
    }

    private static func fingerprint(_ key: Data, database: RedisDatabase) async throws -> (kind: KeyKind, count: Int64) {
        let type = try await database.wire.execute([Data("TYPE".utf8), key])
        guard let name = type.string, let kind = KeyKind(rawValue: name), kind != .unknown else { throw RedisError.message("键已消失或数据类型不支持完整导出。") }
        let command: String
        switch kind { case .string: command = "STRLEN"; case .hash: command = "HLEN"; case .list: command = "LLEN"; case .set: command = "SCARD"; case .zset: command = "ZCARD"; case .stream: command = "XLEN"; case .unknown: throw RedisError.message("未知类型") }
        guard let count = try await database.wire.execute([Data(command.utf8), key]).number, count >= 0 else { throw RedisError.message("键长度读取失败。") }
        return (kind, count)
    }
    private static func expiration(_ key: Data, database: RedisDatabase) async throws -> (String, Int64?) {
        let reply = try await database.wire.pipeline([[Data("PEXPIRETIME".utf8), key]])[0]
        await database.capabilities.observe("PEXPIRETIME", reply: reply)
        if let expiry = reply.number {
            if expiry == -1 { return ("permanent", nil) }
            guard expiry >= 0 else { throw RedisError.message("键已过期。") }
            return ("absolute-unix-milliseconds", expiry)
        }
        if reply.serverError?.category == .unsupported {
            let values = try await database.wire.pipeline([[Data("TIME".utf8)], [Data("PTTL".utf8), key]])
            if let time = values[0].elements, time.count == 2, let seconds = time[0].number, let micros = time[1].number,
               seconds >= 0, seconds < Int64.max / 1000, (0..<1_000_000).contains(micros), let ttl = values[1].number {
                if ttl == -1 { return ("permanent", nil) }
                if ttl >= 0, seconds * 1000 <= Int64.max - micros / 1000 - ttl { return ("estimated-absolute-unix-milliseconds", seconds * 1000 + micros / 1000 + ttl) }
            }
        }
        return ("unknown", nil)
    }
}
