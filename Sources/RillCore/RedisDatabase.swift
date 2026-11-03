import Foundation

public final class RedisDatabase: @unchecked Sendable {
    public static let previewLimit = 1024 * 1024
    public static let pageSize = 200
    public let profile: ConnectionProfile
    public let wire: RedisConnection
    public let capabilities = RedisCapabilities()
    public private(set) var server: [String: String] = [:]
    public private(set) var latency: Double = 0

    private init(profile: ConnectionProfile, wire: RedisConnection) { self.profile = profile; self.wire = wire }
    public static func connect(_ profile: ConnectionProfile, password: String, timeout: TimeInterval = 10) async throws -> RedisDatabase {
        try profile.validate()
        let connection = try RedisConnection(host: profile.host, port: profile.port, tls: profile.tls, timeout: timeout)
        do {
            try await connection.open()
            if !password.isEmpty || !profile.username.isEmpty {
                _ = try await connection.execute(profile.username.isEmpty ? ["AUTH", password] : ["AUTH", profile.username, password])
            }
            if profile.database != 0 { _ = try await connection.execute(["SELECT", String(profile.database)]) }
            let result = RedisDatabase(profile: profile, wire: connection)
            let start = Date(); _ = try await connection.execute(["PING"])
            result.latency = Date().timeIntervalSince(start) * 1000
            let info = try await result.observed(["INFO", "server"], feature: "INFO")
            if let value = info.string { result.server = parseInfo(value) }
            if let mode = result.server["redis_mode"], mode != "standalone" {
                throw RedisError.message("此连接为 \(mode) 模式。当前版本仅支持 standalone，请连接独立实例。")
            }
            return result
        } catch { connection.close(); throw error }
    }
    public func close() { wire.close() }

    private func observed(_ args: [String], feature: String) async throws -> RESPValue {
        let reply = try await wire.pipeline([args.map { Data($0.utf8) }])[0]
        await capabilities.observe(feature, reply: reply)
        return reply
    }

    public func lookup(_ key: Data, kind: String = "") async throws -> RedisKey? {
        guard let row = try await metadata(for: [key]).first else { return nil }
        if let error = row.typeError { throw error }
        guard kind.isEmpty || row.rawType == kind else { return nil }
        return row
    }

    public func metadata(for keys: [Data], knownKind: String? = nil, includeTTL: Bool = true, includeMemory: Bool = false, includeType: Bool = true) async throws -> [RedisKey] {
        guard !keys.isEmpty else { return [] }
        var commands: [[Data]] = []
        for key in keys {
            if knownKind == nil && includeType { commands.append([Data("TYPE".utf8), key]) }
            if includeTTL { commands.append([Data("PTTL".utf8), key]) }
            if includeMemory { commands.append([Data("MEMORY".utf8), Data("USAGE".utf8), key]) }
        }
        let replies = try await wire.pipeline(commands)
        var index = 0, rows: [RedisKey] = [], observations: [String: RESPValue] = [:]
        func read(_ feature: String) -> RESPValue {
            let reply = replies[index]; index += 1
            if observations[feature]?.serverError == nil { observations[feature] = reply }
            return reply
        }
        for key in keys {
            let type = knownKind.map(RESPValue.simple) ?? (includeType ? read("TYPE") : .bulk(nil))
            let ttl = includeTTL ? read("PTTL") : .bulk(nil)
            let memory = includeMemory ? read("MEMORY USAGE") : .bulk(nil)
            if includeType && knownKind == nil && type.serverError == nil && type.string?.isEmpty != false { throw RedisError.message("TYPE 响应格式无效。") }
            if includeTTL && ttl.serverError == nil && (ttl.number == nil || ttl.number! < -2) { throw RedisError.message("PTTL 响应格式无效。") }
            if type.string == "none" || ttl.number == -2 { continue }
            rows.append(RedisKey(bytes: key, kind: KeyKind(rawValue: type.string ?? "") ?? .unknown, ttl: ttl.number,
                                 rawType: type.string, typeError: type.serverError, ttlError: ttl.serverError,
                                 memory: memory.number, memoryError: memory.serverError))
        }
        for (feature, reply) in observations { await capabilities.observe(feature, reply: reply) }
        return rows
    }

    public func scan(cursor: String, pattern: String, kind: String = "", maximumRequests: Int = 2, includeMetadata: Bool = true) async throws -> ScanPage {
        var args = ["SCAN", cursor, "MATCH", pattern.isEmpty ? "*" : pattern, "COUNT", String(Self.pageSize)]
        let supportsType = await capabilities.supportsScanType()
        let useType = !kind.isEmpty && supportsType
        if useType { args += ["TYPE", kind] }
        let response: RESPValue
        do {
            response = try await observed(args, feature: useType ? "SCAN TYPE" : "SCAN").checked()
        } catch {
            guard useType, RedisCapabilities.canRetryScanWithoutType(error), let issue = error as? RedisError else { throw error }
            await capabilities.markScanTypeUnsupported(issue)
            guard maximumRequests > 1 else { return ScanPage(cursor: cursor, keys: [], needsRetry: true) }
            var fallback = try await scan(cursor: cursor, pattern: pattern, kind: kind, maximumRequests: maximumRequests - 1, includeMetadata: includeMetadata)
            fallback.requests += 1
            return fallback
        }
        guard let values = response.elements, values.count == 2, let cursor = values[0].string,
              let rawKeys = values[1].elements else { throw RedisError.message("SCAN 响应格式无效。") }
        let keys = Array(Set(rawKeys.compactMap(\.data))).sorted { $0.lexicographicallyPrecedes($1) }
        if keys.isEmpty { return ScanPage(cursor: cursor, keys: []) }
        if !includeMetadata && (kind.isEmpty || useType) {
            return ScanPage(cursor: cursor, keys: keys.map { RedisKey(bytes: $0, kind: KeyKind(rawValue: kind) ?? .unknown, rawType: useType ? kind : nil) })
        }
        let rows = try await metadata(for: keys, knownKind: useType ? kind : nil, includeTTL: includeMetadata)
        if !kind.isEmpty && !useType {
            if let error = rows.first(where: { $0.typeError != nil })?.typeError { throw error }
            return ScanPage(cursor: cursor, keys: rows.filter { $0.rawType == kind })
        }
        return ScanPage(cursor: cursor, keys: rows)
    }

    public func size() async throws -> Int64 { try await observed(["DBSIZE"], feature: "DBSIZE").checked().number ?? 0 }

    public func inspect(_ key: Data, cursor: String = "0", offset: Int = 0, query: MemberQuery = MemberQuery()) async throws -> KeyPage {
        try query.validate()
        guard let row = try await metadata(for: [key], includeMemory: true).first else { throw RedisError.message("这个键已过期或被删除，请刷新键列表。") }
        if let error = row.typeError { throw error }
        let kind = row.kind
        var page = KeyPage(key: row, count: 0, memory: row.memory)
        func run(_ parts: [Data]) async throws -> RESPValue { try await wire.execute(parts) }
        func args(_ prefix: String, _ rest: [String] = []) -> [Data] { [Data(prefix.utf8), key] + rest.map { Data($0.utf8) } }
        switch kind {
        case .string:
            page.count = try await run(args("STRLEN")).number ?? 0
            page.content = try await run(args("GETRANGE", ["0", String(Self.previewLimit - 1)])).data ?? Data()
            page.isTruncated = page.count > Self.previewLimit
        case .hash, .set, .zset:
            if kind == .zset, query.pattern.isEmpty {
                page.count = try await run(args("ZCARD")).number ?? 0
                let values = try await run(args("ZRANGE", [String(offset), String(offset + Self.pageSize - 1), "WITHSCORES"])).elements ?? []
                guard values.count % 2 == 0, values.allSatisfy({ $0.data != nil }) else { throw RedisError.message("成员与分值响应无效。") }
                page.rows = stride(from: 0, to: values.count, by: 2).map { ValueRow(field: values[$0].data ?? Data(), value: values[$0].data ?? Data(), score: values[$0 + 1].string) }
                page.nextOffset = offset + page.rows.count; page.hasMore = page.nextOffset < page.count
                return page
            }
            let countCommand = kind == .hash ? "HLEN" : kind == .set ? "SCARD" : "ZCARD"
            let scanCommand = kind == .hash ? "HSCAN" : kind == .set ? "SSCAN" : "ZSCAN"
            page.count = try await run(args(countCommand)).number ?? 0
            let filter = query.pattern.isEmpty ? [] : ["MATCH", query.pattern]
            let result = try await run(args(scanCommand, [cursor, "COUNT", String(Self.pageSize)] + filter)).elements ?? []
            guard result.count == 2, let next = result[0].string, let values = result[1].elements else { throw RedisError.message("集合分页响应无效。") }
            page.cursor = next; page.hasMore = next != "0"
            guard values.allSatisfy({ $0.data != nil }) else { throw RedisError.message("成员响应无效。") }
            if kind == .set { page.rows = values.map { ValueRow(field: $0.data ?? Data(), value: $0.data ?? Data()) } }
            else {
                guard values.count % 2 == 0 else { throw RedisError.message("成员字段/值响应不成对。") }
                page.rows = stride(from: 0, to: values.count, by: 2).map {
                    ValueRow(field: values[$0].data ?? Data(), value: kind == .hash ? values[$0 + 1].data ?? Data() : values[$0].data ?? Data(), score: kind == .zset ? values[$0 + 1].string : nil)
                }
            }
        case .list:
            page.count = try await run(args("LLEN")).number ?? 0
            let values = try await run(args("LRANGE", [String(offset), String(offset + Self.pageSize - 1)])).elements ?? []
            page.rows = values.enumerated().map { ValueRow(field: Data(String(offset + $0.offset).utf8), value: $0.element.data ?? Data(), index: offset + $0.offset) }
            page.nextOffset = offset + page.rows.count; page.hasMore = page.nextOffset < page.count
        case .stream:
            page.count = try await run(args("XLEN")).number ?? 0
            let first = query.newestFirst ? query.streamEnd : query.streamStart
            let last = query.newestFirst ? query.streamStart : query.streamEnd
            let boundary = cursor == "0" ? first : "(" + cursor
            let values = try await run(args(query.newestFirst ? "XREVRANGE" : "XRANGE", [boundary, last, "COUNT", String(Self.pageSize)])).elements ?? []
            page.rows = try values.map { item in
                guard let pair = item.elements, pair.count == 2, let id = pair[0].data,
                      let fields = pair[1].elements, fields.count % 2 == 0, fields.allSatisfy({ $0.data != nil }) else {
                    throw RedisError.message("Stream 条目或字段对响应无效。")
                }
                let pairs = stride(from: 0, to: max(0, fields.count - 1), by: 2).map { ["field": DataPresentation.text(fields[$0].data ?? Data()), "value": DataPresentation.text(fields[$0 + 1].data ?? Data())] }
                let data = (try? JSONSerialization.data(withJSONObject: pairs, options: [.prettyPrinted, .sortedKeys])) ?? Data()
                return ValueRow(field: id, value: data, streamFields: fields.compactMap(\.data))
            }
            page.cursor = page.rows.last?.fieldText ?? cursor; page.hasMore = page.rows.count == Self.pageSize
        case .unknown: break
        }
        return page
    }

    public func info() async throws -> [String: String] {
        Self.parseInfo(try await observed(["INFO"], feature: "INFO").checked().string ?? "")
    }
    public static func parseInfo(_ input: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in input.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
            let pair = line.split(separator: ":", maxSplits: 1)
            if pair.count == 2 { result[String(pair[0])] = String(pair[1]) }
        }
        return result
    }
    public func slowQueries() async throws -> [SlowQuery] {
        let result = try await observed(["SLOWLOG", "GET", "50"], feature: "SLOWLOG GET").checked().elements ?? []
        return result.compactMap { item in
            guard let row = item.elements, row.count >= 4, let id = row[0].number,
                  let timestamp = row[1].number, let duration = row[2].number else { return nil }
            let args = row[3].elements?.map { $0.string ?? "(binary)" } ?? []
            let sensitive = ["AUTH", "HELLO", "ACL"].contains(args.first?.uppercased() ?? "")
            return SlowQuery(id: id, date: Date(timeIntervalSince1970: TimeInterval(timestamp)), microseconds: duration,
                             command: sensitive ? "\(args.first ?? "") [已隐藏参数]" : args.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " "),
                             client: row.count > 4 ? row[4].string ?? "" : "")
        }
    }

    public func slowlogReport() async throws -> SlowlogReport {
        var report = SlowlogReport(queries: try await slowQueries())
        do { report.length = try await observed(["SLOWLOG", "LEN"], feature: "SLOWLOG LEN").checked().number }
        catch let error as RedisError { if case .server = error { report.settingsError = error.localizedDescription } else { throw error } }
        for parameter in ["slowlog-log-slower-than", "slowlog-max-len"] {
            do {
                let result = try await observed(["CONFIG", "GET", parameter], feature: "CONFIG GET " + parameter).checked().elements
                let number = result?.count == 2 ? result?[1].number : nil
                if parameter == "slowlog-log-slower-than" { report.thresholdMicroseconds = number }
                else { report.maximumLength = number }
            } catch let error as RedisError {
                if case .server = error { report.settingsError = error.localizedDescription } else { throw error }
            }
        }
        return report
    }

    private func writable() throws {
        guard !profile.readOnly else { throw RedisError.message("当前连接为只读，请在连接设置中开启写入。") }
    }
    private func atomic(_ script: String, key: Data, args: [Data]) async throws -> RESPValue {
        try writable()
        return try await wire.execute([Data("EVAL".utf8), Data(script.utf8), Data("1".utf8), key] + args)
    }
    private func requireSuccess(_ response: RESPValue) throws {
        guard response.number == 1 else { throw RedisError.message("数据已变化、已过期或目标已存在。请刷新后重新编辑，原数据未被覆盖。") }
    }
    public func saveString(key: Data, expected: Data, replacement: Data) async throws {
        guard replacement.count <= Self.previewLimit else { throw RedisError.message("编辑值不能超过 1 MiB。") }
        let script = "if redis.call('TYPE',KEYS[1]).ok~='string' then return 0 end if redis.call('GET',KEYS[1])~=ARGV[1] then return 0 end redis.call('SET',KEYS[1],ARGV[2],'KEEPTTL'); return 1"
        try requireSuccess(try await atomic(script, key: key, args: [expected, replacement]))
    }
    public func copyKey(_ source: Data, to destination: Data) async throws {
        try writable()
        guard source != destination else { throw RedisError.message("复制目标必须与源键不同。") }
        let reply = try await wire.pipeline([[Data("COPY".utf8), source, destination]])[0]
        await capabilities.observe("COPY", reply: reply)
        guard try reply.checked().number == 1 else { throw RedisError.message("源键已不存在或目标已存在，未覆盖任何目标。") }
    }
    public func saveRow(key: Data, kind: KeyKind, row: ValueRow, replacement: Data, score: String? = nil, total: Int64) async throws {
        let script: String
        var args = [row.field, row.value, replacement]
        switch kind {
        case .hash:
            script = "if redis.call('HGET',KEYS[1],ARGV[1])~=ARGV[2] then return 0 end redis.call('HSET',KEYS[1],ARGV[1],ARGV[3]); return 1"
        case .list:
            script = "if redis.call('LLEN',KEYS[1])~=tonumber(ARGV[4]) or redis.call('LINDEX',KEYS[1],ARGV[1])~=ARGV[2] then return 0 end redis.call('LSET',KEYS[1],ARGV[1],ARGV[3]); return 1"
            args.append(Data(String(total).utf8))
        case .zset:
            guard let score, let number = Double(score), number.isFinite else { throw RedisError.message("Score 必须是有限数值。") }
            script = "if redis.call('ZSCORE',KEYS[1],ARGV[1])~=ARGV[2] then return 0 end redis.call('ZADD',KEYS[1],'XX',ARGV[3],ARGV[1]); return 1"
            args = [row.field, Data((row.score ?? "").utf8), Data(score.utf8)]
        default: throw RedisError.message("此类型不支持原位编辑。请新增或删除成员。")
        }
        try requireSuccess(try await atomic(script, key: key, args: args))
    }
    public func addRow(key: Data, kind: KeyKind, field: Data, value: Data, score: String = "0") async throws {
        let script: String
        var args = [field, value]
        switch kind {
        case .hash: script = "if redis.call('TYPE',KEYS[1]).ok~='hash' then return 0 end return redis.call('HSETNX',KEYS[1],ARGV[1],ARGV[2])"
        case .list: script = "if redis.call('TYPE',KEYS[1]).ok~='list' then return 0 end redis.call('RPUSH',KEYS[1],ARGV[2]); return 1"
        case .set: script = "if redis.call('TYPE',KEYS[1]).ok~='set' then return 0 end return redis.call('SADD',KEYS[1],ARGV[2])"
        case .zset:
            guard let number = Double(score), number.isFinite else { throw RedisError.message("Score 必须是有限数值。") }
            script = "if redis.call('TYPE',KEYS[1]).ok~='zset' then return 0 end return redis.call('ZADD',KEYS[1],'NX',ARGV[1],ARGV[2])"
            args = [Data(score.utf8), value]
        case .stream:
            script = "if redis.call('TYPE',KEYS[1]).ok~='stream' then return 0 end redis.call('XADD',KEYS[1],'*',unpack(ARGV)); return 1"
            args = try Self.streamFields(value)
        default: throw RedisError.message("此类型不支持新增成员。")
        }
        try requireSuccess(try await atomic(script, key: key, args: args))
    }
    public func deleteRow(key: Data, kind: KeyKind, row: ValueRow) async throws {
        let script: String
        var args = [row.field, row.value]
        switch kind {
        case .hash: script = "if redis.call('HGET',KEYS[1],ARGV[1])~=ARGV[2] then return 0 end return redis.call('HDEL',KEYS[1],ARGV[1])"
        case .set: script = "return redis.call('SREM',KEYS[1],ARGV[1])"
        case .zset:
            script = "if redis.call('ZSCORE',KEYS[1],ARGV[1])~=ARGV[2] then return 0 end return redis.call('ZREM',KEYS[1],ARGV[1])"
            args = [row.field, Data((row.score ?? "").utf8)]
        case .stream: script = "return redis.call('XDEL',KEYS[1],ARGV[1])"
        default: throw RedisError.message("List 的位置删除请使用工作台。")
        }
        try requireSuccess(try await atomic(script, key: key, args: args))
    }
    public func deleteKey(_ key: Data) async throws { try writable(); _ = try await wire.execute([Data("UNLINK".utf8), key]) }
    public func rename(_ key: Data, to name: Data) async throws {
        try writable()
        guard !name.isEmpty, key != name else { throw RedisError.message("请填写不同的非空键名。") }
        try requireSuccess(try await wire.execute([Data("RENAMENX".utf8), key, name]))
    }
    public func expire(_ key: Data, seconds: Int64?) async throws {
        try writable()
        if let seconds {
            guard seconds > 0, seconds <= Int64.max / 1000 else { throw RedisError.message("TTL 必须为正整数秒，永久有效请使用「移除过期时间」。") }
            try requireSuccess(try await wire.execute([Data("PEXPIRE".utf8), key, Data(String(seconds * 1000).utf8)]))
        } else {
            let script = "if redis.call('EXISTS',KEYS[1])==0 then return 0 end redis.call('PERSIST',KEYS[1]); return 1"
            try requireSuccess(try await atomic(script, key: key, args: []))
        }
    }
    public func create(key: Data, kind: KeyKind, field: Data, value: Data, score: String = "0", ttl: Int64? = nil) async throws {
        guard !key.isEmpty else { throw RedisError.message("键名不能为空。") }
        guard value.count <= Self.previewLimit else { throw RedisError.message("初始值不能超过 1 MiB。") }
        if let ttl { guard ttl > 0, ttl <= Int64.max / 1000 else { throw RedisError.message("TTL 必须是正整数。") } }
        var command: [Data]
        switch kind {
        case .string: command = [Data("SET".utf8), key, value]
        case .hash: command = [Data("HSET".utf8), key, field, value]
        case .list: command = [Data("RPUSH".utf8), key, value]
        case .set: command = [Data("SADD".utf8), key, value]
        case .zset:
            guard let n = Double(score), n.isFinite else { throw RedisError.message("Score 必须是有限数值。") }
            command = [Data("ZADD".utf8), key, Data(score.utf8), value]
        case .stream: command = [Data("XADD".utf8), key, Data("*".utf8)] + (try Self.streamFields(value))
        case .unknown: throw RedisError.message("请选择支持的数据类型。")
        }
        // Lua errors do not roll back writes; validate expiry on the missing key before creating it.
        let script = "if redis.call('EXISTS',KEYS[1])~=0 then return 0 end local ttl=table.remove(ARGV,1); if ttl~='' then redis.call('PEXPIRE',KEYS[1],ttl) end redis.call(unpack(ARGV)); if ttl~='' then redis.call('PEXPIRE',KEYS[1],ttl) end return 1"
        try requireSuccess(try await atomic(script, key: key, args: [Data((ttl.map { String($0 * 1000) } ?? "").utf8)] + command))
    }
    public static func streamFields(_ data: Data) throws -> [Data] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: String], !object.isEmpty,
              object.count <= 200 else { throw RedisError.message("Stream 内容必须是 1–200 个字符串字段组成的 JSON 对象，例如 {\"event\":\"created\"}。") }
        return object.keys.sorted().flatMap { [Data($0.utf8), Data(object[$0]!.utf8)] }
    }
}
