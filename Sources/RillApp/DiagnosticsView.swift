import SwiftUI
import RillCore

struct ConsoleView: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var focused: Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("工作台使用独立会话，连续命令复用连接；沿用当前 DB 与只读设置", systemImage: "point.3.connected.trianglepath.dotted")
                Spacer()
                Button("清空显示") { model.consoleEntries = [] }.buttonStyle(.borderless).disabled(model.isConsoleRunning)
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 23).frame(height: 43)
            Divider()
            if model.consoleEntries.isEmpty {
                EmptyState(symbol: "terminal", title: "从一条命令开始", message: "支持引号、空值和转义。↑ ↓ 浏览历史，⌘↩ 执行。\n会话控制和服务器管理命令不在此执行。") {
                    HStack(spacing: 9) {
                        ForEach(["PING", "INFO server", "SCAN 0 COUNT 20"], id: \.self) { command in
                            Button(command) { model.consoleInput = command; focused = true }.font(.system(size: 11, design: .monospaced))
                        }
                    }
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(model.consoleEntries) { entry in
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack(alignment: .top) {
                                        Text("❯").foregroundStyle(RillTheme.accent)
                                        Text(entry.command).font(.system(size: 12, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                                        Spacer()
                                        Text(String(format: "%.1f ms", entry.milliseconds)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                                            .help(entry.failed ? "失败前耗时" : "命令发送至收到完整响应的耗时")
                                        Button { copyText(entry.output); model.notify("结果已复制") } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("复制命令结果")
                                    }
                                    Text(entry.output).font(.system(size: 12, design: .monospaced)).foregroundStyle(entry.failed ? .red : .primary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                    if let preparation = entry.preparationMilliseconds {
                                        Text(String(format: "%@ · 准备 %.1f ms · 命令往返 %.1f ms", entry.reusedConnection ? "复用连接" : "新建连接", preparation, entry.milliseconds))
                                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                                    }
                                }.padding(22).id(entry.id)
                                Divider().padding(.horizontal, 22)
                            }
                        }
                    }.onChange(of: model.consoleEntries.count) { _, _ in if let last = model.consoleEntries.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 7) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button(suggestion) { model.consoleInput = suggestion + " "; focused = true }
                            .font(.system(size: 10, design: .monospaced)).buttonStyle(.borderless).padding(.horizontal, 6).padding(.vertical, 4)
                            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 4))
                    }
                    Spacer()
                    Text("历史仅保存在本次会话").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                HStack(spacing: 12) {
                    Text("DB \(model.activeProfile?.database ?? 0) ❯").font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(RillTheme.accent)
                    TextField("输入 Redis 命令…", text: $model.consoleInput).textFieldStyle(.plain).font(.system(size: 13, design: .monospaced)).focused($focused)
                        .onSubmit { model.runConsole() }.onKeyPress(.upArrow) { model.navigateHistory(-1); return .handled }.onKeyPress(.downArrow) { model.navigateHistory(1); return .handled }
                        .disabled(model.isConsoleRunning).accessibilityIdentifier("consoleInput")
                    Button { model.runConsole() } label: {
                        if model.isConsoleRunning { ProgressView().controlSize(.small) } else { Label("执行", systemImage: "arrow.turn.down.left") }
                    }.buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command).disabled(model.busy || model.consoleInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding(12).background(RillTheme.canvas, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(RillTheme.border))
            }.padding(20).background(RillTheme.panel.opacity(0.4))
        }
    }
    private var suggestions: [String] {
        let prefix = model.consoleInput.split(separator: " ").first.map(String.init)?.uppercased() ?? ""
        return Array((prefix.isEmpty ? ["GET", "SET", "SCAN", "HGET", "ZRANGE", "INFO"] : CommandPolicy.suggestions.filter { $0.hasPrefix(prefix) }).prefix(6))
    }
}

struct OverviewView: View {
    @EnvironmentObject private var model: AppModel
    private var info: [String: String] { model.serverInfo }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("每一项状态，都有迹可循。").font(.system(size: 23, weight: .semibold))
                        Text("按需读取 INFO，不在后台持续采样。").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let mode = info["redis_mode"] { Text(mode.uppercased()).font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1).foregroundStyle(.secondary).padding(8).background(.quaternary.opacity(0.3), in: Capsule()) }
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    MetricCard(title: "已用内存", value: info["used_memory_human"] ?? "—", subtitle: "峰值 \(info["used_memory_peak_human"] ?? "—")", symbol: "memorychip", color: .blue)
                    MetricCard(title: "当前连接", value: info["connected_clients"] ?? "—", subtitle: "阻塞 \(info["blocked_clients"] ?? "—")", symbol: "network", color: .purple)
                    MetricCard(title: "每秒操作", value: info["instantaneous_ops_per_sec"] ?? "—", subtitle: "累计 \(info["total_commands_processed"] ?? "—")", symbol: "waveform.path", color: .green)
                    MetricCard(title: "缓存命中率", value: hitRate, subtitle: "基于累计 hits / misses", symbol: "scope", color: .orange)
                    MetricCard(title: "运行时间", value: info["uptime_in_days"].map { $0 + " 天" } ?? "—", subtitle: "端口 \(info["tcp_port"] ?? "—")", symbol: "clock", color: .indigo)
                    MetricCard(title: "已淘汰键", value: info["evicted_keys"] ?? "—", subtitle: "已过期 \(info["expired_keys"] ?? "—")", symbol: "tray.and.arrow.up", color: RillTheme.accent)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("实例详情").font(.system(size: 13, weight: .semibold)).padding(17)
                    Divider()
                    infoRow("Redis 版本", info["redis_version"] ?? "—")
                    infoRow("操作系统", info["os"] ?? "—")
                    infoRow("内存上限", info["maxmemory_human"] ?? "—")
                    infoRow("淘汰策略", info["maxmemory_policy"] ?? "—")
                    infoRow("角色", info["role"] ?? "—")
                    infoRow("持久化", "AOF \(info["aof_enabled"].map { $0 == "1" ? "开启" : "关闭" } ?? "未知") · RDB \(info["rdb_last_bgsave_status"] ?? "—")")
                    ForEach(info.keys.filter { $0.hasPrefix("db") && Int($0.dropFirst(2)) != nil }.sorted(), id: \.self) { key in infoRow(key.uppercased(), info[key] ?? "") }
                }.background(RillTheme.panel.opacity(0.4), in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(RillTheme.border))
                Text("指标来自本次 INFO 响应。命中率反映实例自启动以来的累计情况，不能代替业务时段分析。").font(.system(size: 10)).foregroundStyle(.tertiary)
                if !model.capabilityStates.isEmpty { capabilitySection }
            }.padding(28).frame(maxWidth: 1100)
        }.overlay { if model.diagnosticsLoading { ProgressView().padding(15).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)) } }
    }
    private var hitRate: String {
        guard let hits = Double(info["keyspace_hits"] ?? ""), let misses = Double(info["keyspace_misses"] ?? ""), hits + misses > 0 else { return "—" }
        return String(format: "%.1f%%", hits / (hits + misses) * 100)
    }
    private var capabilitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("当前连接能力").font(.system(size: 13, weight: .semibold))
            Text("根据实际请求结果记录；未使用的命令不作推断。重新连接后重新检测。").font(.caption).foregroundStyle(.secondary)
            ForEach(model.capabilityStates) { item in
                HStack {
                    Text(item.id).fontDesign(.monospaced)
                    Spacer()
                    Text(item.status.rawValue).foregroundStyle(item.status == .available ? Color.secondary : Color.orange)
                }.font(.system(size: 11)).help(item.message ?? "最近一次请求可用")
            }
        }.padding(17).background(RillTheme.panel.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
    private func infoRow(_ name: String, _ value: String) -> some View {
        HStack { Text(name).foregroundStyle(.secondary); Spacer(); Text(value).fontDesign(.monospaced).textSelection(.enabled) }.font(.system(size: 11)).padding(.horizontal, 17).padding(.vertical, 11)
    }
}

private struct MetricCard: View {
    let title: String, value: String, subtitle: String, symbol: String
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(title).font(.system(size: 11)).foregroundStyle(.secondary); Spacer(); Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(color) }
            Text(value).font(.system(size: 28, weight: .medium, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
            Text(subtitle).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(RillTheme.panel.opacity(0.4), in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(RillTheme.border))
    }
}

struct SlowlogView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("把时间花在该优化的地方。").font(.system(size: 20, weight: .semibold))
                    Text("最近 50 条 SLOWLOG。耗时仅指服务端执行时间，不包含网络往返。").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if model.diagnosticsLoading { ProgressView().controlSize(.small) }
            }.padding(25)
            Divider()
            if model.slowQueries.isEmpty {
                EmptyState(symbol: "clock.badge.checkmark", title: "暂无慢查询记录", message: "当前 SLOWLOG 为空。是否记录取决于服务器设置的阈值。") { Button("刷新") { model.loadSlowQueries() }.disabled(model.diagnosticsLoading) }
            } else {
                Table(model.slowQueries) {
                    TableColumn("时间") { item in Text(item.date.formatted(date: .omitted, time: .standard)).font(RillTheme.mono) }.width(90)
                    TableColumn("耗时") { item in Text(String(format: "%.3f ms", Double(item.microseconds) / 1000)).font(RillTheme.mono).foregroundStyle(item.microseconds >= 10000 ? .orange : .primary) }.width(95)
                    TableColumn("命令") { item in Text(item.command).font(RillTheme.mono).lineLimit(3).textSelection(.enabled) }
                    TableColumn("客户端") { item in Text(item.client).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary) }.width(130)
                }.tableStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
    }
}
