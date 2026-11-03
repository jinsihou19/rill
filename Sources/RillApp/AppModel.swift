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
        case connection(ConnectionProfile, String), newKey, row(ValueRow?), ttl, rename, copy
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
    var preparationMilliseconds: Double? = nil
    var reusedConnection = false
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
    @Published var isStoppingScan = false
    @Published var scanState: ScanStopReason = .budget
    @Published var isLoadingDetail = false
    @Published var isWriting = false
    @Published var memberPattern = ""
    @Published var streamNewestFirst = true
    @Published var streamStart = "-"
    @Published var streamEnd = "+"
    @Published var isStoppingMembers = false
    @Published private(set) var memberQuery = MemberQuery()
    private var memberSession: MemberReadSession?
    @Published var isConsoleRunning = false
    @Published var isExportingKey = false
    @Published var exportProgress: KeyExportProgress?
    private var exportTask: Task<Void, Never>?
    private var exportDatabase: RedisDatabase?
    private var exportRevision = UUID()
    @Published var keys: [RedisKey] = []
    @Published var selectedKeyID: String?
    @Published var detail: KeyPage?
    @Published var draft = ""
    @Published var valueFormat = "文本"
    @Published private(set) var valueCodec: ValueCodec = .raw
    @Published private(set) var decodedValue: DecodedValue?
    @Published private(set) var valueDecodeError: String?
    @Published private(set) var isPreparingValue = false
    @Published private(set) var valueHex = ""
    @Published private(set) var valueChange: ValueChangeSummary?
    @Published private(set) var valueEncodeError: String?
    private var cleanDraft = ""
    private var valueGeneration = UUID()
    private var valueWorker: Task<DecodedValue, Error>?
    private var valuePresentation: Task<Void, Never>?
    @Published var search = ""
    @Published var searchMode: KeySearchMode = .fuzzy
    @Published var typeFilter = ""
    @Published var grouped = true
    @Published var namespaceSeparator = ":"
    @Published var namespaceExpansion: [String: Bool] = [:]
    @Published var namespaceTree = KeyNamespaceTree.build([])
    @Published var isBuildingNamespaces = false
    @Published var showKeyTypes = true
    @Published var showKeyTTL = true
    @Published var favoritesOnly = false
    @Published var scanFinished = false
    @Published var totalKeys: Int64?
    @Published var capabilityStates: [RedisCapability] = []
    @Published var serverInfo: [String: String] = [:]
    @Published var slowQueries: [SlowQuery] = []
    @Published var slowlogReport: SlowlogReport?
    @Published var trend = InfoTrend()
    @Published var isSamplingTrend = false
    @Published var memoryAnalysis: MemoryAnalysisReport?
    @Published var isAnalyzingMemory = false
    private var trendTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var trendDatabase: RedisDatabase?
    private var analysisDatabase: RedisDatabase?
    private var trendRevision = UUID()
    private var analysisRevision = UUID()
    @Published var savedSearches: [SavedKeySearch] = []
    @Published var consoleHistory = CommandHistory()
    private var histories: [String: CommandHistory] = [:]
    private var historyDraft = ""
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
    private let store: ProfileStore
    private let keychain = KeychainStore()
    private let browserPreferences: BrowserPreferencesStore
    private var generation = UUID()
    private var detailGeneration = UUID()
    private var keyGeneration = UUID()
    private var scanSession: KeyScanSession?
    private var scanQuery = (mode: KeySearchMode.fuzzy, text: "", kind: "")
    private var keyIndex: [String: Int] = [:]
    private var namespaceBuild: Task<KeyNamespaceTree, Never>?
    private var namespaceGeneration = UUID()
    private var visibleKeyObservers: [UUID: String] = [:]
    private var visibleKeyIDs: Set<String> { Set(visibleKeyObservers.values) }
    private var metadataDebounce: Task<Void, Never>?
    private let consoleSession = ConsoleSession()
    private var consoleResetTask: Task<Void, Never>?
    private var isReadingMetadata = false
    private var connectTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var demoID: UUID?
    private var historyIndex = 0
    private var afterEditor: (() -> Void)?
    private var afterConfirmation: (() -> Void)?

    var connected: Bool { database != nil && !connectionLost }
    var busy: Bool { isConnecting || isLoadingKeys || isStoppingScan || isLoadingDetail || isWriting || isConsoleRunning || diagnosticsLoading || isPreparingValue || isExportingKey }
    var canSearch: Bool { connected && !isConnecting && !isWriting && !isConsoleRunning }
    var isPatternSearch: Bool { scanQuery.mode.scanPattern(scanQuery.text) != nil }
    var keyListRevision: UUID { keyGeneration }
    var canWrite: Bool { connected && activeProfile?.readOnly == false && !busy }
    var latency: Double { database?.latency ?? 0 }
    var textValueEditable: Bool { decodedValue?.text != nil && detail?.isTruncated == false && !isPreparingValue }
    var dirty: Bool { decodedValue?.text != nil && detail?.isTruncated == false && draft != cleanDraft }
    var visibleKeys: [RedisKey] { favoritesOnly ? keys.filter { favorites.contains(favoriteID($0.id)) } : keys }
    var currentKey: RedisKey? { detail?.key }
    var updateRestartBlocker: String? {
        if isWriting || isConsoleRunning || isExportingKey { return "操作正在进行，请结束后再继续安装更新。" }
        if dirty { return "当前键有未保存的修改，请保存或还原后再继续安装更新。" }
        if sheet != nil || confirmation != nil { return "请先完成或取消当前编辑，再继续安装更新。" }
        return nil
    }

    init(store: ProfileStore = ProfileStore(), browserPreferences: BrowserPreferencesStore = BrowserPreferencesStore()) {
        self.store = store; self.browserPreferences = browserPreferences
        do { profiles = try store.load() } catch { self.error = "读取连接配置失败：\(error.localizedDescription)" }
        favorites = Set(UserDefaults.standard.stringArray(forKey: "favoriteKeys") ?? [])
        if let portText = ProcessInfo.processInfo.environment["RILL_DEMO_PORT"], let port = Int(portText) {
            let profile = ConnectionProfile(name: "rill 演示", port: port, environment: .local)
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
                self?.restoreValueDraft()
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
        let preferences = browserPreferences.load(profile)
        searchMode = preferences.searchMode; search = preferences.search; typeFilter = preferences.kind
        valueCodec = preferences.codec; valueFormat = preferences.format
        showKeyTypes = preferences.showTypes; showKeyTTL = preferences.showTTL; savedSearches = preferences.searches
        consoleHistory = histories[workspaceID(profile)] ?? CommandHistory(); historyIndex = consoleHistory.commands.count
        namespaceSeparator = preferences.separator; grouped = preferences.grouped; namespaceExpansion = preferences.expansion
        let token = generation
        connectTask = Task { [self] in
            do {
                let secret = profile.id == demoID ? "" : try keychain.password(for: profile.id)
                let db = try await RedisDatabase.connect(profile, password: secret)
                let states = await db.capabilities.snapshot()
                guard generation == token, !Task.isCancelled else { db.close(); return }
                database = db; serverInfo = db.server; capabilityStates = states; isConnecting = false
                db.wire.onDisconnect { [weak self] reason in
                    Task { @MainActor in
                        guard let self, self.generation == token else { return }
                        self.connectionLost = true; self.error = self.error ?? reason
                    }
                }
                loadKeys(reset: true, focusKey: preferences.selectedKey)
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
        stopDiagnostics(); stopKeyExport(); trend = InfoTrend(); memoryAnalysis = nil; slowlogReport = nil
        generation = UUID(); detailGeneration = UUID(); keyGeneration = UUID(); scanSession = nil; memberSession = nil; isStoppingMembers = false
        memberQuery = MemberQuery(); memberPattern = ""; streamNewestFirst = true; streamStart = "-"; streamEnd = "+"
        namespaceBuild?.cancel(); namespaceGeneration = UUID(); namespaceTree = KeyNamespaceTree.build([]); isBuildingNamespaces = false
        let previousReset = consoleResetTask, session = consoleSession
        consoleResetTask = Task { await previousReset?.value; await session.close() }
        metadataDebounce?.cancel(); visibleKeyObservers = [:]; keyIndex = [:]; isReadingMetadata = false
        connectTask?.cancel(); scanTask?.cancel(); detailTask?.cancel(); database?.close(); database = nil
        clearValue(); keys = []; selectedKeyID = nil; detail = nil; draft = ""; scanFinished = false; totalKeys = nil; capabilityStates = []
        serverInfo = [:]; slowQueries = []; consoleEntries = []; consoleInput = ""
        connectionLost = false
        isConnecting = false; isLoadingKeys = false; isStoppingScan = false; isLoadingDetail = false; isWriting = false; diagnosticsLoading = false; isConsoleRunning = false
    }
    func changeDatabase(_ number: Int) {
        guard var profile = activeProfile, number != profile.database, !busy else { return }
        profile.database = number; connect(profile)
    }
    func switchTab(_ new: WorkspaceTab) {
        if new != .overview { stopDiagnostics() }
        tab = new
        if new == .overview { loadDiagnostics() }
        if new == .slowlog { loadSlowQueries() }
    }

    func updateSearch(_ text: String) {
        guard text != search else { return }
        search = text
        if text.isEmpty { loadKeys(reset: true, preserveSelection: false) }
    }
    func changeSearchMode(_ mode: KeySearchMode) {
        guard mode != searchMode else { return }
        guardDraft { [weak self] in
            guard let self else { return }
            self.searchMode = mode; self.loadKeys(reset: true, preserveSelection: false)
        }
    }
    func loadKeys(reset: Bool, preserveSelection: Bool = true, focusKey: Data? = nil) {
        guard let db = database, canSearch else { return }
        if reset && dirty { guardDraft { [weak self] in self?.loadKeys(reset: true, preserveSelection: preserveSelection, focusKey: focusKey) }; return }
        if !reset && (scanFinished || isLoadingKeys || isStoppingScan) { return }
        let previousKey = focusKey ?? (preserveSelection ? detail?.key.bytes ?? keys.first(where: { $0.id == selectedKeyID })?.bytes : nil)
        if reset && !preserveSelection {
            detailGeneration = UUID()
            if let previous = memberSession { Task { await previous.pause() } }
            memberSession = nil; isLoadingDetail = false; isStoppingMembers = false
            selectedKeyID = nil; detail = nil; clearValue()
        }
        if reset {
            if let old = scanSession { Task { await old.pause() } }
            keyGeneration = UUID(); keys = []; scanFinished = false; scanState = .budget
            namespaceBuild?.cancel(); namespaceGeneration = UUID(); namespaceTree = KeyNamespaceTree.build([]); isBuildingNamespaces = false
            metadataDebounce?.cancel(); visibleKeyObservers = [:]; keyIndex = [:]; isReadingMetadata = false
            scanSession = KeyScanSession()
            scanQuery = (searchMode, search, typeFilter)
        }
        let token = generation, pattern = scanQuery.mode.scanPattern(scanQuery.text), kind = scanQuery.kind
        let mode = scanQuery.mode, query = scanQuery.text, keyToken = keyGeneration, selectionRevision = detailGeneration, selectedQuery = memberQuery
        let session = scanSession ?? KeyScanSession(); scanSession = session
        isLoadingKeys = true; isStoppingScan = false; error = nil
        scanTask = Task {
            do {
                var additions: [RedisKey] = [], reason: ScanStopReason = .complete
                if let pattern {
                    let batch = try await session.nextPage(fetchWithinBudget: { cursor, remaining in
                        try await db.scan(cursor: cursor, pattern: pattern, kind: kind, maximumRequests: remaining, includeMetadata: false)
                    })
                    additions = batch.keys; reason = batch.reason
                } else if let exact = try mode.exactKey(query) {
                    if let key = try await db.lookup(exact, kind: kind) { additions = [key] }
                }
                guard token == generation, keyToken == keyGeneration else { return }
                let count = reset ? (try? await db.size()) : nil
                let selectedPage: KeyPage?
                let selectedMembers = MemberReadSession()
                if reset, reason != .paused, let previousKey, pattern != nil || additions.contains(where: { $0.bytes == previousKey }) {
                    selectedPage = try? await selectedMembers.next { cursor, offset in try await db.inspect(previousKey, cursor: cursor, offset: offset, query: selectedQuery) }
                } else { selectedPage = nil }
                let observedCapabilities = await db.capabilities.snapshot()
                guard token == generation, keyToken == keyGeneration, !Task.isCancelled else { return }
                capabilityStates = observedCapabilities
                var merged = Dictionary(keys.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
                for key in additions { merged[key.id] = key }
                if let selectedPage { merged[selectedPage.key.id] = selectedPage.key }
                keys = merged.values.sorted { $0.bytes.lexicographicallyPrecedes($1.bytes) }
                keyIndex = Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($0.element.id, $0.offset) })
                rebuildNamespaces()
                scanState = reason; scanFinished = reason == .complete || reason == .capacity
                if reset { totalKeys = count }
                isLoadingKeys = false; isStoppingScan = false
                if pattern == nil, reset, !preserveSelection, let key = additions.first { startDetail(key.id); return }
                if reset, selectionRevision == detailGeneration {
                    if let selectedPage {
                        detail = selectedPage; memberSession = selectedMembers; selectedKeyID = selectedPage.key.id
                        prepareValue(selectedPage)
                    }
                    else { selectedKeyID = nil; detail = nil; clearValue() }
                }
                saveBrowserPreferences()
            } catch {
                guard token == generation, keyToken == keyGeneration else { return }
                isLoadingKeys = false; isStoppingScan = false; presentError(error)
            }
        }
    }
    func stopKeyScan() {
        guard isLoadingKeys, isPatternSearch, let session = scanSession else { return }
        isLoadingKeys = false; isStoppingScan = true
        Task { await session.pause() }
    }
    func keyAppeared(_ id: String, revision: UUID, observer: UUID) {
        guard revision == keyGeneration else { return }
        visibleKeyObservers[observer] = id; requestVisibleMetadata()
    }
    func keyDisappeared(_ id: String, revision: UUID, observer: UUID) {
        if revision == keyGeneration, visibleKeyObservers[observer] == id { visibleKeyObservers.removeValue(forKey: observer) }
    }
    func requestVisibleMetadata() {
        metadataDebounce?.cancel()
        metadataDebounce = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 60_000_000) } catch { return }
            self?.loadVisibleMetadata()
        }
    }
    private func loadVisibleMetadata() {
        guard connected, let db = database, !isReadingMetadata, showKeyTypes || showKeyTTL else { return }
        let batch = Array(visibleKeyIDs.sorted().compactMap { id -> RedisKey? in
            guard let index = keyIndex[id] else { return nil }
            let row = keys[index]
            let needsType = showKeyTypes && row.rawType == nil && row.typeError == nil
            let needsTTL = showKeyTTL && row.ttl == nil && row.ttlError == nil
            return needsType || needsTTL ? row : nil
        }.prefix(64))
        guard !batch.isEmpty else { return }
        let token = generation, revision = keyGeneration
        let includeType = showKeyTypes && batch.contains { $0.rawType == nil && $0.typeError == nil }
        let includeTTL = showKeyTTL && batch.contains { $0.ttl == nil && $0.ttlError == nil }
        let knownKind = scanQuery.kind.isEmpty ? nil : scanQuery.kind
        isReadingMetadata = true
        Task {
            do {
                let rows = try await db.metadata(for: batch.map(\.bytes), knownKind: knownKind, includeTTL: includeTTL, includeType: includeType)
                let states = await db.capabilities.snapshot()
                guard token == generation, revision == keyGeneration else { return }
                let received = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
                var updated = keys, missing: Set<String> = []
                for original in batch {
                    guard let index = keyIndex[original.id] else { continue }
                    guard let row = received[original.id] else {
                        if selectedKeyID != original.id || !dirty { missing.insert(original.id) }
                        else { updated[index] = RedisKey(bytes: original.bytes, kind: original.kind, ttl: -2, rawType: original.rawType, typeError: .message("此键已不存在，未保存的草稿已保留。")) }
                        continue
                    }
                    updated[index] = RedisKey(bytes: row.bytes, kind: row.rawType == nil ? original.kind : row.kind,
                                              ttl: includeTTL ? row.ttl : original.ttl, rawType: row.rawType ?? original.rawType,
                                              typeError: includeType ? row.typeError : original.typeError, ttlError: includeTTL ? row.ttlError : original.ttlError,
                                              memory: original.memory, memoryError: original.memoryError)
                }
                if !missing.isEmpty { updated.removeAll { missing.contains($0.id) }; visibleKeyObservers = visibleKeyObservers.filter { !missing.contains($0.value) } }
                keys = updated; keyIndex = Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($0.element.id, $0.offset) })
                if !missing.isEmpty { rebuildNamespaces() }
                capabilityStates = states; isReadingMetadata = false; requestVisibleMetadata()
            } catch {
                guard token == generation, revision == keyGeneration else { return }
                isReadingMetadata = false; presentError(error)
            }
        }
    }
    func key(id: String) -> RedisKey? { keyIndex[id].map { keys[$0] } }
    func rebuildNamespaces() {
        namespaceBuild?.cancel(); namespaceGeneration = UUID()
        guard grouped else { isBuildingNamespaces = false; return }
        let revision = namespaceGeneration, bytes = visibleKeys.map(\.bytes), separator = Data(namespaceSeparator.utf8)
        isBuildingNamespaces = true
        let worker = Task.detached(priority: .userInitiated) { KeyNamespaceTree.build(bytes, separator: separator) }
        namespaceBuild = worker
        Task {
            let tree = await worker.value
            guard revision == namespaceGeneration, !worker.isCancelled else { return }
            namespaceTree = tree; isBuildingNamespaces = false
        }
    }
    func setNamespaceSeparator(_ separator: String) {
        guard !separator.isEmpty, separator.utf8.count <= 16 else { error = "分隔符需为 1–16 个 UTF-8 字节，例如 :、/ 或 ::。"; return }
        namespaceSeparator = separator; namespaceExpansion = [:]; saveBrowserPreferences(); rebuildNamespaces()
    }
    func isNamespaceExpanded(_ id: String, depth: Int) -> Bool { namespaceExpansion[id] ?? (depth == 0) }
    func setNamespaceExpanded(_ id: String, expanded: Bool) {
        namespaceExpansion[id] = expanded; saveBrowserPreferences()
    }
    private func workspaceID(_ profile: ConnectionProfile) -> String { "\(profile.id.uuidString)/\(profile.database)" }
    func saveBrowserPreferences() {
        guard let profile = activeProfile, profile.id != demoID, connected else { return }
        var value = BrowserPreferences()
        value.separator = namespaceSeparator; value.grouped = grouped; value.expansion = namespaceExpansion
        if scanQuery.text.utf8.count <= 4096 { value.searchMode = scanQuery.mode; value.search = scanQuery.text; value.kind = scanQuery.kind }
        if let key = detail?.key.bytes, key.count <= 4096 { value.selectedKey = key }
        value.codec = valueCodec; value.format = valueFormat; value.showTypes = showKeyTypes; value.showTTL = showKeyTTL
        value.searches = savedSearches
        browserPreferences.save(value, for: profile)
    }
    func saveSearch() {
        guard search.utf8.count <= 4096 else { error = "保存的搜索不能超过 4096 字节。"; return }
        let value = SavedKeySearch(mode: searchMode, text: search, kind: typeFilter)
        savedSearches.removeAll { $0.mode == value.mode && $0.text == value.text && $0.kind == value.kind }
        savedSearches.insert(value, at: 0); savedSearches = Array(savedSearches.prefix(20)); saveBrowserPreferences()
    }
    func restoreSearch(_ value: SavedKeySearch) {
        guardDraft { [weak self] in
            guard let self else { return }
            self.searchMode = value.mode; self.search = value.text; self.typeFilter = value.kind
            self.loadKeys(reset: true, preserveSelection: false)
        }
    }
    func removeSearch(_ id: UUID) { savedSearches.removeAll { $0.id == id }; saveBrowserPreferences() }
    func searchNamespace(_ node: KeyNamespaceNode) {
        guard let pattern = String(data: RedisGlob.escapedPrefix(node.bytes), encoding: .utf8) else { return }
        guardDraft { [weak self] in
            guard let self else { return }
            self.searchMode = .pattern; self.search = pattern; self.favoritesOnly = false
            self.namespaceExpansion[node.id] = true; self.loadKeys(reset: true, preserveSelection: false)
        }
    }
    func selectKey(_ id: String?, force: Bool = false) {
        guard force || id != selectedKeyID else { return }
        let action: () -> Void = { [weak self] in self?.startDetail(id) }
        if force { startDetail(id) } else { guardDraft(action) }
    }
    private func startDetail(_ id: String?) {
        detailGeneration = UUID()
        if let previous = memberSession { Task { await previous.pause() } }
        guard let id, let key = keys.first(where: { $0.id == id }), let db = database else {
            selectedKeyID = nil; detail = nil; memberSession = nil; isLoadingDetail = false; isStoppingMembers = false; clearValue(); return
        }
        // The serialized transport finishes an old read before starting the next one; results are generation checked.
        let detailToken = detailGeneration, token = generation
        let changingKey = selectedKeyID != id
        if changingKey { memberPattern = ""; streamNewestFirst = true; streamStart = "-"; streamEnd = "+"; memberQuery = MemberQuery() }
        let session = MemberReadSession(), query = memberQuery
        memberSession = session; isStoppingMembers = false
        selectedKeyID = id; detail = nil; clearValue(resetCodec: changingKey); isLoadingDetail = true
        if changingKey { valueFormat = "文本" }
        detailTask = Task {
            do {
                let page = try await session.next { cursor, offset in try await db.inspect(key.bytes, cursor: cursor, offset: offset, query: query) }
                let states = await db.capabilities.snapshot()
                guard token == generation, detailToken == detailGeneration else { return }
                detail = page; prepareValue(page, autoFormat: changingKey); saveBrowserPreferences()
                capabilityStates = states
                isLoadingDetail = false; isStoppingMembers = false
            } catch {
                guard token == generation, detailToken == detailGeneration else { return }
                isLoadingDetail = false; isStoppingMembers = false; presentError(error)
            }
        }
    }
    func applyMemberQuery() {
        guard let id = selectedKeyID, !busy else { return }
        var query = MemberQuery(); query.pattern = memberPattern; query.newestFirst = streamNewestFirst
        query.streamStart = streamStart; query.streamEnd = streamEnd
        do { try query.validate(); memberQuery = query; startDetail(id) } catch { presentError(error) }
    }
    func stopMemberRead() {
        guard isLoadingDetail, let session = memberSession else { return }
        isStoppingMembers = true; Task { await session.pause() }
    }
    func loadMoreRows() {
        guard let db = database, let previous = detail, let session = memberSession, previous.hasMore, !busy else { return }
        let token = generation, selected = selectedKeyID, revision = detailGeneration, query = memberQuery
        isLoadingDetail = true; isStoppingMembers = false
        Task {
            do {
                var page = try await session.next { cursor, offset in try await db.inspect(previous.key.bytes, cursor: cursor, offset: offset, query: query) }
                guard token == generation, selected == selectedKeyID, revision == detailGeneration else { return }
                var seen = Set<String>(); page.rows = (previous.rows + page.rows).filter { seen.insert($0.id).inserted }
                detail = page; isLoadingDetail = false; isStoppingMembers = false
            } catch { if token == generation, revision == detailGeneration { isLoadingDetail = false; isStoppingMembers = false; presentError(error) } }
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
                    self.cleanDraft = self.draft
                    if focusKey != nil { self.tab = .browser }
                    self.loadKeys(reset: true, focusKey: focusKey)
                } catch {
                    guard self.generation == token else { return }
                    self.isWriting = false
                    if case .transport = error as? RedisError {
                        self.error = error.localizedDescription + "\n写入结果可能未知，请刷新核对。此操作未自动重试。"
                    } else { self.presentError(error) }
                }
            }
        }
        if activeProfile?.environment == .production || destructive {
            confirmation = ConfirmationRequest(title: title + "？", message: message.isEmpty ? "此操作将修改当前数据库中的数据。" : message,
                                               button: title, requiredText: activeProfile?.environment == .production ? activeProfile?.name ?? "" : "",
                                               destructive: destructive, action: execute)
        } else { execute() }
    }
    private func clearValue(resetCodec: Bool = true) {
        valueGeneration = UUID(); valueWorker?.cancel(); valuePresentation?.cancel()
        decodedValue = nil; valueDecodeError = nil; isPreparingValue = false
        draft = ""; cleanDraft = ""; valueHex = ""; valueChange = nil; valueEncodeError = nil
        if resetCodec { valueCodec = .raw }
    }
    private func prepareValue(_ page: KeyPage, autoFormat: Bool = false) {
        let codec = valueCodec
        clearValue(resetCodec: false)
        guard let original = page.content else { return }
        let revision = valueGeneration
        isPreparingValue = true
        let worker = Task.detached(priority: .userInitiated) { try DecodedValue(original: original, codec: codec) }
        valueWorker = worker
        Task {
            do {
                let value = try await worker.value
                guard revision == valueGeneration, !worker.isCancelled else { return }
                decodedValue = value; draft = value.text ?? ""; cleanDraft = draft
                if value.text == nil { valueFormat = "Hex" }
                else if autoFormat { valueFormat = value.isJSON ? "JSON" : "文本" }
            } catch {
                guard revision == valueGeneration, !worker.isCancelled else { return }
                valueDecodeError = error.localizedDescription; valueFormat = "Hex"
            }
            isPreparingValue = false; refreshValuePresentation(); saveBrowserPreferences()
        }
    }
    func chooseValueCodec(_ codec: ValueCodec) {
        guard codec != valueCodec, !busy, let page = detail else { return }
        guardDraft { [weak self] in self?.valueCodec = codec; self?.prepareValue(page, autoFormat: true) }
    }
    func restoreValueDraft() { draft = cleanDraft; refreshValuePresentation() }
    func refreshValuePresentation() {
        valuePresentation?.cancel()
        guard let original = detail?.content, !isPreparingValue else { return }
        let revision = valueGeneration, text = draft, codec = valueCodec, decoded = decodedValue
        let hex = valueFormat == "Hex" || decoded?.text == nil
        valueChange = nil; valueEncodeError = nil
        valuePresentation = Task {
            do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
            let result = await Task.detached(priority: .userInitiated) { () -> (String?, ValueChangeSummary?, String?) in
                let bytes = decoded?.text == nil ? decoded?.bytes ?? original : Data(text.utf8)
                let hexText = hex ? DataPresentation.hex(bytes) : nil
                do { return (hexText, ValueChangeSummary(original: original, replacement: try codec.encode(bytes)), nil) }
                catch { return (hexText, nil, error.localizedDescription) }
            }.value
            guard !Task.isCancelled, revision == valueGeneration, text == draft else { return }
            if let hex = result.0 { valueHex = hex }
            valueChange = result.1; valueEncodeError = result.2
        }
    }
    func saveString() {
        guard let page = detail, let original = page.content, textValueEditable, dirty, canWrite else { return }
        let text = draft, codec = valueCodec, json = valueFormat == "JSON", revision = valueGeneration
        isPreparingValue = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<Data, Error> in
                Result { let data = Data(text.utf8); if json { try JSONText.validate(data) }; return try codec.encode(data) }
            }.value
            guard revision == valueGeneration else { return }
            isPreparingValue = false
            do {
                let encoded = try result.get()
                mutate("保存值", message: "将向「\(page.key.name)」写入 \(encoded.count) 字节，保留当前 TTL 并检查原值冲突。") {
                    try await $0.saveString(key: page.key.bytes, expected: original, replacement: encoded)
                }
            } catch { presentError(error) }
        }
    }
    func formatJSON() {
        guard textValueEditable else { return }
        let revision = valueGeneration, text = draft
        isPreparingValue = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try JSONText.formatted(Data(text.utf8)) } }.value
            guard revision == valueGeneration else { return }
            isPreparingValue = false
            do { draft = String(decoding: try result.get(), as: UTF8.self); valueFormat = "JSON"; refreshValuePresentation(); notify("JSON 已格式化，保存后生效") }
            catch { presentError(error) }
        }
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
    var favoriteKeyBytes: [Data] {
        let prefix = "\(activeProfile?.id.uuidString ?? "")/\(activeProfile?.database ?? 0)/"
        return favorites.filter { $0.hasPrefix(prefix) }.compactMap { Data(base64Encoded: String($0.dropFirst(prefix.count))) }
            .sorted { $0.lexicographicallyPrecedes($1) }
    }
    func openFavorite(_ bytes: Data) {
        guardDraft { [weak self] in
            guard let self else { return }
            self.favoritesOnly = false; self.searchMode = .hex
            self.search = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
            self.loadKeys(reset: true, preserveSelection: false)
        }
    }
    func isFavorite(_ key: RedisKey) -> Bool { favorites.contains(favoriteID(key.id)) }
    func toggleFavorite(_ key: RedisKey) {
        let id = favoriteID(key.id)
        if favorites.contains(id) { favorites.remove(id) } else { favorites.insert(id) }
        UserDefaults.standard.set(Array(favorites), forKey: "favoriteKeys")
        if favoritesOnly { rebuildNamespaces() }
    }

    func runConsole() {
        guard let profile = activeProfile, connected, !busy else { return }
        let command = consoleInput
        do {
            let arguments = try CommandLine.parse(command)
            try CommandPolicy.validate(arguments, readOnly: profile.readOnly)
            let token = generation
            let execute: () -> Void = { [weak self] in
                guard let self, self.generation == token, self.activeProfile == profile else { return }
                self.executeConsole(command, arguments: arguments, profile: profile)
            }
            if profile.environment == .production && !CommandPolicy.isRead(arguments) {
                confirmation = ConfirmationRequest(title: "在生产环境执行命令？", message: command, button: "执行命令", requiredText: profile.name, action: execute)
            } else { execute() }
        } catch { presentError(error) }
    }
    private func executeConsole(_ command: String, arguments: [String], profile: ConnectionProfile) {
        let token = generation; isConsoleRunning = true; consoleInput = ""; error = nil
        consoleHistory.record(command); histories[workspaceID(profile)] = consoleHistory
        historyIndex = consoleHistory.commands.count; historyDraft = ""
        Task {
            let start = ContinuousClock.now
            do {
                await consoleResetTask?.value
                guard generation == token else { return }
                let secret = profile.id == demoID ? "" : try keychain.password(for: profile.id)
                let result = try await consoleSession.execute(arguments, profile: profile, password: secret)
                let rendered = await Task.detached(priority: .userInitiated) { result.value.preview() }.value
                guard generation == token else { return }
                consoleEntries.append(ConsoleEntry(command: command, output: rendered,
                                                   milliseconds: result.commandMilliseconds, preparationMilliseconds: result.preparationMilliseconds,
                                                   reusedConnection: result.reusedConnection, failed: false))
                if !CommandPolicy.isRead(arguments) { notify("命令已执行；切回数据浏览后按 ⌘R 刷新") }
            } catch {
                guard generation == token else { return }
                consoleEntries.append(ConsoleEntry(command: command, output: error.localizedDescription, milliseconds: start.duration(to: .now).rillMilliseconds, failed: true))
            }
            if consoleEntries.count > 100 { consoleEntries.removeFirst(consoleEntries.count - 100) }
            isConsoleRunning = false
        }
    }
    func navigateHistory(_ delta: Int) {
        let commands = consoleHistory.commands
        guard !commands.isEmpty else { return }
        if historyIndex == commands.count { historyDraft = consoleInput }
        historyIndex = min(max(0, historyIndex + delta), commands.count)
        consoleInput = historyIndex < commands.count ? commands[historyIndex] : historyDraft
    }
    func recallCommand(_ command: String) { consoleInput = command; historyIndex = consoleHistory.commands.count; historyDraft = command }
    func loadDiagnostics() {
        guard let db = database, !diagnosticsLoading else { return }
        let token = generation; diagnosticsLoading = true
        Task {
            do {
                let info = try await db.info(), states = await db.capabilities.snapshot()
                if token == generation { serverInfo = info; capabilityStates = states; diagnosticsLoading = false }
            } catch {
                let states = await db.capabilities.snapshot()
                if token == generation { capabilityStates = states; diagnosticsLoading = false; presentError(error) }
            }
        }
    }
    func loadSlowQueries() {
        guard let db = database, !diagnosticsLoading else { return }
        let token = generation; diagnosticsLoading = true
        Task {
            do { let result = try await db.slowlogReport(); if token == generation { slowlogReport = result; slowQueries = result.queries; capabilityStates = await db.capabilities.snapshot(); diagnosticsLoading = false } }
            catch { if token == generation { diagnosticsLoading = false; presentError(error) } }
        }
    }
    func startTrend() {
        guard let profile = activeProfile, connected, tab == .overview, !isSamplingTrend else { return }
        trendRevision = UUID(); let revision = trendRevision, token = generation
        isSamplingTrend = true; trend = InfoTrend()
        trendTask = Task {
            var db: RedisDatabase?
            defer { db?.close(); if revision == trendRevision { trendDatabase = nil; isSamplingTrend = false } }
            do {
                let secret = profile.id == demoID ? "" : try keychain.password(for: profile.id)
                db = try await RedisDatabase.connect(profile, password: secret, timeout: 5)
                guard revision == trendRevision, token == generation, !Task.isCancelled else { return }
                trendDatabase = db
                while !Task.isCancelled {
                    let info = try await db!.info()
                    guard revision == trendRevision, token == generation, tab == .overview else { return }
                    serverInfo = info; trend.append(info, monotonicSeconds: ProcessInfo.processInfo.systemUptime)
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                }
            } catch { if !Task.isCancelled, revision == trendRevision { presentError(error) } }
        }
    }
    func stopTrend() {
        trendRevision = UUID(); trendTask?.cancel(); trendTask = nil; trendDatabase?.close(); trendDatabase = nil; isSamplingTrend = false
    }
    func startMemoryAnalysis() {
        guard let profile = activeProfile, connected, tab == .overview, !isAnalyzingMemory else { return }
        analysisRevision = UUID(); let revision = analysisRevision, token = generation
        isAnalyzingMemory = true; memoryAnalysis = MemoryAnalysisReport()
        analysisTask = Task {
            var db: RedisDatabase?
            defer { db?.close(); if revision == analysisRevision { analysisDatabase = nil; isAnalyzingMemory = false } }
            do {
                let secret = profile.id == demoID ? "" : try keychain.password(for: profile.id)
                let database = try await RedisDatabase.connect(profile, password: secret, timeout: 5); db = database
                guard revision == analysisRevision, token == generation, !Task.isCancelled else { return }
                analysisDatabase = database
                _ = try await MemoryAnalysis.run(fetch: { cursor in try await database.scan(cursor: cursor, pattern: "*", includeMetadata: false) },
                                                metadata: { keys in try await database.metadata(for: keys, includeTTL: false, includeMemory: true, includeType: false) },
                                                update: { [weak self] report in await self?.receiveMemoryAnalysis(report, revision: revision, token: token) })
            } catch {
                if !Task.isCancelled, revision == analysisRevision { memoryAnalysis?.state = "读取失败，结果不完整"; presentError(error) }
            }
        }
    }
    private func receiveMemoryAnalysis(_ report: MemoryAnalysisReport, revision: UUID, token: UUID) {
        if revision == analysisRevision, token == generation { memoryAnalysis = report }
    }
    func stopMemoryAnalysis() {
        if isAnalyzingMemory { memoryAnalysis?.state = "已停止，结果不完整" }
        analysisRevision = UUID(); analysisTask?.cancel(); analysisTask = nil; analysisDatabase?.close(); analysisDatabase = nil; isAnalyzingMemory = false
    }
    func stopDiagnostics() { stopTrend(); stopMemoryAnalysis() }
    func exportFullKey() {
        guard let key = detail?.key, let profile = activeProfile, connected, !isExportingKey else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "redis-key.jsonl"
        panel.title = "完整导出此键（实时分段读取，非一致性快照）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let token = generation
        exportRevision = UUID(); let revision = exportRevision
        isExportingKey = true; exportProgress = nil
        exportTask = Task {
            var db: RedisDatabase?
            defer { db?.close(); if revision == exportRevision { exportDatabase = nil; isExportingKey = false } }
            do {
                let secret = profile.id == demoID ? "" : try keychain.password(for: profile.id)
                let database = try await RedisDatabase.connect(profile, password: secret, timeout: 5); db = database
                guard token == generation, revision == exportRevision, !Task.isCancelled else { return }
                exportDatabase = database
                let result = try await KeyExporter.exportFile(key: key.bytes, database: database, destination: url, update: { [weak self] progress in
                    await self?.receiveKeyExport(progress, revision: revision)
                })
                guard revision == exportRevision else { return }
                if result.footer.complete { notify("完整键值已导出：" + result.url.lastPathComponent) }
                else { error = (result.footer.failure ?? "导出不完整") + "\n文件保留于：" + result.url.path }
            } catch { if revision == exportRevision { presentError(error) } }
        }
    }
    private func receiveKeyExport(_ progress: KeyExportProgress, revision: UUID) {
        if revision == exportRevision { exportProgress = progress }
    }
    func stopKeyExport() {
        guard isExportingKey else { return }
        exportTask?.cancel(); exportDatabase?.close()
        // The exporter writes an incomplete footer and reports its .partial file before finishing.
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
