import SwiftUI
import RillCore

struct KeyDetailView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedRow: String?
    @State private var showChanges = false
    @State private var localMemberFilter = ""
    private var textEditable: Bool { model.textValueEditable }
    private var isTextValue: Bool { model.decodedValue?.text != nil }
    var body: some View {
        Group {
            if model.isLoadingDetail && model.detail == nil {
                VStack(spacing: 12) {
                    ProgressView(model.isStoppingMembers ? "正在停止；等待当前响应…" : "读取数据…")
                    Button("停止读取") { model.stopMemberRead() }.disabled(model.isStoppingMembers)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    Button("完整导出此键…", systemImage: "square.and.arrow.up.on.square") { model.exportFullKey() }.disabled(model.isExportingKey || page.key.kind == .unknown)
                    Button("复制到新键…", systemImage: "plus.square.on.square") { model.sheet = EditorSheet(kind: .copy) }.disabled(!model.canWrite)
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
                }.labelsHidden().pickerStyle(.segmented).frame(width: 150)
                Picker("解码方式", selection: Binding(get: { model.valueCodec }, set: { model.chooseValueCodec($0) })) {
                    ForEach(ValueCodec.allCases, id: \.self) { Text($0.title).tag($0) }
                }.labelsHidden().frame(width: 130).disabled(model.busy)
                Spacer()
                if model.valueFormat != "Hex", textEditable {
                    Button { model.formatJSON() } label: { Image(systemName: "curlybraces") }.help("无损格式化 JSON 草稿").disabled(!model.canWrite)
                }
                Button { copyText(model.valueFormat == "Hex" || !isTextValue ? model.valueHex : model.draft); model.notify("值已复制") } label: { Image(systemName: "doc.on.doc") }.help("复制当前显示的值")
            }.buttonStyle(.borderless).padding(.horizontal, 18).frame(height: 47)
            Divider()
            if page.isTruncated {
                Label("仅预览前 1 MiB，共 \(byteCount(page.count))；为避免截断覆盖，此值不能编辑。", systemImage: "info.circle")
                    .font(.system(size: 11)).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading).padding(12).background(Color.orange.opacity(0.05))
            } else if let failure = model.valueDecodeError {
                Label(failure + " 原始字节已保留，可切回原始查看。", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(.orange).padding(12)
            } else if !isTextValue && !model.isPreparingValue {
                Label("包含二进制数据，使用 Hex 查看或导出原始字节。", systemImage: "doc.zipper")
                    .font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            if model.isPreparingValue {
                ProgressView("转换中…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.valueFormat == "Hex" || !isTextValue {
                CodeTextView(text: .constant(model.valueHex), editable: false, fontSize: 11)
            } else {
                CodeTextView(text: $model.draft, editable: textEditable && model.activeProfile?.readOnly == false && !model.isWriting, json: model.valueFormat == "JSON")
                    .id(page.key.id + model.valueCodec.rawValue).accessibilityIdentifier("valueEditor")
            }
            HStack {
                if model.dirty { Circle().fill(.orange).frame(width: 5, height: 5); Text("未保存").foregroundStyle(.secondary) }
                else { Text(!textEditable ? "只读预览" : model.activeProfile?.readOnly == true ? "只读连接" : "保存时检查冲突并保留 TTL").foregroundStyle(.tertiary) }
                Spacer()
                if let change = model.valueChange, model.dirty {
                    Button("写入 \(change.replacementBytes) B") { showChanges.toggle() }
                        .popover(isPresented: $showChanges) {
                            Text("原始值 \(change.originalBytes) 字节 → 写入 \(change.replacementBytes) 字节\n从偏移 \(change.firstChangedByte) 起，替换 \(change.removedBytes) 字节为 \(change.insertedBytes) 字节。\n按 \(model.valueCodec.title) 逆向编码；保存时检查原值并保留 TTL。")
                                .font(.system(size: 12)).padding(20)
                        }
                }
                if model.dirty {
                    Button("还原") { model.restoreValueDraft() }.disabled(model.isWriting)
                }
                Button("保存修改") { model.saveString() }.buttonStyle(.borderedProminent).keyboardShortcut("s", modifiers: .command)
                    .disabled(!model.canWrite || !model.dirty || !textEditable || model.valueFormat == "Hex")
            }.font(.system(size: 11)).padding(.horizontal, 19).frame(height: 54)
            if let failure = model.valueEncodeError { Text(failure).font(.system(size: 11)).foregroundStyle(.orange).padding(8) }
        }
        .onChange(of: model.draft) { model.refreshValuePresentation() }
        .onChange(of: model.valueFormat) { model.refreshValuePresentation(); model.saveBrowserPreferences() }
    }

    private func collectionEditor(_ page: KeyPage) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(page.key.kind == .stream ? "条目" : "成员").font(.system(size: 12, weight: .medium))
                Text("\(page.rows.count) / \(page.count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).help("已加载匹配数 / 此键总成员数；后者不是匹配总数")
                Spacer()
                if page.key.kind == .stream { Text(model.memberQuery.newestFirst ? "最新优先" : "最早优先").font(.system(size: 10)).foregroundStyle(.tertiary) }
                if page.key.kind == .zset { Text(model.memberQuery.pattern.isEmpty ? "按分值升序" : "游标扫描顺序").font(.system(size: 10)).foregroundStyle(.tertiary) }
                Button { model.sheet = EditorSheet(kind: .row(nil)) } label: { Label("新增", systemImage: "plus") }.disabled(!model.canWrite).font(.system(size: 11))
            }.padding(.horizontal, 19).frame(height: 47)
            Divider()
            if page.key.kind == .stream {
                HStack(spacing: 8) {
                    Picker("方向", selection: $model.streamNewestFirst) { Text("最新优先").tag(true); Text("最早优先").tag(false) }.labelsHidden().frame(width: 112)
                    TextField("起始 ID / -", text: $model.streamStart).textFieldStyle(.roundedBorder).onSubmit { model.applyMemberQuery() }
                    Text("至").foregroundStyle(.secondary)
                    TextField("结束 ID / +", text: $model.streamEnd).textFieldStyle(.roundedBorder).onSubmit { model.applyMemberQuery() }
                    Button("应用") { model.applyMemberQuery() }.disabled(model.busy)
                }.font(.system(size: 11)).padding(12)
            } else if page.key.kind == .list {
                TextField("过滤已加载的 List 内容", text: $localMemberFilter).textFieldStyle(.roundedBorder).padding(12)
            } else {
                HStack {
                    TextField("服务端 MATCH · 字段/成员 glob", text: $model.memberPattern).textFieldStyle(.roundedBorder).onSubmit { model.applyMemberQuery() }
                    Button("查找") { model.applyMemberQuery() }.disabled(model.busy)
                }.font(.system(size: 11)).padding(12)
            }
            Table(localMemberFilter.isEmpty || page.key.kind != .list ? page.rows : page.rows.filter { $0.valueText.localizedCaseInsensitiveContains(localMemberFilter) }, selection: $selectedRow) {
                TableColumn(columnTitle(page.key.kind)) { row in
                    Text(DataPresentation.previewKey(row.field)).font(RillTheme.mono).lineLimit(2).textSelection(.enabled)
                }.width(min: 95, ideal: page.key.kind == .stream ? 150 : 150, max: 250)
                TableColumn(page.key.kind == .zset ? "Score" : page.key.kind == .set ? "字节" : "Value") { row in
                    Text(page.key.kind == .set ? String(row.value.count) : row.score ?? RESPValue.bulk(row.value).preview(maximumCharacters: 500)).font(RillTheme.mono).lineLimit(page.key.kind == .stream ? 4 : 3).textSelection(.enabled)
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
                    } label: { Image(systemName: "ellipsis") }.menuIndicator(.hidden).menuStyle(.borderlessButton).fixedSize().accessibilityLabel("成员 \(DataPresentation.previewKey(row.field)) 的操作")
                }.width(25)
            }.tableStyle(.inset(alternatesRowBackgrounds: true))
            if page.hasMore {
                HStack {
                    Text(page.readState == .paused ? "已停止，可继续" : "已加载范围；并发修改可能影响分页").font(.system(size: 10)).foregroundStyle(.tertiary)
                    Spacer()
                    if model.isLoadingDetail { Button(model.isStoppingMembers ? "正在停止…" : "停止") { model.stopMemberRead() }.disabled(model.isStoppingMembers) }
                    else { Button("继续读取") { model.loadMoreRows() }.disabled(model.busy) }
                }.padding(15)
            }
            if page.readState == .capacity {
                Text("已达 1 万成员 / 16 MiB 上限，请缩小筛选范围；当前结果不完整。")
                    .font(.system(size: 11)).foregroundStyle(.orange).padding(12)
            }
        }.onChange(of: page.key.id) { localMemberFilter = ""; selectedRow = nil }
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
