import Foundation

public enum RedisError: LocalizedError, Equatable, Sendable {
    case message(String)
    case server(String)
    public var category: RedisFailureCategory {
        guard case .server(let text) = self else { return .other }
        let upper = text.uppercased()
        if upper.hasPrefix("NOPERM") { return .permission }
        if upper.hasPrefix("NOAUTH") || upper.hasPrefix("WRONGPASS") { return .authentication }
        if upper.hasPrefix("WRONGTYPE") { return .wrongType }
        if upper.hasPrefix("MOVED ") || upper.hasPrefix("ASK ") || upper.hasPrefix("CLUSTERDOWN") { return .topology }
        if upper.contains("UNKNOWN COMMAND") || upper.contains("UNSUPPORTED") { return .unsupported }
        return .other
    }
    public var errorDescription: String? {
        if case .message(let text) = self { return text }
        guard case .server(let text) = self else { return nil }
        switch category {
        case .permission: return "当前账户没有此命令或键的权限。\n\(text)"
        case .authentication: return "认证失败，请检查连接的用户名和密码。\n\(text)"
        case .unsupported: return "服务器或代理不支持此命令/选项。\n\(text)"
        case .wrongType: return "键的数据类型已变化或与操作不符，请刷新。\n\(text)"
        case .topology: return "服务器要求集群路由，当前连接无法完成此操作。\n\(text)"
        case .other: return text
        }
    }
}

public enum RedisFailureCategory: Sendable { case permission, authentication, unsupported, wrongType, topology, other }

public indirect enum RESPValue: Equatable, Sendable {
    case simple(String), error(String), integer(Int64), bulk(Data?), array([RESPValue]?)

    public var data: Data? {
        switch self {
        case .bulk(let data): return data
        case .simple(let text): return Data(text.utf8)
        default: return nil
        }
    }
    public var string: String? { data.flatMap { String(data: $0, encoding: .utf8) } }
    public var elements: [RESPValue]? { if case .array(let items) = self { return items }; return nil }
    public var number: Int64? { if case .integer(let n) = self { return n }; return string.flatMap(Int64.init) }
    public var serverError: RedisError? { if case .error(let text) = self { return .server(text) }; return nil }
    public func checked() throws -> RESPValue {
        if let error = serverError { throw error }
        return self
    }
    public var pretty: String {
        switch self {
        case .simple(let s): return s
        case .error(let s): return "(error) \(s)"
        case .integer(let n): return "(integer) \(n)"
        case .bulk(nil), .array(nil): return "(nil)"
        case .bulk(let data?): return DataPresentation.text(data)
        case .array(let items?):
            if items.isEmpty { return "(empty array)" }
            return items.enumerated().map { "\($0.offset + 1)) \($0.element.pretty)" }.joined(separator: "\n")
        }
    }
}

public enum RESPCodec {
    public static let maximumBytes = 32 * 1024 * 1024
    public static func encode(_ arguments: [Data]) -> Data {
        var output = Data("*\(arguments.count)\r\n".utf8)
        for arg in arguments {
            output.append(Data("$\(arg.count)\r\n".utf8)); output.append(arg); output.append(contentsOf: [13, 10])
        }
        return output
    }

    // A nil result means an incomplete frame. The caller retains the unconsumed bytes.
    public static func decode(_ input: Data) throws -> (value: RESPValue, consumed: Int)? {
        let bytes = [UInt8](input)
        var index = 0
        func parse(_ depth: Int) throws -> RESPValue? {
            guard depth < 64 else { throw RedisError.message("RESP 嵌套层数过多。") }
            let start = index
            guard index < bytes.count else { return nil }
            let marker = bytes[index]; index += 1
            let lineStart = index
            while index + 1 < bytes.count && !(bytes[index] == 13 && bytes[index + 1] == 10) { index += 1 }
            guard index + 1 < bytes.count else { index = start; return nil }
            let line = String(decoding: bytes[lineStart..<index], as: UTF8.self)
            index += 2
            switch marker {
            case 43: return .simple(line)
            case 45: return .error(line)
            case 58:
                guard let number = Int64(line) else { throw RedisError.message("无效的 RESP 整数。") }
                return .integer(number)
            case 36, 42:
                guard let count = Int(line), count >= -1, count <= maximumBytes else {
                    throw RedisError.message("RESP 响应超过 32 MiB 限制或长度无效。")
                }
                if count == -1 { return marker == 36 ? .bulk(nil) : .array(nil) }
                if marker == 36 {
                    guard bytes.count - index >= count + 2 else { index = start; return nil }
                    guard bytes[index + count] == 13, bytes[index + count + 1] == 10 else {
                        throw RedisError.message("RESP 数据结束符无效。")
                    }
                    let data = Data(bytes[index..<(index + count)]); index += count + 2
                    return .bulk(data)
                }
                guard count <= 100_000 else { throw RedisError.message("单次响应包含过多元素，请缩小查询范围。") }
                var items: [RESPValue] = []
                for _ in 0..<count {
                    guard let item = try parse(depth + 1) else { index = start; return nil }
                    items.append(item)
                }
                return .array(items)
            default: throw RedisError.message("不支持的 RESP 类型：\(marker)。")
            }
        }
        guard let value = try parse(0) else { return nil }
        return (value, index)
    }
}

public enum DataPresentation {
    public static func text(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8), !data.contains(0) { return text }
        let digits = Array("0123456789abcdef".utf8)
        var output: [UInt8] = [48, 120]; output.reserveCapacity(2 + data.count * 2)
        for byte in data { output.append(digits[Int(byte >> 4)]); output.append(digits[Int(byte & 15)]) }
        return String(decoding: output, as: UTF8.self)
    }
    public static func key(_ data: Data) -> String {
        text(data).replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\t", with: "\\t")
    }
    public static func previewKey(_ data: Data, limit: Int = 256) -> String {
        var prefix = Data(data.prefix(max(0, limit)))
        if prefix.count < data.count, !prefix.isEmpty {
            var end = prefix.count
            while end > 0, (0x80...0xBF).contains(prefix[end - 1]) { end -= 1 }
            if end > 0 {
                let lead = prefix[end - 1]
                let expected = (0xC2...0xDF).contains(lead) ? 2 : (0xE0...0xEF).contains(lead) ? 3 : (0xF0...0xF4).contains(lead) ? 4 : 1
                if prefix.count - end + 1 < expected { prefix = Data(prefix.prefix(end - 1)) }
            }
        }
        return key(prefix) + (data.count > prefix.count ? "…（\(data.count) 字节）" : "")
    }
    public static func hex(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }
        let digits = Array("0123456789ABCDEF".utf8), bytes = [UInt8](data)
        var output = [UInt8](); output.reserveCapacity((bytes.count + 15) / 16 * 77)
        for offset in stride(from: 0, to: bytes.count, by: 16) {
            if offset > 0 { output.append(10) }
            for shift in stride(from: 28, through: 0, by: -4) { output.append(digits[(offset >> shift) & 15]) }
            output.append(contentsOf: [32, 32])
            let end = min(offset + 16, bytes.count)
            for index in 0..<16 {
                if offset + index < end { let b = bytes[offset + index]; output.append(digits[Int(b >> 4)]); output.append(digits[Int(b & 15)]); output.append(32) }
                else { output.append(contentsOf: [32, 32, 32]) }
            }
            output.append(contentsOf: [32, 32])
            for b in bytes[offset..<end] { output.append((32...126).contains(b) ? b : 46) }
        }
        return String(decoding: output, as: UTF8.self)
    }
}
