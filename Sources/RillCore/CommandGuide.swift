import Foundation

public struct CommandGuide: Sendable {
    public let syntax: String
    public let note: String
    // Offline subset of the official redis.io command reference; availability remains server-dependent.
    private static let catalog: [String: CommandGuide] = {
        let rows = """
        PING|PING [message]|检查连接，或回显消息。
        GET|GET key|读取 String；不存在返回 nil。
        SET|SET key value [NX ／ XX] [EX seconds ／ PX milliseconds ／ KEEPTTL]|写入 String；不带过期选项会清除原 TTL。支持的选项依服务器版本而定。
        SCAN|SCAN cursor [MATCH pattern] [COUNT count] [TYPE type]|从游标 0 开始，返回游标 0 才结束；COUNT 是提示，可能空页或重复。
        TYPE|TYPE key|读取键类型。
        TTL|TTL key|单位秒；-1 永久，-2 不存在。
        PTTL|PTTL key|单位毫秒；-1 永久，-2 不存在。
        HGET|HGET key field|读取 Hash 字段。
        HSET|HSET key field value [field value ...]|新增或更新字段。
        HSCAN|HSCAN key cursor [MATCH pattern] [COUNT count]|游标扫描字段名；结果可能重复。
        LRANGE|LRANGE key start stop|按下标读取 List，包含 stop；-1 为末尾。
        RPUSH|RPUSH key element [element ...]|追加到 List 尾部。
        SMEMBERS|SMEMBERS key|返回整个 Set；大集合优先 SSCAN。
        SSCAN|SSCAN key cursor [MATCH pattern] [COUNT count]|按游标扫描成员；MATCH 匹配成员字节。
        SADD|SADD key member [member ...]|加入 Set 成员。
        ZRANGE|ZRANGE key start stop [BYSCORE ／ BYLEX] [REV] [LIMIT offset count] [WITHSCORES]|默认按排名升序；范围选项依服务器版本而定。
        ZSCAN|ZSCAN key cursor [MATCH pattern] [COUNT count]|按成员名扫描，返回成员与分值。
        ZADD|ZADD key [NX ／ XX] [CH] score member [score member ...]|写入有序集合成员及分值。
        XRANGE|XRANGE key start end [COUNT count]|升序；-、+ 表示首尾，(ID 表示排他边界（Redis 6.2+）。
        XREVRANGE|XREVRANGE key end start [COUNT count]|降序，注意范围参数为 end、start。
        XADD|XADD key * field value [field value ...]|追加 Stream 条目；字段按原顺序发送。
        INFO|INFO [section [section ...]]|读取服务器信息，ACL 可能限制。
        DBSIZE|DBSIZE|当前 DB 的键总数，包含尚未清理的过期键。
        MEMORY|MEMORY USAGE key [SAMPLES count]|工作台仅允许只读诊断子命令，如 USAGE、STATS。
        SLOWLOG|SLOWLOG GET [count]|还支持 LEN、HELP；耗时单位微秒。
        XINFO|XINFO STREAM key [FULL [COUNT count]]|还支持 GROUPS key、CONSUMERS key group。
        """
        return Dictionary(uniqueKeysWithValues: rows.split(separator: "\n").map {
            let parts = $0.split(separator: "|", maxSplits: 2).map(String.init)
            return (parts[0], CommandGuide(syntax: parts[1], note: parts[2]))
        })
    }()
    public static func lookup(_ input: String) -> CommandGuide? {
        input.split(whereSeparator: \.isWhitespace).first.flatMap { catalog[String($0).uppercased()] }
    }
    public static func completingName(_ input: String, with command: String) -> String {
        guard command.allSatisfy({ $0.isLetter }), !command.isEmpty else { return input }
        let leading = input.prefix(while: \.isWhitespace)
        let rest = input.dropFirst(leading.count)
        let name = rest.prefix(while: { !$0.isWhitespace })
        guard name.allSatisfy({ $0.isLetter }) else { return input }
        let suffix = rest.dropFirst(name.count)
        return String(leading) + command.uppercased() + (suffix.isEmpty ? " " : String(suffix))
    }
}

public struct CommandHistory: Sendable {
    public private(set) var commands: [String] = []
    public init() {}
    public mutating func record(_ command: String) {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, command.utf8.count <= 16_384 else { return }
        commands.removeAll { $0 == command }; commands.append(command)
        if commands.count > 100 { commands.removeFirst(commands.count - 100) }
    }
    public func matching(_ query: String) -> [String] {
        commands.reversed().filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
    }
}

public struct SavedKeySearch: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var mode: KeySearchMode
    public var text: String
    public var kind: String
    public init(mode: KeySearchMode, text: String, kind: String) { self.mode = mode; self.text = text; self.kind = kind }
    public var label: String { mode.title + " · " + (text.isEmpty ? "*" : String(text.prefix(60))) + (kind.isEmpty ? "" : " · " + kind) }
}
