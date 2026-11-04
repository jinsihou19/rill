import SwiftUI
import RillCore

extension ValueRow {
    var collectionPreview: String {
        guard let fields = streamFields else { return RESPValue.bulk(value).preview(maximumCharacters: 500) }
        let pairCount = fields.count / 2
        var lines = (0..<min(pairCount, 3)).map { index in
            "\(DataPresentation.previewKey(fields[index * 2], limit: 60)): \(DataPresentation.previewKey(fields[index * 2 + 1], limit: 140))"
        }
        if pairCount > 3 { lines.append("…（共 \(pairCount) 个字段）") }
        return lines.joined(separator: "\n")
    }
}

struct RowDetailView: View {
    let row: ValueRow
    let key: RedisKey
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    private var fieldTitle: String {
        switch key.kind { case .hash: return "Field"; case .list: return "Index"; case .stream: return "Entry ID"; default: return "Member" }
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeading(symbol: "doc.text.magnifyingglass", title: key.kind == .stream ? "条目详情" : "成员详情", subtitle: key.name)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(fieldTitle).font(.system(size: 12, weight: .medium))
                    Spacer()
                    Button("复制 \(fieldTitle)") { copyText(DataPresentation.text(row.field)) }.buttonStyle(.borderless)
                }
                CodeTextView(text: .constant(DataPresentation.text(row.field)), editable: false, fontSize: 12)
                    .frame(height: 72)
                if let score = row.score { LabeledContent("Score", value: score).fontDesign(.monospaced).textSelection(.enabled) }
            }.padding(18)
            Divider()
            HStack {
                Text(key.kind == .stream ? "全部字段 · JSON" : "完整值").font(.system(size: 12, weight: .medium))
                Spacer()
                Text(byteCount(Int64(row.value.count))).font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(.horizontal, 18).frame(height: 40)
            CodeTextView(text: .constant(row.valueText), editable: false, json: key.kind == .stream)
            Divider()
            HStack {
                Button(copied ? "已复制完整值" : "复制完整值") { copyText(row.valueText); copied = true }
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(18)
        }.frame(width: 760, height: 620).tint(RillTheme.accent)
    }
}
