import Foundation

public enum ConnectionEnvironment: String, Codable, CaseIterable, Sendable {
    case local, development, staging, production
    public var title: String {
        switch self { case .local: return "本地"; case .development: return "开发"; case .staging: return "预发布"; case .production: return "生产" }
    }
}

public struct ConnectionProfile: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var database: Int
    public var tls: Bool
    public var readOnly: Bool
    public var environment: ConnectionEnvironment

    public init(id: UUID = UUID(), name: String = "本地 Redis", host: String = "127.0.0.1", port: Int = 6379,
                username: String = "", database: Int = 0, tls: Bool = false, readOnly: Bool = false,
                environment: ConnectionEnvironment = .local) {
        self.id = id; self.name = name; self.host = host; self.port = port; self.username = username
        self.database = database; self.tls = tls; self.readOnly = readOnly; self.environment = environment
    }
    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RedisError.message("连接名称不能为空。") }
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !host.contains("://"), !host.contains("/"), !host.contains("\n"), !host.contains(" ") else {
            throw RedisError.message("主机只需填写域名或 IP，不要包含 redis://、空格或路径。")
        }
        guard (1...65535).contains(port) else { throw RedisError.message("端口必须在 1–65535 之间。") }
        guard (0...65535).contains(database) else { throw RedisError.message("数据库编号必须在 0–65535 之间。") }
    }
}

public enum KeyKind: String, CaseIterable, Codable, Sendable {
    case string, hash, list, set, zset, stream, unknown
    public var title: String { rawValue == "zset" ? "ZSet" : rawValue.capitalized }
    public var symbol: String {
        switch self {
        case .string: return "text.alignleft"
        case .hash: return "number"
        case .list: return "list.number"
        case .set: return "circle.grid.2x2"
        case .zset: return "chart.bar.xaxis"
        case .stream: return "waveform.path"
        case .unknown: return "questionmark.square"
        }
    }
    public static var editable: [Self] { allCases.filter { $0 != .unknown } }
}

public enum KeySearchMode: String, CaseIterable, Codable, Sendable {
    case fuzzy, pattern, exact, hex
    public var title: String {
        switch self { case .fuzzy: return "模糊"; case .pattern: return "模式"; case .exact: return "精确键"; case .hex: return "Hex 键" }
    }
    public var placeholder: String {
        switch self {
        case .fuzzy: return "输入键名片段，回车搜索"
        case .pattern: return "Redis glob，如 user:*"
        case .exact: return "完整键名，按字面查找"
        case .hex: return "原始字节，如 00 FF 3A"
        }
    }
    public func scanPattern(_ input: String) -> String? {
        // An empty search field returns to browsing in every mode.
        if input.isEmpty { return "*" }
        switch self {
        case .fuzzy: return "*" + String(decoding: RedisGlob.escapedPrefix(Data(input.utf8)), as: UTF8.self)
        case .pattern: return input
        case .exact, .hex: return nil
        }
    }
    public func exactKey(_ input: String) throws -> Data? {
        switch self {
        case .fuzzy, .pattern: return nil
        case .exact: return Data(input.utf8)
        case .hex:
            var text = input.filter { !$0.isWhitespace }
            if text.lowercased().hasPrefix("0x") { text.removeFirst(2) }
            let chars = Array(text)
            guard chars.count.isMultiple(of: 2) else { throw RedisError.message("Hex 键必须由完整的字节组成，例如 00 FF 3A。") }
            var bytes = Data()
            for i in stride(from: 0, to: chars.count, by: 2) {
                guard let byte = UInt8(String(chars[i...i + 1]), radix: 16) else { throw RedisError.message("Hex 键只能包含十六进制数字和空白。") }
                bytes.append(byte)
            }
            return bytes
        }
    }
}

public enum RedisGlob {
    public static func escapedPrefix(_ bytes: Data) -> Data {
        var result = Data()
        for byte in bytes {
            if [UInt8(42), 63, 91, 93, 92].contains(byte) { result.append(92) }
            result.append(byte)
        }
        result.append(42)
        return result
    }
}

public struct RedisKey: Identifiable, Equatable, Sendable {
    public let bytes: Data
    public let kind: KeyKind
    public let ttl: Int64?
    public let rawType: String?
    public let typeError: RedisError?
    public let ttlError: RedisError?
    public let memory: Int64?
    public let memoryError: RedisError?
    public init(bytes: Data, kind: KeyKind = .unknown, ttl: Int64? = nil, rawType: String? = nil,
                typeError: RedisError? = nil, ttlError: RedisError? = nil, memory: Int64? = nil,
                memoryError: RedisError? = nil) {
        self.bytes = bytes; self.kind = kind; self.ttl = ttl; self.rawType = rawType ?? (kind == .unknown ? nil : kind.rawValue)
        self.typeError = typeError; self.ttlError = ttlError; self.memory = memory; self.memoryError = memoryError
    }
    public var ttlLabel: String {
        guard let ttl else { return "TTL 未知" }
        return ttl == -1 ? "永久有效" : ttl == -2 ? "已不存在" : "TTL \(max(0, ttl) / 1000)s"
    }
    public var id: String { bytes.base64EncodedString() }
    public var name: String { DataPresentation.key(bytes) }
    public var namespace: String {
        let parts = name.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        return parts.count > 1 ? String(parts[0]) : "未分组"
    }
}

public struct ValueRow: Identifiable, Equatable, Sendable {
    public var field: Data
    public var value: Data
    public var score: String?
    public var index: Int?
    public var streamFields: [Data]? = nil
    public var id: String { index.map(String.init) ?? field.base64EncodedString() }
    public var fieldText: String { DataPresentation.key(field) }
    public var valueText: String { DataPresentation.text(value) }
}

public struct KeyPage: Sendable {
    public var key: RedisKey
    public var count: Int64
    public var memory: Int64?
    public var fetchedAt = Date()
    public var content: Data?
    public var rows: [ValueRow] = []
    public var cursor = "0"
    public var nextOffset = 0
    public var hasMore = false
    public var isTruncated = false
    public var readState: ScanStopReason?
}

public struct ScanPage: Sendable {
    public let cursor: String
    public let keys: [RedisKey]
    public var requests = 1
    public var needsRetry = false
}

public struct SlowQuery: Identifiable, Sendable {
    public let id: Int64
    public let date: Date
    public let microseconds: Int64
    public let command: String
    public let client: String
}

public enum CommandLine {
    public static func parse(_ input: String) throws -> [String] {
        var result: [String] = [], token = "", quote: Character?, escaped = false, started = false
        for char in input {
            if escaped {
                switch char { case "n": token.append("\n"); case "r": token.append("\r"); case "t": token.append("\t"); default: token.append(char) }
                escaped = false; started = true
            } else if char == "\\" { escaped = true; started = true }
            else if let current = quote {
                if char == current { quote = nil } else { token.append(char) }
            } else if char == "\"" || char == "'" { quote = char; started = true }
            else if char.isWhitespace {
                if started { result.append(token); token = ""; started = false }
            } else { token.append(char); started = true }
        }
        guard quote == nil, !escaped else { throw RedisError.message("引号或转义尚未结束，请补全命令。") }
        if started { result.append(token) }
        return result
    }
}

public enum CommandPolicy {
    private static let blocked: Set<String> = [
        "AUTH", "SELECT", "HELLO", "QUIT", "RESET", "CLIENT", "MULTI", "EXEC", "DISCARD", "WATCH", "UNWATCH",
        "SUBSCRIBE", "PSUBSCRIBE", "SSUBSCRIBE", "UNSUBSCRIBE", "PUNSUBSCRIBE", "SUNSUBSCRIBE", "MONITOR",
        "BLPOP", "BRPOP", "BRPOPLPUSH", "BLMOVE", "BLMPOP", "BZPOPMIN", "BZPOPMAX", "BZMPOP",
        "FLUSHDB", "FLUSHALL", "SHUTDOWN", "DEBUG", "CONFIG", "ACL", "MODULE", "REPLICAOF", "SLAVEOF",
        "MIGRATE", "RESTORE", "SAVE", "BGSAVE", "BGREWRITEAOF", "REPLCONF", "SYNC", "PSYNC", "FAILOVER",
        "CLUSTER", "SENTINEL", "SCRIPT", "FUNCTION", "SWAPDB", "KEYS", "EVAL", "EVALSHA", "EVAL_RO", "EVALSHA_RO", "FCALL", "FCALL_RO"
    ]
    // Unknown and module commands are treated as writes, never inferred to be safe by their names.
    public static let readCommands: Set<String> = [
        "PING", "ECHO", "GET", "MGET", "GETRANGE", "STRLEN", "GETBIT", "BITCOUNT", "BITPOS", "TYPE", "EXISTS",
        "TTL", "PTTL", "EXPIRETIME", "PEXPIRETIME", "DBSIZE", "SCAN", "RANDOMKEY", "INFO", "TIME", "LASTSAVE",
        "HGET", "HMGET", "HGETALL", "HKEYS", "HVALS", "HLEN", "HEXISTS", "HSTRLEN", "HSCAN", "HRANDFIELD",
        "LINDEX", "LLEN", "LRANGE", "LPOS", "SCARD", "SISMEMBER", "SMISMEMBER", "SMEMBERS", "SSCAN", "SRANDMEMBER",
        "SINTER", "SUNION", "SDIFF", "SINTERCARD", "ZCARD", "ZCOUNT", "ZLEXCOUNT", "ZRANGE", "ZREVRANGE",
        "ZRANGEBYSCORE", "ZREVRANGEBYSCORE", "ZRANGEBYLEX", "ZSCORE", "ZMSCORE", "ZRANK", "ZREVRANK", "ZSCAN",
        "ZRANDMEMBER", "ZDIFF", "ZINTER", "ZUNION", "ZINTERCARD", "XLEN", "XRANGE", "XREVRANGE", "GEOHASH",
        "GEOPOS", "GEODIST", "GEOSEARCH", "DUMP", "COMMAND"
    ]
    public static func isRead(_ args: [String]) -> Bool {
        guard let name = args.first?.uppercased() else { return false }
        if name == "MEMORY" { return args.count >= 2 && ["USAGE", "STATS", "DOCTOR", "MALLOC-STATS"].contains(args[1].uppercased()) }
        if name == "SLOWLOG" { return args.count >= 2 && ["GET", "LEN", "HELP"].contains(args[1].uppercased()) }
        if name == "XINFO" { return true }
        return readCommands.contains(name)
    }
    public static func validate(_ args: [String], readOnly: Bool) throws {
        guard let name = args.first?.uppercased(), !name.isEmpty else { throw RedisError.message("请输入 Redis 命令。") }
        guard !blocked.contains(name), !["XREAD", "XREADGROUP"].contains(name) else {
            throw RedisError.message("工作台不执行 \(name)。请使用应用的连接/数据库控件，或在专用运维终端执行此类命令。")
        }
        if ["MEMORY", "SLOWLOG"].contains(name), !isRead(args) {
            throw RedisError.message("工作台只提供 \(name) 的只读诊断子命令。")
        }
        guard !readOnly || isRead(args) else { throw RedisError.message("当前连接为只读，不能执行写入或无法确认安全的命令。") }
    }
    public static let suggestions = ["PING", "GET", "SET", "SCAN", "TYPE", "TTL", "PTTL", "HGET", "HSET", "HSCAN", "LRANGE", "RPUSH", "SMEMBERS", "SADD", "ZRANGE", "ZADD", "XRANGE", "XADD", "INFO", "DBSIZE"]
}
