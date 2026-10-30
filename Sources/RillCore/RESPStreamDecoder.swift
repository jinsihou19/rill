import Foundation

// Frame once as bytes arrive; decode values only after a complete frame is available.
public struct RESPStreamDecoder {
    private var bytes: [UInt8] = []
    private var cursor = 0
    private var frameStart = 0
    private var marker: UInt8?
    private var lineStart = 0
    private var lineSearch = 0
    private var bulkEnd: Int?
    private var remaining: [Int] = []
    public init() {}
    public mutating func append(_ data: Data) throws {
        guard bytes.count - frameStart + data.count <= RESPCodec.maximumBytes else { throw RedisError.message("响应超过 32 MiB，请使用分段查询。") }
        if frameStart > 0 {
            bytes.removeFirst(frameStart); cursor -= frameStart; lineStart -= frameStart; lineSearch -= frameStart
            if let end = bulkEnd { bulkEnd = end - frameStart }
            frameStart = 0
        }
        bytes.append(contentsOf: data)
    }
    public mutating func next() throws -> RESPValue? {
        while true {
            if let end = bulkEnd {
                guard bytes.count >= end else { return nil }
                guard bytes[end - 2] == 13, bytes[end - 1] == 10 else { throw RedisError.message("RESP 数据结束符无效。") }
                cursor = end; bulkEnd = nil
                if completeItem() { return try finish() }
                continue
            }
            if marker == nil {
                guard cursor < bytes.count else { return nil }
                guard remaining.count < 64 else { throw RedisError.message("RESP 嵌套层数过多。") }
                marker = bytes[cursor]; cursor += 1; lineStart = cursor; lineSearch = cursor
            }
            while lineSearch + 1 < bytes.count, !(bytes[lineSearch] == 13 && bytes[lineSearch + 1] == 10) { lineSearch += 1 }
            guard lineSearch + 1 < bytes.count else { return nil }
            let kind = marker!, line = String(decoding: bytes[lineStart..<lineSearch], as: UTF8.self)
            cursor = lineSearch + 2; marker = nil
            switch kind {
            case 43, 45: if completeItem() { return try finish() }
            case 58:
                guard Int64(line) != nil else { throw RedisError.message("无效的 RESP 整数。") }
                if completeItem() { return try finish() }
            case 36, 42:
                guard let count = Int(line), count >= -1, count <= RESPCodec.maximumBytes else { throw RedisError.message("RESP 长度无效或超过上限。") }
                if count == -1 || (kind == 42 && count == 0) { if completeItem() { return try finish() }; continue }
                if kind == 36 {
                    guard cursor - frameStart + count + 2 <= RESPCodec.maximumBytes else { throw RedisError.message("RESP 响应超过 32 MiB。") }
                    bulkEnd = cursor + count + 2
                } else {
                    guard count <= 100_000 else { throw RedisError.message("单次响应包含过多元素，请缩小查询范围。") }
                    remaining.append(count)
                }
            default: throw RedisError.message("不支持的 RESP 类型：\(kind)。")
            }
        }
    }
    private mutating func completeItem() -> Bool {
        while !remaining.isEmpty {
            remaining[remaining.count - 1] -= 1
            if remaining.last! > 0 { return false }
            remaining.removeLast()
        }
        return true
    }
    private mutating func finish() throws -> RESPValue {
        let frame = Data(bytes[frameStart..<cursor])
        guard let parsed = try RESPCodec.decode(frame), parsed.consumed == frame.count else { throw RedisError.message("RESP 分帧无效。") }
        frameStart = cursor
        if cursor == bytes.count {
            bytes.removeAll(keepingCapacity: bytes.capacity <= 1024 * 1024)
            frameStart = 0; cursor = 0; lineStart = 0; lineSearch = 0
        }
        return parsed.value
    }
}
