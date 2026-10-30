import Foundation

public enum JSONText {
    public static func validate(_ data: Data) throws { var parser = try Parser(data, pretty: false, emitOutput: false); _ = try parser.run() }
    public static func formatted(_ data: Data, pretty: Bool = true) throws -> Data {
        var parser = try Parser(data, pretty: pretty, emitOutput: true); return try parser.run()
    }
    private struct Parser {
        let bytes: [UInt8]
        let pretty: Bool
        let emitOutput: Bool
        var index = 0, depth = 0
        var output = Data()
        init(_ data: Data, pretty: Bool, emitOutput: Bool) throws {
            guard data.count <= 1024 * 1024, String(data: data, encoding: .utf8) != nil else { throw RedisError.message("JSON 需为 1 MiB 以内的有效 UTF-8 文本。") }
            bytes = [UInt8](data); self.pretty = pretty; self.emitOutput = emitOutput
        }
        mutating func run() throws -> Data {
            skipSpace(); try value(); skipSpace()
            guard index == bytes.count else { throw failure() }
            return output
        }
        func failure() -> RedisError { .message("JSON 格式无效，位于字节 \(index)。") }
        var next: UInt8? { index < bytes.count ? bytes[index] : nil }
        mutating func skipSpace() { while let byte = next, [UInt8(9), 10, 13, 32].contains(byte) { index += 1 } }
        mutating func emit(_ byte: UInt8) throws {
            guard emitOutput else { return }
            guard output.count < 1024 * 1024 else { throw RedisError.message("格式化结果超过 1 MiB 上限。") }
            output.append(byte)
        }
        mutating func emit(_ slice: ArraySlice<UInt8>) throws {
            guard emitOutput else { return }
            guard output.count + slice.count <= 1024 * 1024 else { throw RedisError.message("格式化结果超过 1 MiB 上限。") }
            output.append(contentsOf: slice)
        }
        mutating func newline() throws {
            guard pretty else { return }
            try emit(10)
            for _ in 0..<(depth * 2) { try emit(32) }
        }
        mutating func require(_ expected: UInt8) throws {
            guard next == expected else { throw failure() }; index += 1; try emit(expected)
        }
        mutating func value() throws {
            guard depth < 128, let byte = next else { throw failure() }
            switch byte {
            case 123, 91: try collection(object: byte == 123)
            case 34: try string()
            case 116: try literal(Array("true".utf8))
            case 102: try literal(Array("false".utf8))
            case 110: try literal(Array("null".utf8))
            case 45, 48...57: try number()
            default: throw failure()
            }
        }
        mutating func collection(object: Bool) throws {
            let open: UInt8 = object ? 123 : 91, close: UInt8 = object ? 125 : 93
            try require(open); skipSpace()
            if next == close { try require(close); return }
            depth += 1; try newline()
            while true {
                if object { try string(); skipSpace(); try require(58); if pretty { try emit(32) }; skipSpace() }
                try value(); skipSpace()
                if next == close { depth -= 1; try newline(); try require(close); return }
                try require(44); skipSpace(); try newline()
            }
        }
        mutating func literal(_ expected: [UInt8]) throws {
            let start = index
            for byte in expected { guard next == byte else { throw failure() }; index += 1 }
            try emit(bytes[start..<index])
        }
        mutating func number() throws {
            let start = index
            if next == 45 { index += 1 }
            if next == 48 { index += 1 }
            else { guard let byte = next, (49...57).contains(byte) else { throw failure() }; digits() }
            if next == 46 { index += 1; guard let byte = next, (48...57).contains(byte) else { throw failure() }; digits() }
            if next == 69 || next == 101 {
                index += 1; if next == 43 || next == 45 { index += 1 }
                guard let byte = next, (48...57).contains(byte) else { throw failure() }; digits()
            }
            try emit(bytes[start..<index])
        }
        mutating func digits() { while let byte = next, (48...57).contains(byte) { index += 1 } }
        mutating func string() throws {
            let start = index
            guard next == 34 else { throw failure() }; index += 1
            while let byte = next {
                index += 1
                if byte == 34 { try emit(bytes[start..<index]); return }
                guard byte >= 32 else { throw failure() }
                if byte == 92 {
                    guard let escaped = next else { throw failure() }; index += 1
                    if escaped == 117 {
                        let code = try hexScalar()
                        if (0xD800...0xDBFF).contains(code) {
                            guard next == 92 else { throw failure() }; index += 1
                            guard next == 117 else { throw failure() }; index += 1
                            guard (0xDC00...0xDFFF).contains(try hexScalar()) else { throw failure() }
                        } else if (0xDC00...0xDFFF).contains(code) { throw failure() }
                    } else if ![UInt8(34), 47, 92, 98, 102, 110, 114, 116].contains(escaped) { throw failure() }
                }
            }
            throw failure()
        }
        mutating func hexScalar() throws -> Int {
            var value = 0
            for _ in 0..<4 {
                guard let byte = next else { throw failure() }; index += 1
                let digit: Int
                switch byte { case 48...57: digit = Int(byte - 48); case 65...70: digit = Int(byte - 55); case 97...102: digit = Int(byte - 87); default: throw failure() }
                value = value * 16 + digit
            }
            return value
        }
    }
}
