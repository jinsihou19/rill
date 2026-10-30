import SwiftUI
import RillCore

struct KeyDetailView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedRow: String?
    private var textEditable: Bool {
        guard let page = model.detail, let data = page.content else { return false }
        return !page.isTruncated && !data.contains(0) && String(data: data, encoding: .utf8) != nil
    }
    private var isTextValue: Bool {
        guard let data = model.detail?.content else { return false }
        return !data.contains(0) && String(data: data, encoding: .utf8) != nil
    }
    var body: some View {
        Group {
            if model.isLoadingDetail && model.detail == nil {
                ProgressView("读取数据…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let page = model.detail {
                VStack(spacing: 0) {
                    header(page)
                    Divider()
                    if page.key.kind == .string { stringEditor(page) }
                    else if page.key.kind == .unknown {
                        EmptyState(symbol: "puzzlepiece.extension", title: "此数据类型尚无专用编辑器", message: "可以通过工作台查询。模块命令在只读连接中会被拒绝。") { Button("打开工作台") { model.switchTab(.console) } }
                    } else { collectionEditor(page) }
                    Divider()
                    footer(page)
                }
            } else {
                EmptyState(symbol: "cursorarrow.click.2", title: "选择一个键，开始探索", message: "浏览它的结构、检查过期时间，\n或打开工作台执行 Redis 命令。") {
                    HStack(spacing: 16) {
                        Label("⌘ F 搜索", systemImage: "magnifyingglass")
                        Label("⌘ 2 工作台", systemImage: "terminal")
                    }.font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
        }.background(RillTheme.canvas)
    }

    private func header(_ page: KeyPage) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 8) {
                    TypeBadge(kind: page.key.kind)
                    Text(page.key.name).font(.system(size: 18, weight: .semibold, design: .monospaced)).textSelection(.enabled).lineLimit(3).truncationMode(.middle)
                }
                Spacer(minLength: 6)
                Button { model.toggleFavorite(page.key) } label: { Image(systemName: model.isFavorite(page.key) ? "star.fill" : "star") }
                    .foregroundStyle(model.isFavorite(page.key) ? .orange : .secondary).help("收藏键").accessibilityLabel("收藏当前键")
                Menu {
                    Button("复制键名", systemImage: "doc.on.doc") { copyText(page.key.name); model.notify("键名已复制") }
                    Button("导出当前页", systemImage: "square.and.arrow.up") { model.exportCurrentPage() }
                    Divider()
                    Button("重命名", systemImage: "pencil") { model.sheet = EditorSheet(kind: .rename) }.disabled(!model.canWrite)
                    Button("设置过期时间", systemImage: "clock") { model.sheet = EditorSheet(kind: .ttl) }.disabled(!model.canWrite)
                    Divider()
                    Button("删除键", systemImage: "trash", role: .destructive) { model.deleteCurrentKey() }.disabled(!model.canWrite)
                } label: { Image(systemName: "ellipsis") }.menuIndicator(.hidden).menuStyle(.borderlessButton).fixedSize().help("键操作").accessibilityLabel("当前键操作")
            }.buttonStyle(.borderless)
            HStack(spacing: 14) {
                Label(page.key.kind == .string ? byteCount(page.count) : "\(page.count.formatted()) 个成员", systemImage: page.key.kind == .string ? "doc.text" : "square.stack")
                if let memory = page.memory { Label(byteCount(memory), systemImage: "memorychip").help("Redis MEMORY USAGE 的估计值") }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let ttl = page.key.ttl.map { $0 < 0 ? $0 : max(0, $0 - Int64(context.date.timeIntervalSince(page.fetchedAt) * 1000)) }
                    Button { model.sheet = EditorSheet(kind: .ttl) } label: {
                        Label(ttl.map { $0 < 0 ? "永久有效" : $0 == 0 ? "即将过期 · 请刷新" : "TTL \($0 / 1000)s" } ?? "TTL 未知", systemImage: "clock")
                    }.buttonStyle(.plain).foregroundStyle(ttl.map { $0 >= 0 && $0 < 60_000 } == true ? .orange : .secondary).disabled(!model.canWrite)
                        .help(page.key.ttlError?.localizedDescription ?? "剩余生存时间")
                }
                if let failure = page.key.memoryError { Image(systemName: "info.circle").help(failure.localizedDescription) }
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(23)
    }

    private func stringEditor(_ page: KeyPage) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("值的显示格式", selection: $model.valueFormat) {
                    Text("文本").tag("文本"); Text("JSON").tag("JSON"); Text("Hex").tag("Hex")
                }.labelsHidden().pickerStyle(.segmented).frame(width: 200)
                Spacer()
                if model.valueFormat != "Hex", textEditable {
                    Button { model.formatJSON() } label: { Label("格式化 JSON", systemImage: "curlybraces") }.font(.system(size: 11)).disabled(!model.canWrite)
                }
                Button { copyText(model.valueFormat == "Hex" || !isTextValue ? DataPresentation.hex(page.content ?? Data()) : model.draft); model.notify("值已复制") } label: { Image(systemName: "doc.on.doc") }.help("复制当前显示的值")
            }.buttonStyle(.borderless).padding(.horizontal, 18).frame(height: 47)
            Divider()
            if page.isTruncated {
                Label("仅预览前 1 MiB，共 \(byteCount(page.count))；为避免截断覆盖，此值不能编辑。", systemImage: "info.circle")
                    .font(.system(size: 11)).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading).padding(12).background(Color.orange.opacity(0.05))
            } else if !isTextValue {
                Label("包含二进制数据，使用 Hex 查看或导出原始字节。", systemImage: "doc.zipper")
                    .font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            if model.valueFormat == "Hex" || !isTextValue {
                CodeTextView(text: .constant(DataPresentation.hex(page.content ?? Data())), editable: false, fontSize: 11)
            } else {
                CodeTextView(text: $model.draft, editable: textEditable && model.activeProfile?.readOnly == false && !model.isWriting, json: model.valueFormat == "JSON")
                    .accessibilityIdentifier("valueEditor")
            }
            HStack {
                if model.dirty { Circle().fill(.orange).frame(width: 5, height: 5); Text("未保存").foregroundStyle(.secondary) }
                else { Text(!textEditable ? "只读预览" : model.activeProfile?.readOnly == true ? "只读连接" : "保存时检查冲突并保留 TTL").foregroundStyle(.tertiary) }
                Spacer()
                if model.dirty {
                    Button("还原") { model.draft = page.content.flatMap { String(data: $0, encoding: .utf8) } ?? "" }.disabled(model.isWriting)
                }
                Button("保存修改") { model.saveString() }.buttonStyle(.borderedProminent).keyboardShortcut("s", modifiers: .command)
                    .disabled(!model.canWrite || !model.dirty || !textEditable || model.valueFormat == "Hex")
            }.font(.system(size: 11)).padding(.horizontal, 19).frame(height: 54)
        }
    }

    private func collectionEditor(_ page: KeyPage) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(page.key.kind == .stream ? "条目" : "成员").font(.system(size: 12, weight: .medium))
                Text("\(page.rows.count) / \(page.count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                if page.key.kind == .stream { Text("按条目 ID 升序").font(.system(size: 10)).foregroundStyle(.tertiary) }
                if page.key.kind == .zset { Text("按分值升序").font(.system(size: 10)).foregroundStyle(.tertiary) }
                Button { model.sheet = EditorSheet(kind: .row(nil)) } label: { Label("新增", systemImage: "plus") }.disabled(!model.canWrite).font(.system(size: 11))
            }.padding(.horizontal, 19).frame(height: 47)
            Divider()
            Table(page.rows, selection: $selectedRow) {
                TableColumn(columnTitle(page.key.kind)) { row in
                    Text(row.fieldText).font(RillTheme.mono).lineLimit(2).textSelection(.enabled)
                }.width(min: 95, ideal: page.key.kind == .stream ? 150 : 150, max: 250)
                TableColumn(page.key.kind == .zset ? "Score" : page.key.kind == .set ? "字节" : "Value") { row in
                    Text(page.key.kind == .set ? String(row.value.count) : row.score ?? String(row.valueText.prefix(500))).font(RillTheme.mono).lineLimit(page.key.kind == .stream ? 4 : 3).textSelection(.enabled)
                }.width(min: 150, ideal: 320)
                TableColumn("") { row in
                    Menu {
                        Button("复制值", systemImage: "doc.on.doc") { copyText(row.valueText); model.notify("已复制") }
                        if [.hash, .list, .zset].contains(page.key.kind) {
                            Button("编辑", systemImage: "pencil") { model.sheet = EditorSheet(kind: .row(row)) }.disabled(!model.canWrite)
                        }
                        if page.key.kind != .list {
                            Button("删除成员", systemImage: "trash", role: .destructive) {
                                model.mutate("删除成员", message: "从「\(page.key.name)」中删除「\(row.fieldText)」。", destructive: true) { try await $0.deleteRow(key: page.key.bytes, kind: page.key.kind, row: row) }
                            }.disabled(!model.canWrite)
                        }
                    } label: { Image(systemName: "ellipsis") }.menuIndicator(.hidden).menuStyle(.borderlessButton).fixedSize().accessibilityLabel("成员 \(row.fieldText) 的操作")
                }.width(25)
            }.tableStyle(.inset(alternatesRowBackgrounds: true))
            if page.hasMore {
                HStack {
                    Text("集合在并发修改时，分页结果可能变化。").font(.system(size: 10)).foregroundStyle(.tertiary)
                    Spacer()
                    Button("加载下一页") { model.loadMoreRows() }.disabled(model.busy)
                }.padding(15)
            }
        }
    }
    private func columnTitle(_ kind: KeyKind) -> String {
        switch kind { case .hash: return "Field"; case .list: return "Index"; case .stream: return "Entry ID"; default: return "Member" }
    }
    private func footer(_ page: KeyPage) -> some View {
        HStack(spacing: 6) {
            Text("DB \(model.activeProfile?.database ?? 0)"); Text("/"); Text(page.key.kind.title)
            Spacer()
            Text("读取于 \(page.fetchedAt.formatted(date: .omitted, time: .standard))")
            Button { model.guardDraft { model.selectKey(page.key.id, force: true) } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).help("重新读取当前键").disabled(model.busy)
        }.font(.system(size: 10)).foregroundStyle(.tertiary).padding(.horizontal, 18).frame(height: 32)
    }
}
