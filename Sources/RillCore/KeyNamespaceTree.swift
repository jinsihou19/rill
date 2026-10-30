import Foundation

public struct KeyNamespaceNode: Identifiable, Sendable {
    public let id: String
    public let bytes: Data
    public let label: String
    public let isFolder: Bool
    public let binaryLabel: Bool
    public let children: [KeyNamespaceNode]
    public let keyCount: Int
}

public struct KeyNamespaceTree: Sendable {
    public let roots: [KeyNamespaceNode]
    public let isLimited: Bool

    public static func build(_ keys: [Data], separator: Data = Data(":".utf8), maximumFolders: Int = 100_000,
                             maximumDepth: Int = 64, maximumPrefixBytes: Int = 32 * 1024 * 1024) -> Self {
        let root = Builder(prefix: Data(), label: Data())
        var folders = 0, prefixBytes = 0, limited = false
        for key in keys {
            if Task.isCancelled { limited = true; break }
            var parent = root, start = key.startIndex, depth = 0
            while !separator.isEmpty, let range = key.range(of: separator, in: start..<key.endIndex) {
                let prefix = key.subdata(in: key.startIndex..<range.upperBound)
                if let existing = parent.folders[prefix] { parent = existing }
                else {
                    guard depth < maximumDepth, folders < maximumFolders, prefixBytes + prefix.count <= maximumPrefixBytes else { limited = true; break }
                    let child = Builder(prefix: prefix, label: key.subdata(in: start..<range.lowerBound))
                    parent.folders[prefix] = child; parent = child
                    folders += 1; prefixBytes += prefix.count
                }
                start = range.upperBound; depth += 1
            }
            parent.keys[key] = key.subdata(in: start..<key.endIndex)
        }
        return Self(roots: root.freeze(), isLimited: limited)
    }

    private final class Builder {
        let prefix: Data
        let label: Data
        var folders: [Data: Builder] = [:]
        var keys: [Data: Data] = [:]
        init(prefix: Data, label: Data) { self.prefix = prefix; self.label = label }
        func freeze() -> [KeyNamespaceNode] {
            let branches = folders.keys.sorted { $0.lexicographicallyPrecedes($1) }.map { prefix in
                let item = folders[prefix]!, children = item.freeze()
                return KeyNamespaceNode(id: "folder:" + prefix.base64EncodedString(), bytes: prefix,
                                        label: item.label.isEmpty ? "（空分段）" : DataPresentation.previewKey(item.label), isFolder: true,
                                        binaryLabel: String(data: item.label, encoding: .utf8) == nil || item.label.contains(0),
                                        children: children, keyCount: children.reduce(0) { $0 + $1.keyCount })
            }
            let leaves = keys.keys.sorted { $0.lexicographicallyPrecedes($1) }.map { key in
                let suffix = keys[key]!
                return KeyNamespaceNode(id: key.base64EncodedString(), bytes: key,
                                        label: suffix.isEmpty ? (key.isEmpty ? "（空键）" : "（空后缀）") : DataPresentation.previewKey(suffix),
                                        isFolder: false, binaryLabel: String(data: suffix, encoding: .utf8) == nil || suffix.contains(0), children: [], keyCount: 1)
            }
            return branches + leaves
        }
    }
}
