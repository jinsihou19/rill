import SwiftUI
import RillCore

struct ConsoleHistoryView: View {
    let history: CommandHistory
    let scope: String
    let onSelect: (String) -> Void
    let onCancel: () -> Void
    @State private var query = ""
    @State private var selected: String?
    @FocusState private var searchFocused: Bool
    private var matches: [String] { history.matching(query) }
    private var panelHeight: CGFloat { matches.isEmpty ? 240 : min(350, 132 + CGFloat(matches.count) * 44) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("命令历史").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(scope).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    Button(action: onCancel) { Image(systemName: "xmark") }.buttonStyle(.borderless).accessibilityLabel("关闭命令历史")
                }
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("筛选命令或参数…", text: $query).textFieldStyle(.plain).focused($searchFocused)
                        .onSubmit { chooseSelected() }
                        .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
                        .onKeyPress(.downArrow) { moveSelection(1); return .handled }
                        .accessibilityIdentifier("consoleHistory.search")
                    if !query.isEmpty {
                        Button { query = ""; searchFocused = true } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                            .buttonStyle(.plain).accessibilityLabel("清空历史筛选")
                    }
                }.padding(8).background(RillTheme.canvas, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(searchFocused ? RillTheme.accent.opacity(0.7) : RillTheme.border))
            }.padding(14)
            Divider()
            if matches.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath").font(.title2).foregroundStyle(.tertiary)
                    Text(history.commands.isEmpty ? "暂无命令历史" : "没有匹配的历史命令").font(.callout).foregroundStyle(.secondary)
                    if history.commands.isEmpty {
                        Text("执行过的命令会显示在这里").font(.caption).foregroundStyle(.tertiary)
                    } else { Button("清空筛选") { query = ""; searchFocused = true }.buttonStyle(.borderless) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(matches, id: \.self) { command in
                                Button { onSelect(command) } label: {
                                    HStack(alignment: .top, spacing: 8) {
                                        Text(String(command.prefix(240))).font(.system(size: 12, design: .monospaced)).lineLimit(2)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        if selected == command { Image(systemName: "arrow.turn.down.left").font(.system(size: 11)).foregroundStyle(.secondary) }
                                    }.padding(.horizontal, 10).padding(.vertical, 8).contentShape(Rectangle())
                                        .background(selected == command ? RillTheme.accent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 5))
                                }.buttonStyle(.plain).help(command).id(command)
                                    .accessibilityLabel("填入历史命令：\(command)").accessibilityAddTraits(selected == command ? .isSelected : [])
                            }
                        }.padding(6)
                    }.onChange(of: selected) { _, value in if let value { proxy.scrollTo(value, anchor: .center) } }
                }
            }
            Divider()
            HStack {
                Text("\(matches.count) / \(history.commands.count) 条 · 最近使用优先")
                Spacer()
                Text("↑↓ 选择 · ↩ 填入 · Esc 关闭")
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 10)
        }.frame(width: 460, height: panelHeight).onExitCommand(perform: onCancel)
            .onAppear { query = ""; selected = history.matching("").first }
            .task { await Task.yield(); searchFocused = true }
            .onChange(of: query) { _, _ in selected = matches.first }
    }

    private func moveSelection(_ delta: Int) {
        let commands = matches
        guard !commands.isEmpty else { return }
        let index = selected.flatMap { commands.firstIndex(of: $0) } ?? 0
        selected = commands[min(max(0, index + delta), commands.count - 1)]
    }
    private func chooseSelected() {
        if let selected, matches.contains(selected) { onSelect(selected) }
    }
}
