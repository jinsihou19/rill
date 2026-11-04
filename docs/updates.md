# Rill 应用内更新与发布

[项目首页](../README.md) · [文档目录](README.md)

## 使用

从 **Rill 菜单 → 检查更新…** 或 **Rill 菜单 → 关于 Rill** 手动检查。默认每天自动检查；后台发现新版时，侧栏显示更新按钮，不主动弹出安装窗口。自动检查可以在关于窗口中关闭。

关于窗口显示应用版本与构建号，例如“版本 0.2.6（构建 9）”，并提供项目主页和版本发布记录。当前暂不提供独立设置窗口。

用户主动打开更新后，Sparkle 原生窗口显示版本和更新说明，负责下载、验证、安装和重启。不会自动重放 Redis 写入。

安装重启前会检查未保存草稿、正在执行的写入 / 命令 / 导出，以及尚未完成的编辑弹窗。存在这些状态时暂缓；保存或还原草稿、结束操作后，再点击“继续安装更新”。任务完成本身不会触发重启。

v0.2.4 及更早版本没有更新组件，需要先手动安装支持更新的版本。初始更新源可以没有发布条目；新安装包只有在正式发布并更新 appcast 后才会推送给用户。

## 更新来源与校验

- 稳定更新源：[appcast.xml](https://raw.githubusercontent.com/jinsihou19/rill/main/appcast.xml)。
- 安装包：[GitHub Releases](https://github.com/jinsihou19/rill/releases)。
- 更新组件：固定 Sparkle 2.10.1，应用打包时内嵌框架，保留其原始签名及符号链接。
- 更新源和安装包均验证 Ed25519 签名，先校验安装包再解压。签名公钥随应用发布。
- Rill 使用独立签名账户 `app.rill.redis`；私钥存于发布者的 macOS Keychain，CI 使用仓库加密 Secret `SPARKLE_PRIVATE_KEY`，私钥不进入 Git。
- 内部 `CFBundleVersion` 必须单调递增；对外版本使用 `CFBundleShortVersionString`。Bundle ID 和连接 / 密码存储保持兼容。

实现参考 [CodexMeter](https://github.com/jinsihou19/CodexMeter) 的静默检查、应用内提示与发布说明内嵌方案。接口与打包规则按 [Sparkle 官方文档](https://sparkle-project.org/documentation/) 核对。

## 发布新版本

1. 修改 `assets/Info.plist` 中的版本和递增构建号，补充 `docs/releases/v<版本>.md`（链接使用完整 HTTPS 地址，保证更新窗口和 Release 中均可打开），提交并推送 `main`。
2. 在 GitHub Actions 手动运行 **Package and publish Rill**。
3. 工作流测试后构建 `arm64 + x86_64` Universal 应用，生成 ZIP、SHA-256 和已签名 appcast，更新说明与 GitHub Release 使用同一份 Markdown。
4. 发布成功后，工作流提交新的 `appcast.xml`；客户端下一次检查即可发现新版。

工作流仅手动触发。普通提交和推送运行测试，不创建 Release。

本机也可先生成签名发布产物：

```sh
./scripts/package-release.sh
```

该脚本要求干净、已提交的工作区，只生成 `build/releases/v<版本>-<构建号>/`，不安装、不发布。相同版本的输出目录和不递增的构建号会被拒绝。签名后的 appcast 不应手工编辑；修改内容后必须重新签名。

当前应用采用 ad-hoc 签名，未完成 Developer ID 签名或 Apple 公证。Universal 构建通过也不等于已在 Intel 和 macOS 14 实机验收。

组件许可证见 [Sparkle 及其附带代码](licenses/Sparkle.txt)。
