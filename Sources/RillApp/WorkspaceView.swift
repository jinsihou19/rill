import SwiftUI
import RillCore

struct WorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    @State private var visibility: NavigationSplitViewVisibility = .all
    @FocusState private var searchFocused: Bool
    @State private var collapsedNamespaces: Set<String> = []

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            sidebar.navigationSplitViewColumnWidth(min: 205, ideal: 228, max: 300)
        } detail: {
            VStack(spacing: 0) {
                if let error = model.error { errorBanner(error) }
                if model.isConnecting {
                    VStack(spacing: 14) { ProgressView(); Text("正在连接 \(model.activeProfile?.name ?? "Redis")…").foregroundStyle(.secondary); Button("取消") { model.disconnect() } }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.connected {
                    workspaceHeader
                    Divider()
                    switch model.tab {
                    case .browser: browser
                    case .console: ConsoleView()
                    case .overview: OverviewView()
                    case .slowlog: SlowlogView()
                    }
                    statusBar
                } else { welcome }
            }.background(RillTheme.canvas)
        }
        .frame(minWidth: 1020, minHeight: 660)
        .navigationTitle(model.activeProfile?.name ?? "Rill")
        .tint(RillTheme.accent)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                if let profile = model.activeProfile { EnvironmentBadge(environment: profile.environment).fixedSize() }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if model.connected {
                    Menu {
                        Button("编辑当前连接…", systemImage: "slider.horizontal.3") { model.editConnection(model.activeProfile) }
                        Button("断开连接", systemImage: "eject") { model.disconnect() }
                    } label: { Image(systemName: "slider.horizontal.3") }.disabled(model.busy).help("连接设置").accessibilityLabel("连接设置")
                    if model.activeProfile?.readOnly == true { Label("只读", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary) }
                    Button { refresh() } label: { Image(systemName: "arrow.clockwise") }.help("刷新 · ⌘R").disabled(model.busy)
                    Button { model.sheet = EditorSheet(kind: .newKey) } label: { Label("新建键", systemImage: "plus") }.disabled(!model.canWrite)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Label(toast, systemImage: "checkmark.circle.fill").font(.callout).padding(.horizontal, 18).padding(.vertical, 11)
                    .background(.regularMaterial, in: Capsule()).shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                    .padding(.bottom, 45).allowsHitTesting(false).transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: model.toast)
        .sheet(item: $model.sheet, onDismiss: model.editorDismissed) { sheet in
            switch sheet.kind {
            case .connection(let profile, let password): ConnectionEditor(profile: profile, password: password)
            case .newKey: DataEditor(mode: .newKey)
            case .row(let row): DataEditor(mode: .row(row))
            case .ttl: MetadataEditor(mode: .ttl)
            case .rename: MetadataEditor(mode: .rename)
            }
        }
        .sheet(item: $model.confirmation, onDismiss: model.confirmationDismissed) { request in ConfirmationView(request: request) }
        .onReceive(NotificationCenter.default.publisher(for: .rillFocusSearch)) { _ in model.switchTab(.browser); searchFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: .rillRefresh)) { _ in if !model.busy { refresh() } }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                RillMark(size: 31)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rill").font(.system(size: 19, weight: .semibold, design: .rounded))
                    Text("REDIS FOR MAC").font(.system(size: 8, weight: .medium)).tracking(1.5).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 25)
            List {
                if model.connected {
                    Section("工作空间") {
                        ForEach(WorkspaceTab.allCases) { tab in
                            Button { model.switchTab(tab) } label: {
                                Label(tab.title, systemImage: tab.symbol).font(.system(size: 13, weight: model.tab == tab ? .medium : .regular))
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                                    .foregroundStyle(model.tab == tab ? RillTheme.accent : Color.primary)
                            }.buttonStyle(.plain).listRowBackground(model.tab == tab ? RillTheme.accent.opacity(0.08) : Color.clear)
                        }
                    }
                }
                Section {
                    ForEach(model.profiles) { profile in
                        HStack(spacing: 6) {
                            Button { model.connect(profile) } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: "externaldrive").font(.system(size: 16)).foregroundStyle(profile.environment.color)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(profile.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                        Text(profile.host + ":" + String(profile.port)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                    if model.activeProfile?.id == profile.id && model.connected { Circle().fill(.green).frame(width: 6, height: 6).accessibilityLabel("已连接") }
                                }.padding(.vertical, 7).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(model.busy)
                            Menu {
                                Button("编辑连接", systemImage: "pencil") { model.editConnection(profile) }
                                if model.activeProfile?.id == profile.id { Button("断开连接", systemImage: "eject") { model.disconnect() } }
                                Divider()
                                Button("删除配置", systemImage: "trash", role: .destructive) { model.guardDraft { model.removeProfile(profile) } }
                            } label: { Image(systemName: "ellipsis").foregroundStyle(.secondary) }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(model.busy).accessibilityLabel("\(profile.name)连接选项")
                        }
                    }
                } header: {
                    HStack { Text("连接"); Spacer(); Text("\(model.profiles.count)").font(.caption2) }
                }
            }.listStyle(.sidebar).scrollContentBackground(.hidden)
            Spacer(minLength: 0)
            Divider().padding(.horizontal, 16)
            Button { model.editConnection(nil) } label: {
                Label("添加连接", systemImage: "plus.circle").font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading).padding(18)
            }.buttonStyle(.plain).disabled(model.busy)
            HStack { Text("本地优先 · 密码存于钥匙串"); Spacer(); Text("0.1") }.font(.system(size: 9)).foregroundStyle(.tertiary).padding(.horizontal, 18).padding(.bottom, 15)
        }.background(.ultraThinMaterial)
    }

    private var workspaceHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: model.tab.symbol).foregroundStyle(RillTheme.accent)
            Text(model.tab.title).font(.system(size: 15, weight: .semibold))
            if model.tab == .browser { Text(model.totalKeys.map { "\($0.formatted()) 个键" } ?? "键总数未知").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            if let profile = model.activeProfile {
                HStack(spacing: 6) {
                    Image(systemName: "cylinder.split.1x2").foregroundStyle(.secondary)
                    Picker("数据库", selection: Binding(get: { model.activeProfile?.database ?? 0 }, set: { model.changeDatabase($0) })) {
                        ForEach(Array(Set(Array(0..<16) + [profile.database])).sorted(), id: \.self) { Text("DB \($0)").tag($0) }
                    }.labelsHidden().frame(width: 86).disabled(model.busy)
                }
            }
        }.padding(.horizontal, 23).frame(height: 58)
    }

    private var browser: some View {
        HSplitView {
            VStack(spacing: 0) {
                VStack(spacing: 10) {
                    Picker("查找方式", selection: $model.searchMode) {
                        ForEach(KeySearchMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).disabled(!model.canSearch).accessibilityIdentifier("keySearchMode")
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField(model.searchMode == .pattern ? "Redis glob，如 user:*" : model.searchMode == .hex ? "原始字节，如 00 FF 3A" : "完整键名，按字面查找", text: $model.search).textFieldStyle(.plain).font(.system(size: 12))
                            .focused($searchFocused).onSubmit { model.loadKeys(reset: true, preserveSelection: false) }.disabled(!model.canSearch).accessibilityIdentifier("keySearch")
                        if !model.search.isEmpty { Button { model.search = ""; model.loadKeys(reset: true, preserveSelection: false) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain).disabled(!model.canSearch) }
                    }.padding(8).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
                    HStack {
                        Picker("数据类型", selection: $model.typeFilter) {
                            Text("所有类型").tag("")
                            ForEach(KeyKind.editable, id: \.self) { Text($0.title).tag($0.rawValue) }
                        }.labelsHidden().frame(maxWidth: 120).onChange(of: model.typeFilter) { _, _ in model.loadKeys(reset: true, preserveSelection: false) }.disabled(!model.canSearch)
                        Spacer(minLength: 1)
                        Button { model.favoritesOnly.toggle() } label: { Image(systemName: model.favoritesOnly ? "star.fill" : "star") }.help("仅显示已加载键中的收藏").foregroundStyle(model.favoritesOnly ? .orange : .secondary)
                        if !model.favoriteKeyBytes.isEmpty {
                            Menu {
                                ForEach(model.favoriteKeyBytes, id: \.self) { key in
                                    Button(DataPresentation.key(key)) { model.openFavorite(key) }
                                }
                            } label: { Image(systemName: "bookmark") }.menuIndicator(.hidden).help("直接打开当前数据库的收藏键").disabled(model.busy)
                        }
                        Button { model.grouped.toggle() } label: { Image(systemName: model.grouped ? "folder" : "list.bullet") }.help("切换前缀分组与列表")
                    }.buttonStyle(.borderless)
                }.padding(14)
                Divider()
                keyList
                Divider()
                HStack {
                    Text("已加载 \(model.keys.count)").font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    if model.isLoadingKeys {
                        ProgressView().controlSize(.small)
                        if model.isPatternSearch { Button("停止") { model.stopKeyScan() }.font(.system(size: 11)).keyboardShortcut(.cancelAction).help("停止续扫 · Esc") }
                    }
                    else if model.isStoppingScan { Text("等待本次响应…").font(.system(size: 10)).foregroundStyle(.secondary) }
                    else if !model.scanFinished { Button("加载更多") { model.loadKeys(reset: false) }.font(.system(size: 11)).disabled(model.busy) }
                    else if model.scanState == .capacity { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).help("达到 10 万键或 16 MiB 键名容量上限，请缩小搜索范围。") }
                    else { Image(systemName: "checkmark.circle").font(.caption).foregroundStyle(.secondary).help(model.isPatternSearch ? "本轮扫描完成，非一致性快照" : "精确查找已完成") }
                }.padding(.horizontal, 14).frame(height: 38)
            }.frame(minWidth: 260, idealWidth: 302, maxWidth: 340)
            KeyDetailView().frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var keyList: some View {
        Group {
            if model.visibleKeys.isEmpty && !model.isLoadingKeys {
                VStack(spacing: 12) {
                    Image(systemName: model.favoritesOnly ? "star" : "tray").font(.title2).foregroundStyle(.tertiary)
                    Text(model.favoritesOnly ? "已加载的键中暂无收藏" : "暂无匹配的键").font(.caption).foregroundStyle(.secondary)
                    if !model.scanFinished { Text(model.isStoppingScan ? "正在停止；等待本次响应" : "扫描尚未结束，可继续查找").font(.caption2).foregroundStyle(.secondary); Button("继续扫描") { model.loadKeys(reset: false) }.disabled(model.busy) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: Binding(get: { model.selectedKeyID }, set: { id in DispatchQueue.main.async { model.selectKey(id) } })) {
                    if model.grouped {
                        ForEach(keyGroups) { group in
                            DisclosureGroup(isExpanded: Binding(get: { !collapsedNamespaces.contains(group.id) }, set: { expanded in
                                if expanded { collapsedNamespaces.remove(group.id) } else { collapsedNamespaces.insert(group.id) }
                            })) {
                                ForEach(group.keys) { key in keyRow(key).tag(key.id) }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "folder").foregroundStyle(.secondary)
                                    Text(group.id).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                    Spacer()
                                    Text(String(group.keys.count)).font(.system(size: 10)).foregroundStyle(.tertiary)
                                }
                            }.padding(.vertical, 2)
                        }
                    } else { ForEach(model.visibleKeys) { key in keyRow(key).tag(key.id) } }
                }.listStyle(.inset).scrollContentBackground(.hidden).disabled(model.isWriting)
            }
        }
    }
    private struct KeyGroup: Identifiable { let id: String; let keys: [RedisKey] }
    private var keyGroups: [KeyGroup] {
        Dictionary(grouping: model.visibleKeys, by: \.namespace).map { KeyGroup(id: $0.key, keys: $0.value) }.sorted { $0.id < $1.id }
    }
    private func keyRow(_ key: RedisKey) -> some View {
        HStack(spacing: 8) {
            Image(systemName: key.kind.symbol).font(.system(size: 11)).foregroundStyle(key.kind.color).frame(width: 14)
            VStack(alignment: .leading, spacing: 4) {
                Text(key.name).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 7) {
                    Text(key.rawType ?? "类型未知").font(.system(size: 9)).foregroundStyle(.secondary).help(key.typeError?.localizedDescription ?? "数据类型")
                    if let ttl = key.ttl, ttl >= 0 { Label("有过期时间", systemImage: "clock").font(.system(size: 9)).foregroundStyle(.secondary) }
                    if key.ttl == nil { Text("TTL 未知").font(.system(size: 9)).foregroundStyle(.secondary).help(key.ttlError?.localizedDescription ?? "尚未读取") }
                }
            }
            Spacer(minLength: 0)
            if model.isFavorite(key) { Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(.orange) }
        }.padding(.vertical, 6).help(key.name).contextMenu {
            Button("复制键名", systemImage: "doc.on.doc") { copyText(key.name) }
            Button(model.isFavorite(key) ? "取消收藏" : "收藏键", systemImage: "star") { model.toggleFavorite(key) }
        }
    }

    private var welcome: some View {
        VStack(spacing: 0) {
            Spacer()
            RillMark(size: 76)
            Text("让 Redis 工作，轻松一点。").font(.system(size: 30, weight: .semibold)).padding(.top, 28)
            Text("一个专注、轻盈的 Mac 原生 Redis 客户端。\n从连接开始，让数据触手可及。").font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(6).padding(.top, 12)
            HStack(spacing: 12) {
                Button("添加连接") { model.editConnection(nil) }.buttonStyle(.borderedProminent).controlSize(.large)
                if let local = model.activeProfile ?? model.profiles.first { Button("连接 \(local.name)") { model.connect(local) }.controlSize(.large) }
            }.padding(.top, 28)
            HStack(spacing: 30) {
                welcomeFeature("lock.shield", "密码存于钥匙串")
                welcomeFeature("square.stack.3d.up", "六种数据类型")
                welcomeFeature("command", "为键盘而生")
            }.padding(.top, 60)
            Spacer()
            Text("Rill 0.1  /  为每一天的开发而造").font(.system(size: 10)).foregroundStyle(.tertiary).padding(.bottom, 25)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(25)
    }
    private func welcomeFeature(_ icon: String, _ text: String) -> some View {
        VStack(spacing: 10) { Image(systemName: icon).font(.system(size: 18, weight: .light)); Text(text).font(.system(size: 11)) }.foregroundStyle(.secondary)
    }
    private var statusBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 7) {
                Circle().fill(.green).frame(width: 5, height: 5)
                Text("已连接"); Text("·"); Text(verbatim: model.activeProfile.map { $0.host + ":" + String($0.port) } ?? "").fontDesign(.monospaced)
                if model.activeProfile?.tls == true { Image(systemName: "lock.shield"); Text("TLS") }
                Spacer()
                if model.busy { ProgressView().controlSize(.mini) }
                if let version = model.serverInfo["redis_version"] { Text("Redis \(version)"); Text("·") }
                Text(String(format: "握手 %.1f ms", model.latency))
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 18).frame(height: 29)
        }
    }
    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            Text(text).font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button { model.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("关闭错误提示")
        }.padding(13).background(Color.orange.opacity(0.08))
    }
    private func refresh() {
        switch model.tab {
        case .browser: model.loadKeys(reset: true)
        case .overview: model.loadDiagnostics()
        case .slowlog: model.loadSlowQueries()
        case .console: model.notify("使用 ⌘↩ 执行命令；切回数据浏览后可刷新键列表")
        }
    }
}

extension Notification.Name {
    static let rillFocusSearch = Notification.Name("rill.focusSearch")
    static let rillRefresh = Notification.Name("rill.refresh")
}
