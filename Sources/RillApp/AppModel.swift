import SwiftUI
import AppKit
import RillCore

enum WorkspaceTab: String, CaseIterable, Identifiable {
    case browser, console, overview, slowlog
    var id: String { rawValue }
    var title: String {
        switch self { case .browser: return "数据浏览"; case .console: return "工作台"; case .overview: return "服务器"; case .slowlog: return "慢查询" }
    }
    var symbol: String {
        switch self { case .browser: return "square.stack.3d.up"; case .console: return "terminal"; case .overview: return "gauge.with.dots.needle.50percent"; case .slowlog: return "clock.badge.exclamationmark" }
    }
}

struct EditorSheet: Identifiable {
    enum Kind {
        case connection(ConnectionProfile, String), newKey, row(ValueRow?), ttl, rename
    }
    let id = UUID()
    let kind: Kind
}

struct ConfirmationRequest: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    var button = "确认"
    var requiredText = ""
    var destructive = false
    let action: () -> Void
}

struct ConsoleEntry: Identifiable {
    let id = UUID()
    let command: String
    let output: String
    let milliseconds: Double
    let failed: Bool
    let date = Date()
}

@MainActor
final class AppModel: ObservableObject {
    @Published var profiles: [ConnectionProfile] = []
    @Published var activeProfile: ConnectionProfile?
    @Published var tab: WorkspaceTab = .browser
    @Published var isConnecting = false
    @Published var isLoadingKeys = false
    @Published var isLoadingDetail = false
    @Published var isWriting = false
    @Published var isConsoleRunning = false
    @Published var keys: [RedisKey] = []
    @Published var selectedKeyID: String?
    @Published var detail: KeyPage?
    @Published var draft = ""
    @Published var valueFormat = "文本"
    @Published var search = ""
    @Published var typeFilter = ""
    @Published var grouped = true
    @Published var favoritesOnly = false
    @Published var cursor = "0"
    @Published var scanFinished = false
    @Published var totalKeys: Int64 = 0
    @Published var serverInfo: [String: String] = [:]
    @Published var slowQueries: [SlowQuery] = []
    @Published var consoleInput = ""
    @Published var consoleEntries: [ConsoleEntry] = []
    @Published var error: String?
    @Published var toast: String?
    @Published var sheet: EditorSheet?
    @Published var confirmation: ConfirmationRequest?
    @Published var favorites: Set<String> = []
    @Published var diagnosticsLoading = false
    @Published private var connectionLost = false
    private(set) var database: RedisDatabase?
    private let store = ProfileStore()
    private let keychain = KeychainStore()
    private var generation = UUID()
    private var detailGeneration = UUID()
    private var connectTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var demoID: UUID?
    private var historyIndex = 0
    private var afterEditor: (() -> Void)?
    private var afterConfirmation: (() -> Void)?

    var connected: Bool { database != nil && !connectionLost }
    var busy: Bool { isConnecting || isLoadingKeys || isLoadingDetail || isWriting || isConsoleRunning || diagnosticsLoading }
    var canWrite: Bool { connected && activeProfile?.readOnly == false && !busy }
    var latency: Double { database?.latency ?? 0 }
    var dirty: Bool {
        guard let detail, let content = detail.content, !detail.isTruncated,
              let original = String(data: content, encoding: .utf8), !content.contains(0) else { return false }
        return draft != original
    }
    var visibleKeys: [RedisKey] { favoritesOnly ? keys.filter { favorites.contains(favoriteID($0.id)) } : keys }
    var currentKey: RedisKey? { detail?.key }

    init() {
        do { profiles = try store.load() } catch { self.error = "读取连接配置失败：\(error.localizedDescription)" }
        favorites = Set(UserDefaults.standard.stringArray(forKey: "favoriteKeys") ?? [])
        if let portText = ProcessInfo.processInfo.environment["RILL_DEMO_PORT"], let port = Int(portText) {
            let profile = ConnectionProfile(name: "Rill 演示", port: port, environment: .local)
            demoID = profile.id; profiles.append(profile)
            Task { connect(profile) }
        }
    }

    func notify(_ text: String) {
        toastTask?.cancel(); toast = text
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { toast = nil }
        }
    }
    func presentError(_ failure: Error) { error = failure.localizedDescription }
    func guardDraft(_ action: @escaping () -> Void) {
        if dirty {
            confirmation = ConfirmationRequest(title: "放弃未保存的修改？", message: "当前值有未保存的修改。离开后这些修改会丢失。", button: "放弃修改", destructive: true) { [weak self] in
                self?.draft = self?.detail?.content.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                action()
            }
        } else { action() }
    }
    func finishEditor(_ action: @escaping () -> Void) { afterEditor = action; sheet = nil }
    func editorDismissed() { let action = afterEditor; afterEditor = nil; action?() }
    func finishConfirmation(_ action: @escaping () -> Void) { afterConfirmation = action; confirmation = nil }
    func confirmationDismissed() { let action = afterConfirmation; afterConfirmation = nil; action?() }

    func connect(_ profile: ConnectionProfile) {
        guardDraft { [weak self] in self?.startConnection(profile) }
    }
    private func startConnection(_ profile: ConnectionProfile) {
        reset(); activeProfile = profile; isConnecting = true; error = nil
        let token = generation
        connectTask = Task { [self] in
            do {
                let secret = profile.id == demoID ? "" : try keychain.password(for: profile.id)
                let db = try await RedisDatabase.connect(profile, password: secret)
                guard generation == token, !Task.isCancelled else { db.close(); return }
                database = db; serverInfo = db.server; isConnecting = false
                db.wire.onDisconnect { [weak self] reason in
                    Task { @MainActor in
                        guard let self, self.generation == token else { return }
                        self.connectionLost = true; self.error = reason
                    }
                }
                loadKeys(reset: true)
                if tab == .overview { loadDiagnostics() }
                if tab == .slowlog { loadSlowQueries() }
            } catch {
                guard generation == token else { return }
                isConnecting = false; presentError(error)
            }
        }
    }
    func disconnect() { guardDraft { [weak self] in self?.reset(); self?.activeProfile = nil } }
    private func reset() {
        generation = UUID(); detailGeneration = UUID()
        connectTask?.cancel(); scanTask?.cancel(); detailTask?.cancel(); database?.close(); database = nil
        keys = []; selectedKeyID = nil; detail = nil; draft = ""; cursor = "0"; scanFinished = false; totalKeys = 0
        serverInfo = [:]; slowQueries = []; consoleEntries = []; consoleInput = ""
        connectionLost = false
        isConnecting = false; isLoadingKeys = false; isLoadingDetail = false; isWriting = false; diagnosticsLoading = false; isConsoleRunning = false
    }
    func changeDatabase(_ number: Int) {
        guard var profile = activeProfile, number != profile.database, !busy else { return }
        profile.database = number; connect(profile)
    }
    func switchTab(_ new: WorkspaceTab) {
        tab = new
        if new == .overview { loadDiagnostics() }
        if new == .slowlog { loadSlowQueries() }
    }

    func loadKeys(reset: Bool, preserveSelection: Bool = true, focusKey: Data? = nil) {
        guard let db = database, !isLoadingKeys, !isWriting else { return }
        if reset && dirty { guardDraft { [weak self] in self?.loadKeys(reset: true, preserveSelection: preserveSelection, focusKey: focusKey) }; return }
        if !reset && scanFinished { return }
        let previousKey = focusKey ?? (preserveSelection ? detail?.key.bytes ?? keys.first(where: { $0.id == selectedKeyID })?.bytes : nil)
        if reset && !preserveSelection { detailGeneration = UUID(); selectedKeyID = nil; detail = nil; draft = "" }
        if reset { keys = []; cursor = "0"; scanFinished = false }
        let token = generation, pattern = search.isEmpty ? "*" : search, kind = typeFilter
        isLoadingKeys = true; error = nil
        scanTask = Task {
            do {
                var next = cursor, additions: [RedisKey] = [], attempts = 0
                repeat {
                    let page = try await db.scan(cursor: next, pattern: pattern, kind: kind)
                    next = page.cursor; additions.append(contentsOf: page.keys); attempts += 1
                } while next != "0" && additions.isEmpty && attempts < 8 && !Task.isCancelled
                let count = try await db.size()
                let selectedPage: KeyPage?
                if reset, let previousKey { selectedPage = try? await db.inspect(previousKey) }
                else { selectedPage = nil }
                guard token == generation, !Task.isCancelled else { return }
                var merged = Dictionary(keys.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
                for key in additions { merged[key.id] = key }
                if let selectedPage { merged[selectedPage.key.id] = selectedPage.key }
                keys = merged.values.sorted { $0.bytes.lexicographicallyPrecedes($1.bytes) }
                cursor = next; scanFinished = next == "0"; totalKeys = count; isLoadingKeys = false
                if reset {
                    if let selectedPage {
                        detail = selectedPage; selectedKeyID = selectedPage.key.id
                        draft = selectedPage.content.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    }
                    else { selectedKeyID = nil; detail = nil; draft = "" }
                }
            } catch {
                guard token == generation else { return }
                isLoadingKeys = false; presentError(error)
            }
        }
    }
    func selectKey(_ id: String?, force: Bool = false) {
        guard force || id != selectedKeyID else { return }
        let action: () -> Void = { [weak self] in self?.startDetail(id) }
        if force { startDetail(id) } else { guardDraft(action) }
    }
    private func startDetail(_ id: String?) {
        guard let id, let key = keys.first(where: { $0.id == id }), let db = database else {
            selectedKeyID = nil; detail = nil; draft = ""; return
        }
        // The serialized transport finishes an old read before starting the next one; results are generation checked.
        detailGeneration = UUID(); let detailToken = detailGeneration, token = generation
        let changingKey = selectedKeyID != id
        selectedKeyID = id; detail = nil; draft = ""; isLoadingDetail = true
        if changingKey { valueFormat = "文本" }
        detailTask = Task {
            do {
                let page = try await db.inspect(key.bytes)
                guard token == generation, detailToken == detailGeneration else { return }
                detail = page; draft = page.content.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                if let data = page.content {
                    if data.contains(0) || String(data: data, encoding: .utf8) == nil { valueFormat = "Hex" }
                    else if changingKey, (draft.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") || draft.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[")),
                            (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil { valueFormat = "JSON" }
                }
                isLoadingDetail = false
            } catch {
                guard token == generation, detailToken == detailGeneration else { return }
                isLoadingDetail = false; presentError(error)
            }
        }
    }
    func loadMoreRows() {
        guard let db = database, let previous = detail, previous.hasMore, !busy else { return }
        let token = generation, selected = selectedKeyID
        isLoadingDetail = true
        Task {
            do {
                var page = try await db.inspect(previous.key.bytes, cursor: previous.cursor, offset: previous.nextOffset)
                guard token == generation, selected == selectedKeyID else { return }
                var seen = Set<String>(); page.rows = (previous.rows + page.rows).filter { seen.insert($0.id).inserted }
                detail = page; isLoadingDetail = false
            } catch { if token == generation { isLoadingDetail = false; presentError(error) } }
        }
    }

    func mutate(_ title: String, message: String = "", destructive: Bool = false, focusKey: Data? = nil, work: @escaping (RedisDatabase) async throws -> Void) {
        guard let db = database, !busy, activeProfile?.readOnly == false else { return }
        if dirty && title != "保存值" {
            guardDraft { [weak self] in self?.mutate(title, message: message, destructive: destructive, focusKey: focusKey, work: work) }
            return
        }
        let token = generation
        let execute = { [weak self] in
            guard let self, self.generation == token, self.database === db else { return }
            self.isWriting = true; self.error = nil
            Task {
                do {
                    try await work(db)
                    guard self.generation == token else { return }
                    self.isWriting = false; self.notify(title + "完成")
                    // Mark the old snapshot clean only after the write has succeeded.
                    if let page = self.detail, let content = page.content { self.draft = String(data: content, encoding: .utf8) ?? "" }
                    if focusKey != nil { self.tab = .browser }
                    self.loadKeys(reset: true, focusKey: focusKey)
                } catch {
                    guard self.generation == token else { return }
                    self.isWriting = false; self.presentError(error)
                }
            }
        }
        if activeProfile?.environment == .production || destructive {
            confirmation = ConfirmationRequest(title: title + "？", message: message.isEmpty ? "此操作将修改当前数据库中的数据。" : message,
                                               button: title, requiredText: activeProfile?.environment == .production ? activeProfile?.name ?? "" : "",
                                               destructive: destructive, action: execute)
        } else { execute() }
    }
    func saveString() {
        guard let page = detail, let original = page.content, !page.isTruncated, dirty else { return }
        let text = draft
        if valueFormat == "JSON" {
            do { _ = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) }
            catch { self.error = "JSON 格式无效：\(error.localizedDescription)"; return }
        }
        mutate("保存值") { try await $0.saveString(key: page.key.bytes, expected: original, replacement: Data(text.utf8)) }
    }
    func formatJSON() {
        do {
            let object = try JSONSerialization.jsonObject(with: Data(draft.utf8), options: [.fragmentsAllowed])
            let output = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
            draft = String(decoding: output, as: UTF8.self); valueFormat = "JSON"; notify("JSON 已格式化，保存后生效")
        } catch { self.error = "JSON 格式无效：\(error.localizedDescription)" }
    }
    func deleteCurrentKey() {
        guard let key = detail?.key else { return }
        mutate("删除键", message: "将使用 UNLINK 删除「\(key.name)」。此操作无法撤销。", destructive: true) { try await $0.deleteKey(key.bytes) }
    }

    func editConnection(_ profile: ConnectionProfile?) {
        do {
            let profile = profile ?? ConnectionProfile(name: "新连接", environment: .development)
            let password = profile.id == demoID ? "" : try keychain.password(for: profile.id)
            sheet = EditorSheet(kind: .connection(profile, password))
        } catch { presentError(error) }
    }
    func saveProfile(_ profile: ConnectionProfile, password: String, connectAfter: Bool) {
        do {
            try profile.validate()
            var updated = profiles.filter { $0.id != demoID }
            if let i = updated.firstIndex(where: { $0.id == profile.id }) { updated[i] = profile } else { updated.append(profile) }
            let old = try keychain.password(for: profile.id)
            try keychain.set(password, for: profile.id)
            do { try store.save(updated) } catch { try? keychain.set(old, for: profile.id); throw error }
            profiles = updated + profiles.filter { $0.id == demoID && $0.id != profile.id }
            finishEditor { [weak self] in
                guard let self else { return }
                if connectAfter || self.activeProfile?.id == profile.id { self.connect(profile) }
                else { self.notify("连接已保存") }
            }
        } catch { presentError(error) }
    }
    func removeProfile(_ profile: ConnectionProfile) {
        confirmation = ConfirmationRequest(title: "删除连接配置？", message: "删除「\(profile.name)」及钥匙串中的密码。Redis 数据不受影响。", button: "删除配置", destructive: true) { [weak self] in
            guard let self else { return }
            do {
                let updated = self.profiles.filter { $0.id != profile.id }
                try self.store.save(updated.filter { $0.id != self.demoID })
                do { try self.keychain.remove(profile.id) }
                catch { try? self.store.save(self.profiles.filter { $0.id != self.demoID }); throw error }
                self.profiles = updated
                if self.activeProfile?.id == profile.id { self.reset(); self.activeProfile = nil }
            } catch { self.presentError(error) }
        }
    }
    private func favoriteID(_ keyID: String) -> String {
        "\(activeProfile?.id.uuidString ?? "")/\(activeProfile?.database ?? 0)/\(keyID)"
    }
    func isFavorite(_ key: RedisKey) -> Bool { favorites.contains(favoriteID(key.id)) }
    func toggleFavorite(_ key: RedisKey) {
        let id = favoriteID(key.id)
        if favorites.contains(id) { favorites.remove(id) } else { favorites.insert(id) }
        UserDefaults.standard.set(Array(favorites), forKey: "favoriteKeys")
    }

    func runConsole() {
        guard let profile = activeProfile, connected, !busy else { return }
        let command = consoleInput
        do {
            let arguments = try CommandLine.parse(command)
            try CommandPolicy.validate(arguments, readOnly: profile.readOnly)
            let execute: () -> Void = { [weak self] in self?.executeConsole(command, arguments: arguments, profile: profile) }
            if profile.environment == .production && !CommandPolicy.isRead(arguments) {
                confirmation = ConfirmationRequest(title: "在生产环境执行命令？", message: command, button: "执行命令", requiredText: profile.name, action: execute)
            } else { execute() }
        } catch { presentError(error) }
    }
    private func executeConsole(_ command: String, arguments: [String], profile: ConnectionProfile) {
        let token = generation; isConsoleRunning = true; consoleInput = ""; error = nil
        Task {
            let start = Date()
            do {
                let secret = profile.id == demoID ? "" : try keychain.password(for: profile.id)
                let console = try await RedisDatabase.connect(profile, password: secret)
                defer { console.close() }
                let response = try await console.wire.execute(arguments)
                guard generation == token else { return }
                consoleEntries.append(ConsoleEntry(command: command, output: String(response.pretty.prefix(100_000)) + (response.pretty.count > 100_000 ? "\n…显示已截断" : ""), milliseconds: Date().timeIntervalSince(start) * 1000, failed: false))
                if !CommandPolicy.isRead(arguments) { notify("命令已执行；切回数据浏览后按 ⌘R 刷新") }
            } catch {
                guard generation == token else { return }
                consoleEntries.append(ConsoleEntry(command: command, output: error.localizedDescription, milliseconds: Date().timeIntervalSince(start) * 1000, failed: true))
            }
            if consoleEntries.count > 100 { consoleEntries.removeFirst(consoleEntries.count - 100) }
            historyIndex = consoleEntries.count; isConsoleRunning = false
        }
    }
    func navigateHistory(_ delta: Int) {
        guard !consoleEntries.isEmpty else { return }
        historyIndex = min(max(0, historyIndex + delta), consoleEntries.count)
        consoleInput = historyIndex < consoleEntries.count ? consoleEntries[historyIndex].command : ""
    }
    func loadDiagnostics() {
        guard let db = database, !diagnosticsLoading else { return }
        let token = generation; diagnosticsLoading = true
        Task {
            do { let info = try await db.info(); if token == generation { serverInfo = info; diagnosticsLoading = false } }
            catch { if token == generation { diagnosticsLoading = false; presentError(error) } }
        }
    }
    func loadSlowQueries() {
        guard let db = database, !diagnosticsLoading else { return }
        let token = generation; diagnosticsLoading = true
        Task {
            do { let result = try await db.slowQueries(); if token == generation { slowQueries = result; diagnosticsLoading = false } }
            catch { if token == generation { diagnosticsLoading = false; presentError(error) } }
        }
    }
    func exportCurrentPage() {
        guard let page = detail else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "redis-value." + (page.content == nil ? "json" : "txt")
        panel.title = page.isTruncated ? "导出预览（前 1 MiB）" : "导出当前已加载数据"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data: Data
            if let content = page.content { data = content }
            else {
                let rows: [[String: Any]] = page.rows.map { row in
                    var result: [String: Any] = ["field": row.field.base64EncodedString(), "value": row.value.base64EncodedString(), "score": row.score ?? ""]
                    if let fields = row.streamFields {
                        result.removeValue(forKey: "value")
                        result["fields"] = stride(from: 0, to: max(0, fields.count - 1), by: 2).map { ["field": fields[$0].base64EncodedString(), "value": fields[$0 + 1].base64EncodedString()] }
                    }
                    return result
                }
                let object: [String: Any] = ["encoding": "base64", "type": page.key.kind.rawValue, "key": page.key.bytes.base64EncodedString(), "loaded": rows.count, "total": page.count, "rows": rows]
                data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            }
            try data.write(to: url, options: .atomic); notify("当前已加载数据已导出")
        } catch { presentError(error) }
    }
}
