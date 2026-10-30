import Foundation
import zlib

public struct DecodeLimits: Sendable {
    public var maximumBytes = 1024 * 1024
    public var maximumExpansionRatio = 1024
    public var milliseconds = 200
    public init() {}
}

public struct DecodedValue: Sendable {
    public let bytes: Data
    public let text: String?
    public let isJSON: Bool
    public init(original: Data, codec: ValueCodec) throws {
        bytes = try codec.decode(original)
        text = bytes.contains(0) ? nil : String(data: bytes, encoding: .utf8)
        isJSON = text != nil && (try? JSONText.validate(bytes)) != nil
    }
}

public enum ValueCodec: String, CaseIterable, Codable, Sendable {
    case raw, base64, gzip, base64Gzip
    public var title: String {
        switch self { case .raw: return "原始"; case .base64: return "Base64"; case .gzip: return "Gzip"; case .base64Gzip: return "Base64 → Gzip" }
    }
    public func decode(_ original: Data, limits: DecodeLimits = DecodeLimits()) throws -> Data {
        let maximum = min(1024 * 1024, max(0, limits.maximumBytes))
        guard original.count <= maximum else { throw RedisError.message("编码输入超过预览上限。") }
        var value = original
        for stage in stages {
            if stage == .base64 {
                let normalized = Data(value.filter { ![UInt8(9), 10, 13, 32].contains($0) })
                guard let decoded = Data(base64Encoded: normalized), decoded.base64EncodedData() == normalized else { throw RedisError.message("Base64 格式无效或包含非规范数据。") }
                value = decoded
            } else { value = try Self.gzip(value, decompress: true, limits: limits) }
            guard value.count <= maximum else { throw RedisError.message("解码结果超过 1 MiB 预览上限。") }
        }
        return value
    }
    public func encode(_ replacement: Data, limits: DecodeLimits = DecodeLimits()) throws -> Data {
        let maximum = min(1024 * 1024, max(0, limits.maximumBytes))
        guard replacement.count <= maximum else { throw RedisError.message("编辑内容超过 1 MiB 上限。") }
        var value = replacement
        for stage in stages.reversed() {
            value = stage == .base64 ? value.base64EncodedData() : try Self.gzip(value, decompress: false, limits: limits)
            guard value.count <= maximum else { throw RedisError.message("重新编码后的值超过 1 MiB 编辑上限。") }
        }
        return value
    }
    private var stages: [ValueCodec] {
        switch self { case .raw: return []; case .base64: return [.base64]; case .gzip: return [.gzip]; case .base64Gzip: return [.base64, .gzip] }
    }
    private static func gzip(_ data: Data, decompress: Bool, limits: DecodeLimits) throws -> Data {
        var stream = z_stream()
        let initialized = decompress
            ? inflateInit2_(&stream, 15 + 16, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
            : deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
        guard initialized == Z_OK else { throw RedisError.message("无法初始化 Gzip 转换。") }
        defer { if decompress { inflateEnd(&stream) } else { deflateEnd(&stream) } }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(max(1, limits.milliseconds)))
        var output = Data(), chunk = [UInt8](repeating: 0, count: 16 * 1024)
        try data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress)
            stream.avail_in = uInt(data.count)
            while true {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw RedisError.message("Gzip 转换超过时间预算。") }
                let status = chunk.withUnsafeMutableBufferPointer { pointer -> Int32 in
                    stream.next_out = pointer.baseAddress; stream.avail_out = uInt(pointer.count)
                    return decompress ? inflate(&stream, Z_NO_FLUSH) : deflate(&stream, Z_FINISH)
                }
                let written = chunk.count - Int(stream.avail_out)
                guard output.count + written <= min(1024 * 1024, max(0, limits.maximumBytes)) else { throw RedisError.message("Gzip 输出超过 1 MiB 上限。") }
                if decompress {
                    let expanded = max(1, data.count).multipliedReportingOverflow(by: max(1, limits.maximumExpansionRatio))
                    guard expanded.overflow || output.count + written <= expanded.partialValue else { throw RedisError.message("Gzip 膨胀比超过限制。") }
                }
                output.append(contentsOf: chunk.prefix(written))
                if status == Z_STREAM_END {
                    guard stream.avail_in == 0 else { throw RedisError.message("Gzip 含多段或尾随内容，请保留原始字节查看。") }
                    return
                }
                guard status == Z_OK, written > 0 || stream.avail_in > 0 else { throw RedisError.message("Gzip 校验失败、数据损坏或内容不完整。") }
            }
        }
        return output
    }
}

public struct ValueChangeSummary: Sendable, Equatable {
    public let originalBytes: Int
    public let replacementBytes: Int
    public let firstChangedByte: Int
    public let removedBytes: Int
    public let insertedBytes: Int
    public init(original: Data, replacement: Data) {
        originalBytes = original.count; replacementBytes = replacement.count
        let lhs = [UInt8](original), rhs = [UInt8](replacement)
        var prefix = 0, suffix = 0
        while prefix < min(lhs.count, rhs.count), lhs[prefix] == rhs[prefix] { prefix += 1 }
        while suffix < min(lhs.count, rhs.count) - prefix, lhs[lhs.count - suffix - 1] == rhs[rhs.count - suffix - 1] { suffix += 1 }
        firstChangedByte = prefix; removedBytes = lhs.count - prefix - suffix; insertedBytes = rhs.count - prefix - suffix
    }
}
