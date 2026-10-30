import Foundation

public enum JSONHighlight {
    public enum Kind: Sendable { case key, string, number, literal }
    public struct Span: Sendable { public let range: NSRange; public let kind: Kind }
    private static let expression = try! NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*"|\b(?:true|false|null)\b|-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?"#)
    public static func spans(_ text: String) -> [Span] {
        let source = text as NSString
        guard source.length < 200_000 else { return [] }
        return expression.matches(in: text, range: NSRange(location: 0, length: source.length)).map { match in
            let token = source.substring(with: match.range)
            var kind: Kind = token.hasPrefix("\"") ? .string : ["true", "false", "null"].contains(token) ? .literal : .number
            if kind == .string {
                var end = NSMaxRange(match.range)
                while end < source.length, [9, 10, 13, 32].contains(source.character(at: end)) { end += 1 }
                if end < source.length, source.character(at: end) == 58 { kind = .key }
            }
            return Span(range: match.range, kind: kind)
        }
    }
}
