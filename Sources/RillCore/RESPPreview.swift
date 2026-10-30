import Foundation

public extension RESPValue {
    func preview(maximumCharacters: Int = 100_000) -> String {
        var remaining = min(1_000_000, max(0, maximumCharacters)), output = "", truncated = false
        func append(_ text: String) {
            let end = text.index(text.startIndex, offsetBy: remaining, limitedBy: text.endIndex) ?? text.endIndex
            let part = text[..<end]; output.append(contentsOf: part); remaining -= part.count
            if end != text.endIndex { truncated = true }
        }
        func visit(_ value: RESPValue) {
            switch value {
            case .simple(let text): append(text)
            case .error(let text): append("(error) "); append(text)
            case .integer(let number): append("(integer) \(number)")
            case .bulk(nil), .array(nil): append("(nil)")
            case .bulk(let data?):
                var prefix = Data(data.prefix(remaining))
                if prefix.count < data.count, !prefix.isEmpty {
                    var end = prefix.count
                    while end > 0, (0x80...0xBF).contains(prefix[end - 1]) { end -= 1 }
                    if end > 0 {
                        let lead = prefix[end - 1]
                        let length = (0xC2...0xDF).contains(lead) ? 2 : (0xE0...0xEF).contains(lead) ? 3 : (0xF0...0xF4).contains(lead) ? 4 : 1
                        if prefix.count - end + 1 < length { prefix = Data(prefix.prefix(end - 1)) }
                    }
                }
                if let text = String(data: prefix, encoding: .utf8), !prefix.contains(0) {
                    append(text); if prefix.count < data.count { truncated = true }
                } else {
                    append("0x")
                    let count = min(data.count, remaining / 2), digits = Array("0123456789abcdef".utf8)
                    var bytes: [UInt8] = []; bytes.reserveCapacity(count * 2)
                    for byte in data.prefix(count) { bytes.append(digits[Int(byte >> 4)]); bytes.append(digits[Int(byte & 15)]) }
                    append(String(decoding: bytes, as: UTF8.self)); if count < data.count { truncated = true }
                }
            case .array(let values?):
                if values.isEmpty { append("(empty array)"); return }
                for (index, item) in values.enumerated() {
                    if remaining == 0 { truncated = true; break }
                    if index > 0 { append("\n") }; append("\(index + 1)) "); visit(item)
                }
            }
        }
        visit(self)
        return output + (truncated ? "\n…显示已截断" : "")
    }
}
