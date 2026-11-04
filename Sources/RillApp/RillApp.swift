import SwiftUI
import RillCore

@main
struct RillApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var updater = AppUpdater()
    @Environment(\.openWindow) private var openWindow
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        Window("rill", id: "main") {
            WorkspaceView().environmentObject(model).environmentObject(updater)
                .onAppear { delegate.model = model; updater.start(model: model) }
        }
            .defaultSize(width: 1260, height: 800)
            .windowToolbarStyle(.unified)
            .commands {
                CommandGroup(replacing: .appInfo) {
                    Button("关于 rill") { openWindow(id: "about") }
                    Divider()
                    Button("检查更新…") { updater.checkForUpdates() }.disabled(!updater.canCheckForUpdates)
                }
                CommandGroup(replacing: .appSettings) {}
                CommandGroup(replacing: .newItem) {
                    Button("新建连接…") { model.editConnection(nil) }.keyboardShortcut("n", modifiers: [.command, .shift]).disabled(model.busy)
                    Button("新建键…") { model.sheet = EditorSheet(kind: .newKey) }.keyboardShortcut("n", modifiers: .command).disabled(!model.canWrite)
                }
                CommandMenu("连接") {
                    ForEach(model.profiles) { profile in Button(profile.name) { model.connect(profile) }.disabled(model.busy) }
                    Divider()
                    Button("断开连接") { model.disconnect() }.disabled(!model.connected || model.busy)
                }
                CommandGroup(after: .toolbar) {
                    Button("搜索键") { NotificationCenter.default.post(name: .rillFocusSearch, object: nil) }.keyboardShortcut("f", modifiers: .command).disabled(!model.connected)
                    Button("刷新") { NotificationCenter.default.post(name: .rillRefresh, object: nil) }.keyboardShortcut("r", modifiers: .command).disabled(!model.connected || model.busy)
                    Divider()
                    ForEach(Array(WorkspaceTab.allCases.enumerated()), id: \.element.id) { index, tab in
                        Button(tab.title) { model.switchTab(tab) }.keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command).disabled(!model.connected)
                    }
                }
                CommandGroup(replacing: .help) {
                    Button("查看使用说明") {
                        if let url = URL(string: "https://github.com/jinsihou19/rill/blob/main/docs/user-guide.md") { NSWorkspace.shared.open(url) }
                    }
                }
            }
        Window("关于 rill", id: "about") {
            AboutView().environmentObject(updater)
        }
        .defaultPosition(.center)
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    weak var model: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.delegate = self
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model?.isWriting == true || model?.isConsoleRunning == true || model?.isExportingKey == true {
            model?.error = "操作正在进行，请等待结果或停止导出后再退出。"; return .terminateCancel
        }
        if model?.dirty == true {
            let alert = NSAlert(); alert.messageText = "退出并放弃未保存的修改？"; alert.informativeText = "当前键有未保存的修改。"
            alert.addButton(withTitle: "继续编辑"); alert.addButton(withTitle: "退出")
            return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
        }
        return .terminateNow
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { NSApp.terminate(nil); return false }
}
