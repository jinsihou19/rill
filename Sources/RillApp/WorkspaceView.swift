import SwiftUI
import RillCore

struct WorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var updater: AppUpdater
    @State private var visibility: NavigationSplitViewVisibility = .all
    @FocusState private var searchFocused: Bool
    @State private var selectedTreeItem: String?
    @State private var showSeparatorEditor = false
    @State private var separatorDraft = ":"
    private var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版" }

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
        .navigationTitle(model.activeProfile?.name ?? "rill")
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
            case .copy: MetadataEditor(mode: .copy)
            }
        }
        .sheet(item: $model.confirmation, onDismiss: model.confirmationDismissed) { request in ConfirmationView(request: request) }
        .onReceive(NotificationCenter.default.publisher(for: .rillFocusSearch)) { _ in model.switchTab(.browser); searchFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: .rillRefresh)) { _ in if !model.busy { refresh() } }
        .onChange(of: model.selectedKeyID) { _, _ in selectedTreeItem = nil }
        .onChange(of: model.activeProfile) { _, _ in selectedTreeItem = nil }
        .alert("命名空间分隔符", isPresented: $showSeparatorEditor) {
            TextField("例如 :、/ 或 ::", text: $separatorDraft)
            Button("应用") { model.setNamespaceSeparator(separatorDraft) }
            Button("取消", role: .cancel) {}
        } message: { Text("按字面字节分组；修改后会重置当前数据库的展开状态。") }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                RillMark(size: 31)
                VStack(alignment: .leading, spacing: 2) {
                    Text("rill").font(.system(size: 19, weight: .semibold, design: .rounded))
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
                                    .contentShape(Rectangle())
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
            if updater.waitingToInstall || updater.availableVersion != nil {
                Button {
                    if updater.waitingToInstall { updater.resumeInstallation() } else { updater.checkForUpdates() }
                } label: {
                    Label(updater.waitingToInstall ? "继续安装更新" : "更新到 \(updater.availableVersion ?? "")", systemImage: "arrow.down.circle")
                        .font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).padding(18)
                }.buttonStyle(.plain)
            }
            Button { model.editConnection(nil) } label: {
                Label("添加连接", systemImage: "plus.circle").font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading).padding(18)
            }.buttonStyle(.plain).disabled(model.busy)
            HStack { Text("本地优先 · 密码存于钥匙串"); Spacer(); Text(appVersion) }.font(.system(size: 9)).foregroundStyle(.tertiary).padding(.horizontal, 18).padding(.bottom, 15)
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
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField(model.searchMode.placeholder, text: Binding(get: { model.search }, set: { model.updateSearch($0) })).textFieldStyle(.plain).font(.system(size: 12))
                            .focused($searchFocused).onSubmit { model.loadKeys(reset: true, preserveSelection: false) }.disabled(!model.canSearch).accessibilityIdentifier("keySearch")
                        if !model.search.isEmpty { Button { model.updateSearch("") } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain).disabled(!model.canSearch).accessibilityLabel("清空搜索").help("清空搜索并恢复键列表") }
                        HStack(spacing: 2) {
                            ForEach([KeySearchMode.fuzzy, .pattern, .hex], id: \.self) { mode in
                                Button { model.changeSearchMode(mode) } label: {
                                    Group {
                                        switch mode {
                                        case .fuzzy: Text("≈")
                                        case .pattern: Text(".*")
                                        case .exact: Text("=")
                                        case .hex: Text("0x")
                                        }
                                    }.font(.system(size: 12, weight: .medium, design: .monospaced)).frame(width: 22, height: 22)
                                        .foregroundStyle(model.searchMode == mode ? RillTheme.accent : .secondary)
                                        .background(model.searchMode == mode ? RillTheme.accent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 4))
                                }.buttonStyle(.plain).disabled(!model.canSearch).help("\(mode.title)查找 · \(mode.placeholder)")
                                    .accessibilityLabel("\(mode.title)查找").accessibilityValue(model.searchMode == mode ? "已选中" : "未选中")
                                    .accessibilityAddTraits(model.searchMode == mode ? .isSelected : [])
                                    .accessibilityIdentifier("keySearchMode.\(mode.rawValue)")
                            }
                        }.fixedSize().accessibilityElement(children: .contain).accessibilityLabel("查找方式").accessibilityIdentifier("keySearchMode")
                    }.padding(.horizontal, 8).padding(.vertical, 5).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(searchFocused ? RillTheme.accent.opacity(0.7) : .clear, lineWidth: 1))
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
                        Menu {
                            Button("保存当前搜索") { model.saveSearch() }
                            if !model.savedSearches.isEmpty {
                                Divider()
                                ForEach(model.savedSearches) { value in
                                    Button(value.label) { model.restoreSearch(value) }
                                }
                                Menu("删除保存的搜索") {
                                    ForEach(model.savedSearches) { value in Button(value.label) { model.removeSearch(value.id) } }
                                }
                            }
                        } label: { Image(systemName: "text.badge.star") }.menuIndicator(.hidden).help("此连接与 DB 的保存搜索").disabled(!model.canSearch)
                        Button { model.grouped.toggle() } label: { Image(systemName: model.grouped ? "folder" : "list.bullet") }.help("切换前缀分组与列表")
                            .contextMenu { Button("设置命名空间分隔符…") { separatorDraft = model.namespaceSeparator; showSeparatorEditor = true } }
                        Menu {
                            Toggle("显示类型", isOn: $model.showKeyTypes)
                            Toggle("显示 TTL", isOn: $model.showKeyTTL)
                        } label: { Image(systemName: "line.3.horizontal.decrease") }.menuIndicator(.hidden).help("键列表显示列")
                    }.buttonStyle(.borderless)
                }.padding(14)
                    .onChange(of: model.grouped) { _, _ in model.saveBrowserPreferences(); model.rebuildNamespaces() }
                    .onChange(of: model.favoritesOnly) { _, _ in model.rebuildNamespaces() }
                    .onChange(of: model.showKeyTypes) { _, _ in model.requestVisibleMetadata(); model.saveBrowserPreferences() }
                    .onChange(of: model.showKeyTTL) { _, _ in model.requestVisibleMetadata(); model.saveBrowserPreferences() }
                Divider()
                keyList
                Divider()
                HStack {
                    Text("已加载 \(model.keys.count)").font(.system(size: 10)).foregroundStyle(.secondary)
                    if model.isBuildingNamespaces { ProgressView().controlSize(.mini).help("正在组织命名空间") }
                    if model.grouped, model.namespaceTree.isLimited { Image(systemName: "folder.badge.questionmark").foregroundStyle(.orange).help("分组达到容量或深度上限，部分键以完整后缀显示；未丢弃键。") }
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
                ScrollViewReader { proxy in
                List(selection: Binding(get: { selectedTreeItem ?? model.selectedKeyID }, set: { id in
                    DispatchQueue.main.async {
                        if let id, id.hasPrefix("folder:") { selectedTreeItem = id }
                        else { selectedTreeItem = nil; model.selectKey(id) }
                    }
                })) {
                    if model.grouped && !model.isBuildingNamespaces {
                        ForEach(model.namespaceTree.roots) { KeyNamespaceBranch(node: $0) }
                    } else { ForEach(model.visibleKeys) { key in KeyBrowserRow(key: key).tag(key.id) } }
                }.listStyle(.inset).scrollContentBackground(.hidden).disabled(model.isWriting)
                    .onChange(of: model.selectedKeyID) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
                    .onChange(of: model.isBuildingNamespaces) { _, building in if !building, let id = model.selectedKeyID { proxy.scrollTo(id, anchor: .center) } }
                }
            }
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
            Text("rill \(appVersion)  /  为每一天的开发而造").font(.system(size: 10)).foregroundStyle(.tertiary).padding(.bottom, 25)
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
                if model.isExportingKey {
                    Text(model.exportProgress.map { "导出 \($0.entries) 条 · \($0.fileBytes.formatted()) B" } ?? "准备导出…")
                    Button("停止导出") { model.stopKeyExport() }.buttonStyle(.borderless)
                }
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
