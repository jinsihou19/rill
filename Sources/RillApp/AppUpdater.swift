import AppKit
import Combine
import SwiftUI
@preconcurrency import Sparkle

/// 持有应用级更新会话；后台只提示，安装重启前检查草稿和正在进行的操作。
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var availableVersion: String?
    @Published private(set) var waitingToInstall = false
    @Published private(set) var status = "每天自动检查更新，安装前由你确认。"
    @Published var automaticallyChecksForUpdates = true {
        didSet {
            if let updater = controller?.updater, updater.automaticallyChecksForUpdates != automaticallyChecksForUpdates {
                updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
            }
        }
    }
    private weak var model: AppModel?
    private var controller: SPUStandardUpdaterController?
    private var observations: Set<AnyCancellable> = []
    private var pendingInstallation: (() -> Void)?

    /// 只在带有完整更新配置的应用包中启动；SwiftPM 测试和命令行运行不访问更新服务。
    func start(model: AppModel) {
        self.model = model
        guard controller == nil else { return }
        guard Bundle.main.bundleURL.pathExtension == "app",
              let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: feed), url.scheme == "https", url.host != nil,
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else {
            status = "此版本暂不支持应用内更新，请从项目主页下载。"; return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }.store(in: &observations)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).receive(on: RunLoop.main)
            .sink { [weak self] in self?.automaticallyChecksForUpdates = $0 }.store(in: &observations)
        do { try controller.updater.start() }
        catch { status = error.localizedDescription }
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        status = "正在检查更新…"; controller?.checkForUpdates(nil)
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableVersion = item.displayVersionString; status = "发现新版本 \(item.displayVersionString)"
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        availableVersion = nil; status = "当前已是最新版本。"
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) { status = "检查更新失败，请稍后重试。\n" + error.localizedDescription }

    var supportsGentleScheduledUpdateReminders: Bool { true }
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool { false }
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if !state.userInitiated { availableVersion = update.displayVersionString; status = "发现新版本 \(update.displayVersionString)" }
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        postponeInstallationIfNeeded(installHandler)
    }

    /// 暂缓安装后保留 Sparkle 的恢复句柄，必须由用户再次点击，避免任务结束时突然重启。
    func postponeInstallationIfNeeded(_ installHandler: @escaping () -> Void) -> Bool {
        guard let reason = model?.updateRestartBlocker else { return false }
        pendingInstallation = installHandler; waitingToInstall = true; status = reason
        model?.notify(reason)
        return true
    }

    func resumeInstallation() {
        if let reason = model?.updateRestartBlocker { status = reason; model?.notify(reason); return }
        let action = pendingInstallation; pendingInstallation = nil; waitingToInstall = false
        action?()
    }
}

struct UpdateSettingsView: View {
    @EnvironmentObject private var updater: AppUpdater
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版" }
    var body: some View {
        Form {
            Section {
                LabeledContent("rill", value: version)
                Toggle("自动检查更新", isOn: $updater.automaticallyChecksForUpdates).disabled(!updater.canCheckForUpdates)
                Text(updater.status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                HStack {
                    if updater.waitingToInstall { Button("继续安装并重启") { updater.resumeInstallation() } }
                    Spacer()
                    Button("检查更新…") { updater.checkForUpdates() }.disabled(!updater.canCheckForUpdates)
                }
            } header: { Text("更新") } footer: { Text("自动检查只显示新版提示，安装需要确认。请先保存草稿，并等待写入或导出结束。") }
            Section("链接") {
                Link("项目主页", destination: URL(string: "https://github.com/jinsihou19/rill")!)
                Link("版本发布记录", destination: URL(string: "https://github.com/jinsihou19/rill/releases")!)
            }
        }.formStyle(.grouped).scrollContentBackground(.hidden).padding(12).frame(width: 480, height: 330)
    }
}
