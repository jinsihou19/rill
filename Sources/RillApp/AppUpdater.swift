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

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let issue = error as NSError
        // Sparkle also ends successful no-update checks through this callback.
        if issue.domain == SUSparkleErrorDomain {
            if issue.code == Int(SUError.noUpdateError.rawValue) { updaterDidNotFindUpdate(updater); return }
            if issue.code == Int(SUError.installationCanceledError.rawValue) { status = "已取消安装，可稍后再试。"; return }
        }
        status = "检查更新失败，请稍后重试。\n" + error.localizedDescription
    }

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

struct AboutView: View {
    @EnvironmentObject private var updater: AppUpdater
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版" }
    private var buildNumber: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—" }
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 20) {
                RillMark(size: 72)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Rill").font(.system(size: 30, weight: .semibold))
                    Text("Redis for Mac").font(.system(size: 13)).foregroundStyle(.secondary)
                    Text("版本 \(version)（构建 \(buildNumber)）").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("软件更新").font(.system(size: 13, weight: .semibold))
                VStack(alignment: .leading, spacing: 18) {
                    Toggle(isOn: $updater.automaticallyChecksForUpdates) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("自动检查更新")
                            Text("每天检查，有新版本时提醒你。")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.toggleStyle(.switch).disabled(!updater.canCheckForUpdates)
                        .accessibilityLabel("自动检查更新").accessibilityHint("每天检查，有新版本时提醒你。")
                    Divider()
                    HStack(alignment: .center, spacing: 20) {
                        Text(updater.status).font(.callout).foregroundStyle(.secondary)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("检查更新…") { updater.checkForUpdates() }
                            .controlSize(.large).disabled(!updater.canCheckForUpdates)
                    }
                    if updater.waitingToInstall {
                        Button("继续安装并重启") { updater.resumeInstallation() }
                            .controlSize(.large)
                    }
                }.padding(20).background(RillTheme.panel, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(RillTheme.border))
                Text("安装更新前会征求你的确认。请先保存草稿，并等待写入或导出完成。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 20) {
                Link("项目主页", destination: URL(string: "https://github.com/jinsihou19/rill")!)
                Link("版本发布记录", destination: URL(string: "https://github.com/jinsihou19/rill/releases")!)
                Spacer()
            }
            .font(.system(size: 12))
        }.padding(32).frame(width: 600).fixedSize(horizontal: false, vertical: true)
    }
}
