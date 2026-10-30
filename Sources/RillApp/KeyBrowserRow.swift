import SwiftUI
import RillCore

struct KeyBrowserRow: View {
    @EnvironmentObject private var model: AppModel
    let key: RedisKey
    var label: String?
    var binaryLabel = false
    var body: some View {
        let revision = model.keyListRevision
        HStack(spacing: 8) {
            if model.showKeyTypes { Image(systemName: key.kind.symbol).font(.system(size: 11)).foregroundStyle(key.kind.color).frame(width: 14) }
            VStack(alignment: .leading, spacing: 4) {
                Text(label ?? DataPresentation.previewKey(key.bytes)).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                if binaryLabel { Text("HEX").font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundStyle(.secondary) }
                HStack(spacing: 7) {
                    if model.showKeyTypes { Text(key.rawType ?? "类型未知").font(.system(size: 9)).foregroundStyle(.secondary).help(key.typeError?.localizedDescription ?? "尚未读取") }
                    if model.showKeyTTL, let ttl = key.ttl, ttl >= 0 { Label("有过期时间", systemImage: "clock").font(.system(size: 9)).foregroundStyle(.secondary) }
                    if model.showKeyTTL, key.ttl == nil { Text("TTL 未知").font(.system(size: 9)).foregroundStyle(.secondary).help(key.ttlError?.localizedDescription ?? "尚未读取") }
                }
            }
            Spacer(minLength: 0)
            if model.isFavorite(key) { Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(.orange) }
        }.padding(.vertical, 6).id(key.id).help(DataPresentation.previewKey(key.bytes))
        .background(RowVisibility(identity: key.id + revision.uuidString) { visible, observer in
            if visible { model.keyAppeared(key.id, revision: revision, observer: observer) }
            else { model.keyDisappeared(key.id, revision: revision, observer: observer) }
        }.allowsHitTesting(false))
        .contextMenu {
            Button("复制键名", systemImage: "doc.on.doc") { copyText(key.name) }
            Button(model.isFavorite(key) ? "取消收藏" : "收藏键", systemImage: "star") { model.toggleFavorite(key) }
        }
    }
}

struct KeyNamespaceBranch: View {
    @EnvironmentObject private var model: AppModel
    let node: KeyNamespaceNode
    var depth = 0
    var body: some View {
        if node.isFolder {
            DisclosureGroup(isExpanded: Binding(get: { model.isNamespaceExpanded(node.id, depth: depth) }, set: { model.setNamespaceExpanded(node.id, expanded: $0) })) {
                ForEach(node.children) { KeyNamespaceBranch(node: $0, depth: depth + 1) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(node.label).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    if node.binaryLabel { Text("HEX").font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundStyle(.secondary) }
                    Spacer()
                    Text(String(node.keyCount)).font(.system(size: 10)).foregroundStyle(.tertiary)
                }.help("\(DataPresentation.previewKey(node.bytes)) · 已加载 \(node.keyCount) 个键")
            }.tag(node.id).padding(.vertical, 2)
            .contextMenu {
                Button("复制前缀", systemImage: "doc.on.doc") { copyText(DataPresentation.key(node.bytes)) }
                if String(data: RedisGlob.escapedPrefix(node.bytes), encoding: .utf8) != nil {
                    Button("查找此前缀", systemImage: "magnifyingglass") { model.searchNamespace(node) }
                }
            }
        } else if let key = model.key(id: node.id) { KeyBrowserRow(key: key, label: node.label, binaryLabel: node.binaryLabel).tag(key.id) }
    }
}
