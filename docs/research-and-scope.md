# Rill：Redis 客户端调研与功能边界

调研时间：2026-10-30（Asia/Taipei）。Stars 为 GitHub API 当日快照，代表关注度，不代表质量或真实用户数。依据公开 README、仓库元数据与官方 Redis 文档；没有安装七款产品逐一测量性能。下表的取舍是面向本项目的判断，不能视为竞品实测结论。

## 七个代表项目

| 项目 | Stars | 优势和可借鉴方案 | 对本项目的局限 / 取舍 |
|---|---:|---|---|
| [Another Redis Desktop Manager](https://github.com/qishibo/AnotherRedisDesktopManager) | 34,836 | SSH/TLS/ACL、Cluster/Sentinel、只读模式、连接颜色分组、SCAN、六类数据、二进制与多种解码器，日常管理覆盖全面 | Electron；功能面很广，原生感和界面密度需要独立设计。采纳环境标识、只读模式、分页与二进制安全处理 |
| [Tiny RDM](https://github.com/tiny-craft/tiny-rdm) | 13,152 | Go + Wails，复用系统 WebView，SCAN 与集合分段加载、操作历史、慢查询、导入导出 | 比内嵌 Chromium 更精简，但界面仍是 WebView。采纳按需加载、慢查询入口与轻量原则；不把项目宣称的百万键能力当实测数据 |
| [Medis](https://github.com/luin/medis) | 11,721 | 简洁的键编辑流程、JSON 校验、命令终端、命名空间模式，明确使用 SCAN | **公开仓库是 Electron/React 的旧版**；README 指向的 Medis 2 原生商业版不是这个开源实现。公开仓库最后推送 2024-02-21。采纳操作聚焦和原生体验方向，不混淆两代产品 |
| [Redis Insight](https://github.com/redis/RedisInsight) | 8,926 | 官方维护，类型编辑、Workbench、SlowLog、Profiler、Pub/Sub、RedisJSON、搜索和向量可视化，专业深度强 | Electron/Monaco/Node；定位超出日常轻量管理。采纳独立工作台、服务器概览和慢查询；模块生态与分析平台后置 |
| [Redis Commander](https://github.com/joeferner/redis-commander) | 4,002 | 多实例、Docker 部署、只读配置、SCAN、常见类型与基本 Stream 操作 | Web 运维工具，需要服务进程和 Web 安全配置；不是 Mac 原生交互。采纳多实例管理与只读边界 |
| [phpRedisAdmin](https://github.com/erikdubbelboer/phpRedisAdmin) | 3,182 | 简单直接、部署容易，多服务器与 TLS 配置，常用操作容易发现 | PHP/Web 架构；README 的 TODO 仍包括编码编辑与更好的错误处理。采纳低学习成本，避免将二进制强行转文本 |
| [P3X Redis UI](https://github.com/patrikx3/redis-ui) | 808 | JSON 编辑、二进制上传下载、SSH/Cluster/Sentinel、多语言、桌面和 Web 同源 | Electron/Node/Web，当前功能范围包括大量模块和 AI 工具。采纳 JSON/Hex 双视图和数据导出，暂不扩展为模块管理平台 |

上述 Stars 经 `gh api repos/{owner}/{repo}` 读取。未包含已无法访问的 `RedisDesktop/RedisDesktopManager`，避免用旧排名充数。

## 亮点采纳与当前实现对照

以下按 2026-10-30 的 Rill 源码核对。“已实现”只表示对应能力已经落地，不表示交互细节、功能深度、性能或稳定性已达到参考项目水平。亮点来源可能重叠，这里记录主要参考对象。

| 学习的亮点 | 主要参考项目 | Rill 已经实现 | 目前差距 / 未实现部分 |
|---|---|---|---|
| 清楚区分连接环境，减少误操作 | ARDM、Redis Commander | 多连接、环境颜色、只读模式；生产环境初选默认只读，写入需输入连接名称 | 环境标签不是自定义连接分组；没有多层连接目录和配置导入导出 |
| 大库按需浏览，避免一次拉取全部键 | Tiny RDM、Medis、ARDM | SCAN + MATCH/TYPE、游标续载和去重，TYPE/PTTL 批量获取；集合按类型分段读取 | 未实测百万键、超大集合和弱网；COUNT 为提示，响应仍受 32 MiB 硬限制 |
| 用命名空间组织键，降低查找成本 | Medis、ARDM | 按第一个冒号分隔前缀分组、服务器模式搜索、收藏已加载键 | 目前是一层前缀分组，不是完整多层键树；没有可配置分隔符和保存搜索模式 |
| 依照数据结构提供专用操作 | ARDM、Tiny RDM、Redis Insight | 六类数据浏览；String 编辑、Hash 字段修改、List 位置修改和尾部追加、Set 增删、ZSet 分值修改、Stream 新增/删除 | 尚无 Hash 字段 TTL、Stream 消费组管理、GEO 专用界面和模块类型编辑器 |
| 让 JSON 易读、易改、易校验 | Medis、P3X、Redis Insight | JSON 自动识别、原生语法高亮、校验和格式化 | 还没有 Monaco 级编辑体验、JSON Schema、折叠、路径导航和结构化树编辑 |
| 正确处理二进制内容 | P3X、ARDM、Redis Insight | 键值以原始字节传输；Hex 查看；二进制值只读；当前页导出保留字节，Stream 保留原始字段 | 不支持二进制文件导入，以及 MessagePack、Protobuf、压缩数据等解码/重新编码 |
| 图形操作与命令工作台结合 | Redis Insight、Medis、Tiny RDM | 独立连接执行命令、引号/转义、命令名称建议、内存历史、耗时和结果复制 | 命令建议尚不是理解参数和上下文的智能补全；没有多行脚本、结果可视化、持久事务和订阅会话 |
| 将排障入口放在同一工作空间 | Redis Insight、Tiny RDM | INFO 概览、内存/连接/命中率等指标、最近 50 条慢查询 | 尚无 Profiler、Pub/Sub、历史趋势、Big Key/Hot Key 分析和诊断建议 |
| 高频操作保持直接、容易发现 | phpRedisAdmin、Medis | 三栏浏览、原生表单、键操作菜单、常用快捷键 | 这是界面设计原则的采纳，尚无对比可用性测试来证明操作效率更高 |

主要实现位置：[`RedisDatabase.swift`](../Sources/RillCore/RedisDatabase.swift)（扫描、类型操作、冲突与 TTL）、[`Models.swift`](../Sources/RillCore/Models.swift)（输入解析和命令策略）、[`AppModel.swift`](../Sources/RillApp/AppModel.swift)（工作流、收藏、生产确认、导出）、[`WorkspaceView.swift`](../Sources/RillApp/WorkspaceView.swift)（连接与键浏览）、[`KeyDetailView.swift`](../Sources/RillApp/KeyDetailView.swift)（类型界面）、[`DiagnosticsView.swift`](../Sources/RillApp/DiagnosticsView.swift)（工作台和诊断）。

### 为本产品补强的能力

结合 Mac 原生定位和编辑可靠性，Rill 另外实现了 Keychain 密码保存、原生文件面板、未保存退出提醒、String 原值比较和 TTL 保留、部分集合修改的冲突检查、超时后关闭连接及不自动重试写入。这些是本项目的实现选择，不据此声称竞品没有同等能力，也不声称这些方案由 Rill 首创。

### 首轮调研能支持的结论

已经学习并实现了多家产品的核心工作流，但目前吸收的主要是功能与设计原则。首轮没有逐个安装七款客户端做相同任务的体验对比，也没有逐个深入分析其源码、性能优化和异常恢复策略，因此不足以宣称“已经集各家最佳于一身”。

后续最值得深化的参考对象是 Tiny RDM 的分段加载和连接管理、Medis 的高频交互、Redis Insight 的工作台与诊断。应先通过源码追踪和相同数据集实测，分别明确值得采纳的细节、实现成本与验收标准，再扩充功能。

## 许可证与实现策略

ARDM、旧版 Medis、Redis Commander、P3X 为 MIT；Tiny RDM 为 GPL-3.0；Redis Insight README 标注 SSPL；phpRedisAdmin README 标注 CC BY 3.0。这里只研究公开功能与交互方案，Rill 的 Swift 代码独立编写，不复制这些仓库的代码、图标或资源。

## 产品定位

面向开发者的 macOS 原生 Redis 工作台：连接清楚、找键快、编辑可靠、异常说人话。使用 SwiftUI/AppKit、Network.framework、Security/Keychain，无 Electron、WebView 和 Node 运行时，无外部 Swift 依赖。界面以简体中文为主，保留 Redis 类型和命令原名。

最低目标 macOS 14；协议目标 Redis 6.2+ standalone（兼容性以实际测试记录为准）。首次交付必须连接真实 Redis，空状态和失败状态可用；演示数据只能来自显式启动的独立本地测试实例。

## 本次实现边界

1. 连接：多配置、环境颜色、ACL 用户名/密码、TCP、验证系统证书的 TLS、连接测试、数据库切换、Keychain 保存密码，生产环境默认只读。可连接由用户管理的本地 SSH 转发端口。
2. 浏览：SCAN + MATCH/TYPE，游标续载、去重、按键名前缀分组、当前库数量、收藏键；TYPE/PTTL 元数据批量获取。搜索范围是服务器匹配，分组与收藏视图只反映已加载键。
3. 数据：String/Hash/List/Set/ZSet/Stream 分页查看；String 文本/JSON/Hex，JSON 校验与格式化；Hash 字段编辑、List 位置编辑与尾部追加、Set 成员增删、ZSet 分值编辑、Stream 新增/删除条目；创建键、重命名、TTL、删除。
4. 可靠性：String 保存使用原值比较并保留 TTL；集合按单个字段/成员操作，不整表覆盖。只读限制在执行入口生效；生产写入确认，删除确认；禁止控制台切换数据库/认证/事务/订阅模式以及服务器管理等命令。
5. 工作台：引号和转义解析、命令建议、内存历史、耗时、结果复制；使用独立临时连接，避免污染浏览会话。控制台历史和慢查询可能含敏感业务数据，不落盘。
6. 诊断：手动刷新的 INFO 指标、连接延迟、内存、命中率、客户端数；慢查询列表，不后台持续 MONITOR。
7. Mac 体验：三栏布局、原生菜单与快捷键、系统明暗模式、可调整栏宽、原生文件面板、无障碍标签、可直接运行的 `.app`。

## 明确后置

- 内建 SSH 配置/密钥托管、Cluster 槽路由、Sentinel 发现与自动故障转移：需要独立拓扑和断线语义，不伪装成已支持；检测到非 standalone 会明确报错。
- Pub/Sub、MONITOR、阻塞命令与持久事务：需要专用连接生命周期，避免占用交互会话。
- RedisJSON/TimeSeries/向量等模块的专用编辑器，压缩/MessagePack/Protobuf 自定义解码器。
- 全库导入导出、跨实例迁移、批量删除、FLUSHDB/FLUSHALL、服务端配置管理、ACL 管理。
- 云同步、团队账户、AI 对话、在线服务依赖。
- App Store 分发、Developer ID 签名、公证、自动更新与 Intel 实机验收；本次提供本机构建的开发版本。

## 关键实现约束

- [SCAN](https://redis.io/docs/latest/commands/scan/) 的 COUNT 是提示，可能返回空页和重复项；持续迭代到游标为 0 才是一次扫描结束。扫描期间的数据变化不构成一致性快照。
- [RESP](https://redis.io/docs/latest/develop/reference/protocol-spec/) 长度按字节处理，键与值以 Data 保留；网络包边界不能当作消息边界。
- [SET](https://redis.io/docs/latest/commands/set/) 的 KEEPTTL 用于保留既有 TTL。通过原子 Lua 检查原值，冲突时拒绝覆盖；不自动重试写入。
- 字符串预览上限 1 MiB，超限仅预览、不允许保存截断值；单帧限制 32 MiB。集合使用有界命令，COUNT 不能保证严格响应大小，协议层仍有硬上限。
- 超时/断线会关闭连接。写入超时的结果视为未知，需要刷新核对，不能提示“肯定未保存”。
- 不声称已验证百万键、生产负载、远端 TLS 或所有 Redis 版本；验证记录单独维护。

## 验收

使用新启动、仅监听 127.0.0.1 的 Redis 实例测试，绝不连接或清空用户已有数据库。覆盖 RESP 分包/二进制/错误响应、ACL、数据库隔离、SCAN 去重、各类型真实读写、TTL 保留、编辑冲突、只读与命令策略、连接失败和超时。构建 `.app` 并检查原生界面和主要交互。
