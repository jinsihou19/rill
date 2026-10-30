import XCTest
import Darwin
@testable import RillCore

private final class TestRedis {
    let process = Process()
    let port: Int
    let directory: URL
    init() throws {
        let binary = ["/opt/homebrew/bin/redis-server", "/usr/local/bin/redis-server", "/usr/bin/redis-server"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let binary else { throw XCTSkip("Integration tests require redis-server.") }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RedisError.message("Cannot reserve test port") }
        var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_port = 0; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        port = Int(UInt16(bigEndian: address.sin_port)); Darwin.close(fd)
        guard bound == 0, port > 0 else { throw RedisError.message("Cannot reserve test port") }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("rill-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["--bind", "127.0.0.1", "--port", String(port), "--save", "", "--appendonly", "no", "--dir", directory.path, "--requirepass", "rill-test-secret"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
    }
    deinit {
        if process.isRunning {
            let pid = process.processIdentifier
            kill(pid, SIGTERM)
            // Foundation waitUntilExit can stall on a cooperative executor without its launch run loop.
            for _ in 0..<100 {
                var status: Int32 = 0
                if waitpid(pid, &status, WNOHANG) != 0 { break }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        try? FileManager.default.removeItem(at: directory)
    }
    func connect(database: Int = 0, readOnly: Bool = false) async throws -> RedisDatabase {
        var last: Error = RedisError.message("server not ready")
        for _ in 0..<30 {
            do { return try await RedisDatabase.connect(ConnectionProfile(port: port, database: database, readOnly: readOnly), password: "rill-test-secret", timeout: 2) }
            catch { last = error; try await Task.sleep(nanoseconds: 30_000_000) }
        }
        throw last
    }
}

final class RedisIntegrationTests: XCTestCase {
    private var server: TestRedis!
    private var db: RedisDatabase!
    override func setUp() async throws { server = try TestRedis(); db = try await server.connect() }
    override func tearDown() async throws { db?.close(); db = nil; server = nil }
    private func data(_ text: String) -> Data { Data(text.utf8) }

    func testEncodedValueSaveKeepsTTLChecksRawConflictAndRetainsSnapshot() async throws {
        for codec in ValueCodec.allCases {
            let key = data("codec:" + codec.rawValue), original = try codec.encode(data("original"))
            _ = try await db.wire.execute([data("SET"), key, original, data("PX"), data("120000")])
            let page = try await db.inspect(key)
            let decoded = try DecodedValue(original: XCTUnwrap(page.content), codec: codec)
            XCTAssertEqual(decoded.text, "original")
            let replacement = try codec.encode(data("edited 中文"))
            try await db.saveString(key: key, expected: original, replacement: replacement)
            let stored = try await db.wire.execute([data("GET"), key])
            XCTAssertEqual(try codec.decode(XCTUnwrap(stored.data)), data("edited 中文"))
            let ttl = try await db.wire.execute([data("PTTL"), key])
            XCTAssertGreaterThan(ttl.number ?? 0, 0); XCTAssertLessThanOrEqual(ttl.number ?? Int64.max, page.key.ttl ?? 0)
            do { try await db.saveString(key: key, expected: original, replacement: original); XCTFail("Stale encoded bytes must conflict") } catch { }
            XCTAssertEqual(page.content, original)
            _ = try await db.wire.execute([data("DEL"), key])
            do { try await db.saveString(key: key, expected: replacement, replacement: original); XCTFail("Missing value must not be recreated") } catch { }
        }
    }

    func testStreamDirectionsRangesAndExclusivePagesDuringConcurrentChanges() async throws {
        let key = data("range-stream")
        for batch in 0..<3 {
            _ = try await db.wire.pipeline((0..<150).map { index in
                [data("XADD"), key, data("\(1000 + batch * 150 + index)-0"), data("same"), Data([0, 255]), data("same"), data("second")]
            })
        }
        let newest = try await db.inspect(key)
        XCTAssertEqual(newest.rows.first?.fieldText, "1449-0"); XCTAssertEqual(newest.rows.last?.fieldText, "1250-0")
        _ = try await db.wire.execute([data("XADD"), key, data("1450-0"), data("new"), data("v")])
        _ = try await db.wire.execute([data("XDEL"), key, data("1240-0")])
        let next = try await db.inspect(key, cursor: newest.cursor)
        XCTAssertEqual(next.rows.first?.fieldText, "1249-0")
        XCTAssertTrue(Set(newest.rows.map(\.id)).isDisjoint(with: Set(next.rows.map(\.id))))
        XCTAssertEqual(newest.rows[0].streamFields, [data("same"), Data([0, 255]), data("same"), data("second")])
        var query = MemberQuery(); query.newestFirst = false; query.streamStart = "1100-0"; query.streamEnd = "(1120-0"
        let range = try await db.inspect(key, query: query)
        XCTAssertEqual(range.rows.count, 20); XCTAssertEqual(range.rows.first?.fieldText, "1100-0"); XCTAssertEqual(range.rows.last?.fieldText, "1119-0")
    }
    func testServerMemberMatchingHashSetAndSortedSet() async throws {
        for kind in [KeyKind.hash, .set, .zset] {
            let key = data("match-" + kind.rawValue)
            let command = kind == .hash ? "HSET" : kind == .set ? "SADD" : "ZADD"
            let fields = (0..<600).flatMap { index -> [Data] in
                let field = data((index % 2 == 0 ? "wanted:" : "other:") + String(index))
                return kind == .hash ? [field, Data([0, 255])] : kind == .zset ? [data("1.2345678901234567"), field] : [field]
            }
            _ = try await db.wire.execute([data(command), key] + fields)
            var query = MemberQuery(); query.pattern = "wanted:*"
            let frozen = query, session = MemberReadSession()
            var rows: [ValueRow] = [], more = true
            while more {
                let page = try await session.next { cursor, offset in try await self.db.inspect(key, cursor: cursor, offset: offset, query: frozen) }
                rows += page.rows; more = page.hasMore
            }
            XCTAssertEqual(rows.count, 300); XCTAssertEqual(Set(rows.map(\.id)).count, 300)
            XCTAssertTrue(rows.allSatisfy { $0.fieldText.hasPrefix("wanted:") })
            if kind == .hash { XCTAssertTrue(rows.allSatisfy { $0.value == Data([0, 255]) }) }
            if kind == .zset { XCTAssertTrue(rows.allSatisfy { $0.score == "1.2345678901234567" }) }
        }
    }

    func testExactLookupInLargeKeyspaceNeverScans() async throws {
        let commands = (0..<100).map { batch -> [Data] in
            [data("MSET")] + (0..<1000).flatMap { [data("large:\(batch * 1000 + $0)"), data("v")] }
        }
        _ = try await db.wire.pipeline(commands)
        let before = RedisDatabase.parseInfo(try await db.wire.execute(["INFO", "commandstats"]).string ?? "")
        let found = try await db.lookup(data("large:99999"))
        let missing = try await db.lookup(data("missing"))
        let after = RedisDatabase.parseInfo(try await db.wire.execute(["INFO", "commandstats"]).string ?? "")
        func calls(_ stats: [String: String], _ command: String) -> Int {
            Int(stats["cmdstat_" + command]?.split(separator: ",").first?.dropFirst(6) ?? "0") ?? 0
        }
        XCTAssertEqual(found?.bytes, data("large:99999")); XCTAssertNil(missing)
        XCTAssertEqual(calls(after, "scan"), calls(before, "scan"))
        XCTAssertEqual(calls(after, "type") - calls(before, "type"), 2)
        XCTAssertEqual(calls(after, "pttl") - calls(before, "pttl"), 2)
    }

    func testExactLookupLiteralBinaryMissingAndPermissionErrors() async throws {
        let keys = ["a*b", "a?b", "a[b]", "a\\b", " 中文 key ", ""].map(data) + [Data([0, 255, 58, 42])]
        for key in keys {
            _ = try await db.wire.execute([data("SET"), key, data("v")])
            let row = try await db.lookup(key)
            XCTAssertEqual(row?.bytes, key); XCTAssertEqual(row?.kind, .string)
            let mismatch = try await db.lookup(key, kind: "hash"); XCTAssertNil(mismatch)
        }
        _ = try await db.wire.execute(["ACL", "SETUSER", "no-type", "on", ">test", "~*", "+ping", "+pttl", "+info"])
        let restricted = try await RedisDatabase.connect(ConnectionProfile(port: server.port, username: "no-type"), password: "test")
        defer { restricted.close() }
        do { _ = try await restricted.lookup(data("a*b")); XCTFail("Permission error must not look like a missing key") }
        catch { XCTAssertTrue(error.localizedDescription.contains("NOPERM")) }
        let ping = try await restricted.wire.execute(["PING"]); XCTAssertEqual(ping.string, "PONG")
        _ = try await db.wire.execute([data("DEL"), keys[0]])
        let removed = try await db.lookup(keys[0]); XCTAssertNil(removed)
    }
    func testOptionalMetadataAndInfoDenialsDoNotPreventReadingValues() async throws {
        _ = try await db.wire.execute(["SET", "restricted", "value", "EX", "120"])
        _ = try await db.wire.execute(["ACL", "SETUSER", "limited", "on", ">test", "~*", "+ping", "+scan", "+type", "+getrange", "+strlen"])
        let limited = try await RedisDatabase.connect(ConnectionProfile(port: server.port, username: "limited", readOnly: true), password: "test")
        defer { limited.close() }
        XCTAssertTrue(limited.server.isEmpty)
        let scan = try await limited.scan(cursor: "0", pattern: "*")
        let row = try XCTUnwrap(scan.keys.first); XCTAssertNil(row.ttl); XCTAssertEqual(row.ttlError?.category, .permission)
        let page = try await limited.inspect(data("restricted"))
        XCTAssertEqual(page.content, data("value")); XCTAssertNil(page.key.ttl); XCTAssertNil(page.memory)
        XCTAssertEqual(page.key.memoryError?.category, .permission)
        let found = try await limited.lookup(data("restricted")); XCTAssertNotNil(found)
        let states = await limited.capabilities.snapshot()
        for command in ["INFO", "PTTL", "MEMORY USAGE"] { XCTAssertEqual(states.first { $0.id == command }?.status, .denied) }
        do { _ = try await limited.size(); XCTFail() } catch { XCTAssertEqual((error as? RedisError)?.category, .permission) }
        do { _ = try await limited.wire.execute(["COMMAND"]); XCTFail() } catch { XCTAssertEqual((error as? RedisError)?.category, .permission) }
        _ = try await db.wire.execute(["ACL", "SETUSER", "limited", "-scan"])
        do { _ = try await limited.scan(cursor: "0", pattern: "*"); XCTFail() } catch { XCTAssertEqual((error as? RedisError)?.category, .permission) }
        let exact = try await limited.lookup(data("restricted")); XCTAssertNotNil(exact)
        let ping = try await limited.wire.execute(["PING"]); XCTAssertEqual(ping.string, "PONG")
    }
    func testTypeDeniedStillListsNamesAndServerTypeFilterCanBeUsed() async throws {
        _ = try await db.wire.execute(["SET", "one", "value"])
        _ = try await db.wire.execute(["ACL", "SETUSER", "names", "on", ">test", "~*", "+ping", "+scan", "+pttl"])
        let limited = try await RedisDatabase.connect(ConnectionProfile(port: server.port, username: "names"), password: "test")
        defer { limited.close() }
        let scan = try await limited.scan(cursor: "0", pattern: "*")
        XCTAssertEqual(scan.keys.first?.bytes, data("one")); XCTAssertEqual(scan.keys.first?.kind, .unknown)
        XCTAssertEqual(scan.keys.first?.typeError?.category, .permission)
        let filtered = try await limited.scan(cursor: "0", pattern: "*", kind: "string")
        XCTAssertEqual(filtered.keys.first?.kind, .string)
        do { _ = try await limited.lookup(data("one")); XCTFail() } catch { XCTAssertEqual((error as? RedisError)?.category, .permission) }
    }
    func testScanTypeUnsupportedResponseFallsBackWithinBudget() async throws {
        let fake = try ScriptedRedisServer { args in
            let strings = args.map { String(decoding: $0, as: UTF8.self) }
            switch strings.first {
            case "PING": return Data("+PONG\r\n".utf8)
            case "INFO": return Data("-NOPERM INFO denied\r\n".utf8)
            case "SCAN": return strings.contains("TYPE") ? Data("-ERR syntax error\r\n".utf8) : Data("*2\r\n$1\r\n0\r\n*1\r\n$3\r\nkey\r\n".utf8)
            case "TYPE": return Data("+string\r\n".utf8)
            case "PTTL": return Data(":-1\r\n".utf8)
            default: return Data("-ERR unexpected command\r\n".utf8)
            }
        }
        try await fake.start(); defer { fake.stop() }
        let database = try await RedisDatabase.connect(ConnectionProfile(port: fake.port), password: "")
        defer { database.close() }
        let session = KeyScanSession(budget: ScanBudget(requests: 1))
        let first = try await session.nextPage(fetchWithinBudget: { cursor, remaining in
            try await database.scan(cursor: cursor, pattern: "*", kind: "string", maximumRequests: remaining)
        })
        XCTAssertEqual(first.reason, .budget); XCTAssertTrue(first.keys.isEmpty); XCTAssertEqual(first.requests, 1)
        let second = try await session.nextPage(fetchWithinBudget: { cursor, remaining in
            try await database.scan(cursor: cursor, pattern: "*", kind: "string", maximumRequests: remaining)
        })
        XCTAssertEqual(second.reason, .complete); XCTAssertEqual(second.keys.first?.name, "key"); XCTAssertEqual(second.requests, 1)
        let scans = fake.commands().filter { $0.first == "SCAN" }
        XCTAssertEqual(scans.count, 2); XCTAssertTrue(scans[0].contains("TYPE")); XCTAssertFalse(scans[1].contains("TYPE"))
        XCTAssertFalse(fake.commands().contains { $0.first == "KEYS" })
        let states = await database.capabilities.snapshot()
        XCTAssertEqual(states.first { $0.id == "SCAN TYPE" }?.status, .unsupported)
    }

    func testStringConflictPreservesTTLAndBinary() async throws {
        let key = data("rill:中文🔑"), original = Data([0, 255, 10, 13])
        try await db.create(key: key, kind: .string, field: Data(), value: original, ttl: 120)
        let page = try await db.inspect(key)
        XCTAssertEqual(page.content, original); XCTAssertGreaterThan(try XCTUnwrap(page.key.ttl), 115_000)
        try await db.saveString(key: key, expected: original, replacement: data("new"))
        let saved = try await db.inspect(key)
        XCTAssertEqual(saved.content, data("new")); XCTAssertGreaterThan(try XCTUnwrap(saved.key.ttl), 115_000)
        do { try await db.saveString(key: key, expected: original, replacement: data("wrong")); XCTFail("Must detect conflict") } catch {}
        let final = try await db.inspect(key); XCTAssertEqual(final.content, data("new"))
    }
    func testCreateNeverOverwritesAndExpiredEditNeverRecreates() async throws {
        let key = data("create")
        try await db.create(key: key, kind: .string, field: Data(), value: data("first"))
        do { try await db.create(key: key, kind: .hash, field: data("f"), value: data("second")); XCTFail() } catch {}
        try await db.deleteKey(key)
        do { try await db.saveString(key: key, expected: data("first"), replacement: data("recreated")); XCTFail() } catch {}
        let exists = try await db.wire.execute(["EXISTS", "create"]).number; XCTAssertEqual(exists, 0)
    }
    func testAllCollectionTypesAndGranularEdits() async throws {
        for kind in [KeyKind.hash, .list, .set, .zset, .stream] {
            let key = data(kind.rawValue)
            let value = kind == .stream ? data(#"{"event":"created"}"#) : data("first")
            try await db.create(key: key, kind: kind, field: data("field"), value: value, score: "1.5", ttl: 120)
            var page = try await db.inspect(key)
            XCTAssertEqual(page.key.kind, kind); XCTAssertEqual(page.count, 1)
            let nextValue = kind == .stream ? data(#"{"event":"updated"}"#) : data("second")
            try await db.addRow(key: key, kind: kind, field: data("another"), value: nextValue, score: "2")
            page = try await db.inspect(key); XCTAssertEqual(page.count, 2)
            if [.hash, .list, .zset].contains(kind) {
                let row = try XCTUnwrap(page.rows.first)
                try await db.saveRow(key: key, kind: kind, row: row, replacement: data("changed"), score: "3.75", total: page.count)
                do { try await db.saveRow(key: key, kind: kind, row: row, replacement: data("conflict"), score: "4", total: page.count); XCTFail("Must detect stale member") } catch {}
                page = try await db.inspect(key)
            }
            if kind != .list {
                try await db.deleteRow(key: key, kind: kind, row: try XCTUnwrap(page.rows.first))
                page = try await db.inspect(key); XCTAssertEqual(page.count, 1)
            }
            XCTAssertGreaterThan(try XCTUnwrap(page.key.ttl), 110_000)
        }
    }
    func testCursorScanFilteringAndDatabaseIsolation() async throws {
        let commands = (0..<650).map { [data("SET"), data("scan:\($0)"), data("v")] }
        _ = try await db.wire.pipeline(commands)
        try await db.create(key: data("other"), kind: .list, field: Data(), value: data("one"))
        var cursor = "0", ids = Set<String>(), pages = 0
        repeat {
            let result = try await db.scan(cursor: cursor, pattern: "scan:*", kind: "string")
            cursor = result.cursor; ids.formUnion(result.keys.map(\.id)); pages += 1
        } while cursor != "0" && pages < 50
        XCTAssertEqual(ids.count, 650); XCTAssertGreaterThan(pages, 1)
        let isolated = try await server.connect(database: 1); defer { isolated.close() }
        let size = try await isolated.size(); XCTAssertEqual(size, 0)
        let originalSize = try await db.size(); XCTAssertEqual(originalSize, 651)
    }
    func testNamesFirstScanAndRequestedMetadataColumns() async throws {
        _ = try await db.wire.pipeline((0..<1000).map { [data("SET"), data("viewport:\($0)"), data("v")] })
        func stats() async throws -> [String: String] { RedisDatabase.parseInfo(try await db.wire.execute(["INFO", "commandstats"]).string ?? "") }
        func calls(_ stats: [String: String], _ command: String) -> Int {
            Int(stats["cmdstat_" + command]?.split(separator: ",").first?.dropFirst(6) ?? "0") ?? 0
        }
        let before = try await stats()
        var cursor = "0", all: [RedisKey] = []
        repeat {
            let page = try await db.scan(cursor: cursor, pattern: "viewport:*", includeMetadata: false)
            cursor = page.cursor; all += page.keys
        } while cursor != "0"
        let namesOnly = try await stats()
        XCTAssertEqual(Set(all.map(\.id)).count, 1000)
        XCTAssertEqual(calls(namesOnly, "type"), calls(before, "type")); XCTAssertEqual(calls(namesOnly, "pttl"), calls(before, "pttl"))
        let visible = Array(all.prefix(40)).map(\.bytes)
        let metadata = try await db.metadata(for: visible)
        let first = try await stats()
        XCTAssertEqual(metadata.count, 40)
        XCTAssertEqual(calls(first, "type") - calls(namesOnly, "type"), 40)
        XCTAssertEqual(calls(first, "pttl") - calls(namesOnly, "pttl"), 40)
        _ = try await db.metadata(for: visible, includeTTL: false)
        let hiddenTTL = try await stats(); XCTAssertEqual(calls(hiddenTTL, "pttl"), calls(first, "pttl"))
        _ = try await db.metadata(for: visible, includeType: false)
        let hiddenType = try await stats(); XCTAssertEqual(calls(hiddenType, "type"), calls(hiddenTTL, "type"))
        _ = try await db.metadata(for: visible, knownKind: "string")
        let known = try await stats(); XCTAssertEqual(calls(known, "type"), calls(hiddenType, "type"))
        let filtered = try await db.scan(cursor: "0", pattern: "viewport:*", kind: "string", includeMetadata: false)
        XCTAssertEqual(filtered.keys.first?.kind, .string)
        let after = try await stats()
        XCTAssertEqual(calls(after, "type"), calls(known, "type")); XCTAssertEqual(calls(after, "pttl"), calls(known, "pttl"))
    }
    func testConsoleReusesOneConnectionAndKeepsDatabaseIsolated() async throws {
        _ = try await db.wire.execute(["SET", "scope", "browser"])
        let before = try await db.info()
        let session = ConsoleSession(), profile = ConnectionProfile(port: server.port, database: 1)
        let first = try await session.execute(["SET", "scope", "console"], profile: profile, password: "rill-test-secret")
        XCTAssertFalse(first.reusedConnection)
        for _ in 0..<20 {
            let next = try await session.execute(["PING"], profile: profile, password: "rill-test-secret")
            XCTAssertEqual(next.value.string, "PONG"); XCTAssertTrue(next.reusedConnection)
        }
        let console = try await session.execute(["GET", "scope"], profile: profile, password: "rill-test-secret")
        let browser = try await db.wire.execute(["GET", "scope"])
        XCTAssertEqual(console.value.string, "console"); XCTAssertEqual(browser.string, "browser")
        let after = try await db.info()
        XCTAssertEqual((Int(after["total_connections_received"] ?? "") ?? 0) - (Int(before["total_connections_received"] ?? "") ?? 0), 1)
        await session.close()
    }
    func testConcurrentConsoleRequestsSharePreparationAndServerErrorsKeepSession() async throws {
        _ = try await db.wire.execute(["SET", "scope", "value"])
        let before = try await db.info(), session = ConsoleSession(), profile = ConnectionProfile(port: server.port)
        let results = try await withThrowingTaskGroup(of: ConsoleExecution.self) { group in
            for _ in 0..<20 { group.addTask { try await session.execute(["GET", "scope"], profile: profile, password: "rill-test-secret") } }
            var values: [ConsoleExecution] = []; for try await value in group { values.append(value) }; return values
        }
        XCTAssertTrue(results.allSatisfy { $0.value.string == "value" }); XCTAssertEqual(results.filter { !$0.reusedConnection }.count, 1)
        do { _ = try await session.execute(["HGET", "scope", "field"], profile: profile, password: "rill-test-secret"); XCTFail() }
        catch { XCTAssertEqual((error as? RedisError)?.category, .wrongType) }
        let next = try await session.execute(["PING"], profile: profile, password: "rill-test-secret"); XCTAssertTrue(next.reusedConnection)
        let after = try await db.info()
        XCTAssertEqual((Int(after["total_connections_received"] ?? "") ?? 0) - (Int(before["total_connections_received"] ?? "") ?? 0), 1)
        await session.close()
    }
    func testConsoleIdleEvictionCredentialChangesAndReadOnlyPolicy() async throws {
        let session = ConsoleSession(idleSeconds: 0.05), profile = ConnectionProfile(port: server.port)
        _ = try await session.execute(["PING"], profile: profile, password: "rill-test-secret")
        try await Task.sleep(nanoseconds: 150_000_000)
        let idle = try await session.execute(["PING"], profile: profile, password: "rill-test-secret"); XCTAssertFalse(idle.reusedConnection)
        do { _ = try await session.execute(["PING"], profile: profile, password: "wrong"); XCTFail() }
        catch { XCTAssertEqual((error as? RedisError)?.category, .authentication) }
        var readonly = profile; readonly.readOnly = true
        for command in [["SET", "key", "v"], ["SELECT", "1"], ["MULTI"], ["BLPOP", "x", "0"]] {
            do { _ = try await session.execute(command, profile: readonly, password: "rill-test-secret"); XCTFail() } catch {}
        }
        let valid = try await session.execute(["PING"], profile: readonly, password: "rill-test-secret"); XCTAssertEqual(valid.value.string, "PONG")
        await session.close()
    }
    func testConsoleDetectedDisconnectRebuildsOnNextCommand() async throws {
        let session = ConsoleSession(), profile = ConnectionProfile(port: server.port)
        _ = try await session.execute(["PING"], profile: profile, password: "rill-test-secret")
        _ = try await db.wire.execute(["CLIENT", "KILL", "TYPE", "normal", "SKIPME", "yes"])
        try await Task.sleep(nanoseconds: 30_000_000)
        let next = try await session.execute(["PING"], profile: profile, password: "rill-test-secret")
        XCTAssertEqual(next.value.string, "PONG"); XCTAssertFalse(next.reusedConnection)
        await session.close()
    }
    func testBoundedScanPauseAndResumeKeepsConnectionUsable() async throws {
        _ = try await db.wire.pipeline((0..<650).map { [data("SET"), data("bounded:\($0)"), data("v")] })
        let session = KeyScanSession(budget: ScanBudget(results: 100, requests: 2))
        let database = db!
        _ = try await db.wire.execute(["CLIENT", "PAUSE", "100", "ALL"])
        let task = Task { try await session.nextPage { cursor in try await database.scan(cursor: cursor, pattern: "bounded:*") } }
        try await Task.sleep(nanoseconds: 20_000_000); await session.pause()
        let stopped = try await task.value; XCTAssertEqual(stopped.reason, .paused)
        let ping = try await db.wire.execute(["PING"]); XCTAssertEqual(ping.string, "PONG")
        var ids = Set<String>(), complete = false
        for _ in 0..<20 {
            let page = try await session.nextPage { cursor in try await database.scan(cursor: cursor, pattern: "bounded:*") }
            XCTAssertLessThanOrEqual(page.keys.count, 100); XCTAssertLessThanOrEqual(page.requests, 2)
            for key in page.keys { XCTAssertTrue(ids.insert(key.id).inserted) }
            if page.reason == .complete { complete = true; break }
        }
        XCTAssertTrue(complete); XCTAssertEqual(ids.count, 650)
    }
    func testListAndStreamPagination() async throws {
        _ = try await db.wire.execute(["RPUSH", "list"] + (0..<450).map(String.init))
        let first = try await db.inspect(data("list")); XCTAssertEqual(first.rows.count, 200); XCTAssertTrue(first.hasMore)
        let second = try await db.inspect(data("list"), offset: first.nextOffset)
        XCTAssertEqual(second.rows.first?.valueText, "200"); XCTAssertEqual(second.rows.first?.index, 200)
        let third = try await db.inspect(data("list"), offset: second.nextOffset)
        XCTAssertEqual(third.rows.count, 50); XCTAssertFalse(third.hasMore)
        _ = try await db.wire.pipeline((0..<230).map { [data("XADD"), data("events"), data("*"), data("number"), data(String($0))] })
        let stream = try await db.inspect(data("events")); XCTAssertTrue(stream.hasMore)
        let stream2 = try await db.inspect(data("events"), cursor: stream.cursor)
        XCTAssertEqual(stream2.rows.count, 30)
        XCTAssertTrue(Set(stream.rows.map(\.id)).isDisjoint(with: Set(stream2.rows.map(\.id))))
    }
    func testReadOnlyRejectsEveryMutation() async throws {
        let readonly = try await server.connect(readOnly: true); defer { readonly.close() }
        try await db.create(key: data("read"), kind: .string, field: Data(), value: data("v"))
        do { try await readonly.saveString(key: data("read"), expected: data("v"), replacement: data("wrong")); XCTFail() } catch {}
        do { try await readonly.deleteKey(data("read")); XCTFail() } catch {}
        do { try await readonly.expire(data("read"), seconds: 5); XCTFail() } catch {}
        do { try await readonly.rename(data("read"), to: data("renamed")); XCTFail() } catch {}
        do { try await readonly.create(key: data("new"), kind: .set, field: Data(), value: data("v")); XCTFail() } catch {}
        let page = try await readonly.inspect(data("read")); XCTAssertEqual(page.content, data("v"))
    }
    func testStreamBinaryFieldsRetainOriginalBytesForExport() async throws {
        let field = Data([0xff, 0x01]), value = Data([0, 0xff, 13, 10])
        _ = try await db.wire.execute([data("XADD"), data("binary-events"), data("*"), field, value])
        let page = try await db.inspect(data("binary-events"))
        XCTAssertEqual(page.rows.first?.streamFields, [field, value])
    }
    func testACLAuthErrorsAndReconnect() async throws {
        _ = try await db.wire.execute(["ACL", "SETUSER", "reader", "on", ">reader-secret", "~*", "+@read", "+ping", "+select"])
        let reader = try await RedisDatabase.connect(ConnectionProfile(port: server.port, username: "reader"), password: "reader-secret")
        defer { reader.close() }
        do { _ = try await reader.wire.execute(["SET", "x", "v"]); XCTFail() } catch {}
        let ping = try await reader.wire.execute(["PING"]); XCTAssertEqual(ping.string, "PONG")
        do { _ = try await RedisDatabase.connect(ConnectionProfile(port: server.port), password: "wrong", timeout: 1); XCTFail() } catch {}
    }
    func testRenameTTLAndLargePreview() async throws {
        try await db.create(key: data("a"), kind: .string, field: Data(), value: data("one"))
        try await db.create(key: data("b"), kind: .string, field: Data(), value: data("two"))
        do { try await db.rename(data("a"), to: data("b")); XCTFail() } catch {}
        try await db.rename(data("a"), to: data("c")); try await db.expire(data("c"), seconds: 60)
        var page = try await db.inspect(data("c")); XCTAssertGreaterThan(try XCTUnwrap(page.key.ttl), 55_000)
        try await db.expire(data("c"), seconds: nil); page = try await db.inspect(data("c")); XCTAssertEqual(page.key.ttl, -1)
        _ = try await db.wire.execute([data("SET"), data("large"), Data(repeating: 65, count: RedisDatabase.previewLimit + 10)])
        let large = try await db.inspect(data("large")); XCTAssertTrue(large.isTruncated); XCTAssertEqual(large.content?.count, RedisDatabase.previewLimit)
    }
    func testTimeoutClosesConnectionAndFailsQueuedRequests() async throws {
        let connection = try RedisConnection(host: "127.0.0.1", port: server.port, timeout: 0.15)
        try await connection.open(); _ = try await connection.execute(["AUTH", "rill-test-secret"])
        let blocked = Task { try await connection.execute(["BLPOP", "empty-list", "0"]) }
        try await Task.sleep(nanoseconds: 30_000_000)
        let queued = Task { try await connection.execute(["PING"]) }
        do { _ = try await blocked.value; XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("超时")) }
        do { _ = try await queued.value; XCTFail("Queued command must fail, not reuse a late response") } catch {}
        do { _ = try await connection.execute(["PING"]); XCTFail() } catch {}
    }
    func testIdleDisconnectIsReported() async throws {
        let expectation = expectation(description: "disconnect callback")
        let db = try await server.connect()
        db.wire.onDisconnect { reason in XCTAssertFalse(reason.isEmpty); expectation.fulfill() }
        _ = try await self.db.wire.execute(["CLIENT", "KILL", "TYPE", "normal", "SKIPME", "yes"])
        await fulfillment(of: [expectation], timeout: 2)
        db.close()
    }
    func testCancelledRequestClosesRatherThanReusesSocket() async throws {
        let connection = try RedisConnection(host: "127.0.0.1", port: server.port)
        try await connection.open(); _ = try await connection.execute(["AUTH", "rill-test-secret"])
        let task = Task { try await connection.execute(["BLPOP", "cancel-list", "0"]) }
        try await Task.sleep(nanoseconds: 20_000_000); task.cancel()
        do { _ = try await task.value; XCTFail() } catch {}
        do { _ = try await connection.execute(["PING"]); XCTFail() } catch {}
    }
    func testInfoSlowlogAndServerErrorDoesNotDesyncPipeline() async throws {
        let info = try await db.info(); XCTAssertNotNil(info["redis_version"])
        _ = try await db.wire.execute(["CONFIG", "SET", "slowlog-log-slower-than", "0"])
        _ = try await db.wire.execute(["PING"])
        let logs = try await db.slowQueries(); XCTAssertFalse(logs.isEmpty)
        let replies = try await db.wire.pipeline([[data("NOT_A_COMMAND")], [data("PING")]])
        XCTAssertThrowsError(try replies[0].checked()); XCTAssertEqual(replies[1].string, "PONG")
    }
}
