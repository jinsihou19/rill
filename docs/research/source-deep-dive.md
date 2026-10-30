# 七款 Redis 客户端源码研究：值得迁移到 Rill 的细节

研究日期：2026-10-30。对照版本：Rill `v0.1.0`，提交 `b3bf2283ef96f6771c60f0f96fabea1c21a9c793`。

这次研究已经从公开功能说明深入到实现链路。最值得优先迁移的是：**精确键直达、有预算的可取消扫描、可见行元数据加载、独立且复用的工作台会话，以及不会丢失原始数据的格式查看器**。它们直接改善日常查找、弱网响应和编辑可靠性。集群、模块生态和持续监控需要单独设计，不应挤进这一轮基础体验改进。

本文中的“迁移”均为方案建议，尚未实施。完整任务、依赖和验收条件见 [迁移路线与验收标准](migration-roadmap.md)；当前已交付能力仍以 [首版说明](../releases/v0.1.0.md) 为准。

## 研究范围和证据

本次对七个项目的搜索、分页、连接、编辑、工作台和诊断等关键路径进行静态源码追踪；其中 P3X 进一步追到两个实际承载业务的依赖仓库，共九个仓库、65 个证据位置。以下 SHA 是本次读取时固定的源码快照，**不是各产品最新发行版的声明**。提交时间也不等于发布时间。

| 项目 / 仓库 | 本次源码提交 | 重点 |
|---|---|---|
| [Another Redis Desktop Manager](https://github.com/qishibo/AnotherRedisDesktopManager/tree/c149855106628babcdfb7675a8e7ba9434d2492a) | `c14985510662` | 可暂停扫描、键树与二进制身份、连接拓扑 |
| [Tiny RDM](https://github.com/tiny-craft/tiny-rdm/tree/4ddb94a3c55f3401dbc66870f0d21cf0d6203cbc) | `4ddb94a3c55f` | 精确查询、成员分页、独立 CLI、格式转换 |
| [Medis 开源旧版](https://github.com/luin/medis/tree/12c87a5a2cc3fd7fa616beb2eaed79413538769a) | `12c87a5a2cc3` | 搜索预算、高频交互、编辑状态、专用监听连接 |
| [Redis Insight](https://github.com/redis/RedisInsight/tree/43bd288ed30dc6d2355723158dad5d7ecf4a280e) | `43bd288ed30d` | 可见行加载、连接创建合并、工作台、诊断生命周期 |
| [Redis Commander](https://github.com/joeferner/redis-commander/tree/2a222de65ed15832d4d4adfbbce564539b80115f) | `2a222de65ed1` | 动态能力目录、执行入口保护、目录展开 |
| [phpRedisAdmin](https://github.com/erikdubbelboer/phpRedisAdmin/tree/44dad2ad4fd5f7bc6e0c87e27442d7f97c2e9019) | `44dad2ad4fd5` | 作用范围校验、按键规则转换、扫描配置和直接操作 |
| [P3X Redis UI](https://github.com/patrikx3/redis-ui/tree/ffd81b2e118d980792d4b9399d64b2086188980b) | `ffd81b2e118d` | 桌面入口与依赖定位 |
| ↳ [P3X server](https://github.com/patrikx3/redis-ui-server/tree/b587f8610eec5112961b87dc55605916f4c8a0f6) | `b587f8610eec` | 命令目录、版本化导出、采样分析和压缩识别 |
| ↳ [P3X material](https://github.com/patrikx3/redis-ui-material/tree/2bba5db1dd6d5256b7694662527b5693cc48bb9b) | `2bba5db1dd6d` | 命令历史与实际前端行为 |

全部提交、许可证声明、文件、行号和永久链接保存在 [源码证据清单](upstream-sources.json)。Medis 研究对象是公开的 Electron/React 旧版，不能将这些实现归属于闭源的原生 Medis 2。P3X 壳与两个依赖的 `package.json` 版本均为 `2026.10.100`，但本文固定的是三个 Git 提交，不宣称与 npm 发布包逐字节一致。[依赖入口][X01]

Tiny RDM 和 ARDM 使用 GitNexus 辅助定位调用关系，随后回到实际源码核对。索引报告的提取范围不完整，查询也出现部分索引失败，因此图谱只用于导航；没有用“图里查不到”证明功能不存在。其他仓库通过文件、符号和调用点搜索追踪。

没有安装七款上游应用逐项试用，没有运行它们的构建脚本，也没有做相同数据集的性能对比。本文的风险判断是指定提交的静态分析，不是已复现的问题通报；收益是工程推导，不能写成实测提升百分比。

## 1. Tiny RDM：查询、分页和会话拆分很值得学

**追踪链路：** 前端详情状态 → `LoadNextKeys / GetKeySummary / GetKeyDetail` → 缓存的浏览连接 → Redis；CLI 则经过另一份客户端缓存。[扫描入口][T01]、[详情入口][T04]、[CLI 生命周期][T03]

- **把“已知键名”从全库扫描中分出来。** `LoadNextKeys` 在 `exactMatch` 分支走 `existsKey`，必要时检查类型，直接返回这个键；模式查询才进入 SCAN。这里的收益来自选择正确的命令路径，调大 COUNT 无法替代它。Rill 应提供明确的“精确键 / 模式”切换，让 `order:[1]*` 这样的键名也能按字面查找。[源码][T01] → **R01**
- **浏览连接和 CLI 会话分别管理。** 浏览服务按连接名缓存客户端；切换 DB 时关闭旧客户端并重建，而不是同时保留所有 DB 的连接。CLI 的 `clients` 是独立缓存，启动、SELECT、关闭都有入口。Rill 可学习“职责独立且复用”，避免现在每执行一条命令就重新连接认证；仍由应用控件决定 DB，保留会话命令限制。[浏览缓存][T02]、[CLI 缓存与关闭][T03] → **R04**
- **摘要、详情与成员游标拆开。** 摘要先获取类型/TTL，再根据类型获取长度；成员详情的游标随 DB、键、模式变化而重置。前端还会恢复该键的解码选项。它改善的是重复查看与继续加载的连续性，不应把所有调用合称为“一次请求”。Rill 可将成员分页状态明确绑定到连接、DB、原始键和过滤条件。[摘要和详情][T04]、[显示配置][T10] → **R08、R09**
- **Stream 默认看最新内容，并能继续向前翻。** 它使用 `XREVRANGE` 和末条 ID 续页，再跳过包含的边界项。这比 Rill 当前默认从最早条目开始更贴近日常排障。迁移时优先使用明确的排他边界，处理空页、删除和刷新；另提供方向选择。[源码][T05] → **R09**
- **显示格式与存储编码有明确接口。** 格式化和解码分开定义，保存时有 `SaveAs` 反向编码入口。迁移价值是“查看方式不等于原始字节”，并非把所有编码器都做进首版。这个提交的 `SaveAs` 在格式化后又把原始 `str` 传给编码器，因此组合转换必须单独验证，不能直接照搬。[接口][T06]、[保存][T07] → **R07**

**不照搬的边界：** 集群扫描的多个主节点共享外层 `cursor`，源码自己留有不能完全加载的 FIXME；后续集群设计应采用每节点游标。[T01] 中的 `scanKeys` 也用循环凑够结果，稀疏查询仍需要时间/请求预算。Stream 过滤分支会读全量；String 保存读取旧 TTL、SET、再 EXPIRE，缺少 Rill 当前的原值比较和原子 TTL 保留。SSH 使用 `ssh.InsecureIgnoreHostKey()`，不能作为原生 SSH 的默认认证方案。[集群扫描][T01]、[Stream 过滤][T05]、[写入顺序][T09]、[SSH/TLS][T08]

## 2. ARDM：从“支持 SCAN”推进到“用户能控制的扫描”

**追踪链路：** `refreshKeyList` → 新建或恢复 `scanBufferStream` → 追加键 → 页满暂停；键列表 → `keysToTree` → 虚拟树。[扫描][A01]、[树生成][A02]、[虚拟树][A03]

- **页满暂停，继续时恢复。** 它为每个主节点创建扫描流，收到数据时累加结果，达到显示页大小就暂停；后续操作可以恢复现有流。相比一次性“查找所有匹配键”，能更早把控制权交回用户。Rill 不需要引入 Node 流，但需要对应的原生扫描状态：游标、缓冲区、预算、暂停/继续和取消原因。[源码][A01] → **R02**
- **文件夹和真实键是两种节点。** 树构建器为文件夹生成独立标识，叶节点保留 `nameBuffer`，处理“键本身也是另一个键的前缀”的情况；展开状态独立保存，文件夹优先排序。Rill 当前一层分组可逐步升级为完整命名空间，但节点身份必须来自原始字节，不能使用解码后的显示文本或特殊后缀充当唯一性保证。[节点生成][A02]、[展开状态][A03] → **R06**
- **虚拟化之外仍有容量边界。** ARDM 的树有明确的节点上限，超限时截取并提示。说明“屏幕只画几十行”和“内存仅处理几十行”是两件事。Rill 应让树构建、排序和可见节点展开都有预算，不能仅更换一个虚拟表格就宣称支持百万键。[源码][A04] → **R06**
- **Viewer 按格式组织，原始 Buffer 作为输入。** Text/Hex/JSON/压缩等查看器通过注册项选择，并存在超大值入口。可以借鉴可扩展的查看器边界；Rill 先做好原始字节、JSON、Hex 和一个受限的可逆转换链，不需要复制完整解码器清单。[源码][A05] → **R07**
- **SSH 下的集群需要地址映射。** ARDM 会先通过入口发现 Sentinel 主节点或 Cluster 节点，再建立转发和 NAT 映射。仅把种子节点套上隧道不等于集群支持。这个链路直接影响 Rill 后续 SSH/拓扑的功能边界。[源码][A06] → **R14**

**不照搬的边界：** 跨节点页大小可能超出期望，暂停也不是彻底销毁；取消必须明确释放任务与缓冲。其命令包装器记录耗时的位置在异步结果返回之前，不能据此充当完整往返耗时。只读写命令黑名单也不能替代 Rill 的保守准入策略。Hash 回复转换器保留原始字段的做法值得参考，树身份仍需独立解决二进制碰撞。[扫描状态][A01]、[拦截和回复转换][A07]

## 3. Medis 旧版：低摩擦的工作流来自几个具体决策

**追踪链路：** 搜索文本 → 精确键 TYPE 快速路径 → 模式 SCAN → 批量类型查询 → 虚拟表格；编辑器 → 当前显示格式校验 → 保存回调 → 确认后更新状态。[搜索][M01]、[表格][M02]、[编辑器][M03]

- **先给可能的精确命中，再做范围搜索。** 已知键可以先显示，用户不必等待前缀搜索完成。这是 Rill 精确键入口的另一个参考。但不能默认把含通配符的输入既当字面键又当 glob，必须让模式含义可见。[源码][M01] → **R01**
- **扫描有“本次工作量”限制。** 搜索以结果数、迭代次数和游标结束作为停止条件，并根据匹配稀疏程度调整 COUNT；切换查询后忽略旧查询结果。其具体 COUNT/迭代常量只是当时实现，Rill 应采用可取消的时间预算与请求预算，保留空页续查能力。[源码][M01] → **R02**
- **键盘、行高和编辑入口一体考虑。** 虚拟表格配合上下移动和直接进入编辑，价值在于高频操作不必反复离开键盘。原生实现应使用 AppKit 选择、菜单命令和焦点系统，避免把 Web 快捷键代码直接移植进 NSTextView。[源码][M02] → **R06、R08**
- **保存前按当前格式校验，成功确认后更新状态。** JSON、MessagePack 与原始格式的表示被区分。Rill 应进一步保留“读取原值 / 展示模型 / 编辑草稿”，转换或保存失败时保留草稿；格式化查看不应悄悄写回 Redis。[源码][M03] → **R07**
- **监听与普通命令有不同连接生命周期。** Terminal 的 MONITOR/订阅分支会使用专用客户端，并在结束时断开。终端有命令名补全和输出条数上限；搜索模式也有本地保存入口。Rill 可先采纳补全与保存搜索，不因此开放持续监听。[终端][M04]、[模式保存][M05] → **R08、R13**

**不照搬的边界：** 该提交 TLS 设置了 `rejectUnauthorized: false`，不适合 Rill 的默认信任策略。保留 TTL 的 Lua 在原子性方面值得理解，但未检查读取原值，不能替代 Rill 现有 CAS 保存。任何从旧版观察到的行为都不用于评价原生 Medis 2。[连接与 Lua][M06]

## 4. Redis Insight：最有价值的是后台调度与工作台边界

**追踪链路：** `getKeys(keysInfo=false)` → SCAN/精确查找 → 渲染可见行 → 仅补齐缺失元数据；请求连接 → `getOrCreateClient` → 同一次创建合并等待者 → 存储与空闲回收。[扫描策略][I01]、[前端扫描][I04]、[可见行][I03]、[连接工厂][I06]

- **先拿键名，元数据随可见行和可见列加载。** 前端扫描不强制获取所有详情；渲染范围变化后，对缺失元数据的键发起补充请求，并根据显示列决定是否请求 TTL/大小。格式化也局限于当前范围。返回结果按原对象身份归位，避免“有些行已有缓存”时位置错乱。Rill 应使用原始键 ID 合并响应，取消上一代查询，缓存按连接/DB 隔离。[扫描请求][I04]、[可见行调度与合并][I03]、[列选择][I05] → **R03**
- **结果数量与扫描工作预算分开。** 策略将 COUNT 限至最多 2000，同时用独立 `scanThreshold` 限制循环；没有 glob 时走单键信息路径。`node.scanned += COUNT` 是工作量近似值，不能当成实际访问键数或准确进度。Rill 可显示“已找到 N 个匹配，扫描尚未结束”，不能显示虚假的完成百分比。[源码][I01] → **R01、R02**
- **元数据错误可以局部降级。** 某项信息失败时返回空值，而非所有键都打不开。Rill 当前扫描对 TYPE/PTTL 的 `.checked()` 会使整个批次失败；MEMORY 已是可选值。迁移时要区分键不存在、权限不足、命令不支持和连接失败，未知信息显示未知，不转换成“无 TTL”或“0 字节”。[策略中的错误处理][I17] → **R03、R05**
- **同时发起连接请求时只创建一次。** 工厂按客户端 ID 合并创建中的请求，成功后统一返回；存储层跟踪活跃状态和空闲回收。CLI 用 UUID 建立独立会话。Rill 可以在 actor 内复用同一工作台会话，并以连接配置版本、DB、用途为身份；无需把浏览、工作台、未来监听放到同一个 socket。[连接创建合并][I06]、[空闲管理][I07]、[CLI 会话][I08] → **R04**
- **工作台把执行过程作为可读对象。** 记录状态、结果、上下文和耗时，采用单调时钟计算执行时间。命令帮助有本地默认数据，更新失败仍能离线使用；补全可以展示参数位置。Rill 应先做好离线命令语法和执行阶段，保留敏感历史默认只在内存的边界。[执行记录][I09]、[离线默认数据][I11]、[参数补全][I12] → **R08**
- **实时诊断先解决生命周期。** Profiler 将高频消息短窗口聚合，observer 负责按节点订阅和释放。慢查询同时包含节点来源、时间单位，并读取服务端阈值解释采样条件。Rill 可以先采纳后者与按需趋势；未来 Profiler 必须另加有界缓冲、丢弃计数、停止和窗口关闭回收。[消息聚合][I13]、[监听释放][I14]、[Slowlog][I15] → **R10、R13**
- **集群扫描持有每个主节点的游标。** 相比单一全局游标，这个数据模型更适合后续拓扑支持；节点变更和重分片仍需重新定义去重与恢复语义。[源码][I02] → **R14**

**不照搬的边界：** Workbench 中有 `Promise.all` 执行路径，不能直接作为 Rill 有依赖的多行写脚本的执行方案。String 更新存在 SET 后恢复 TTL 的非原子窗口；名为下载流的路径先读取完整内容，再包装 Readable，不等于按块读取 Redis。Rill 应保留当前保存原子性，另设计真正有界的导出。[批量执行][I10]、[String 读写和下载][I16]

## 5. Redis Commander：动态能力探测有用，执行策略仍要自己把关

**追踪链路：** 建连 → COMMAND/模块信息 → 连接能力目录 → `postExec` 执行前检查；目录展开 → 转义前缀 → 搜索 → 生成下一层节点。[能力目录][C01]、[执行入口][C02]、[目录][C04]

- **从真实服务端获取命令目录。** 能适应服务器版本和模块变化，目录不可获取时有回退。Rill 可用它支持命令提示和功能可用性展示，但 `readonly` 标记不能自动覆盖应用禁用规则，未知命令仍需保守处理。[源码][C01] → **R05、R08**
- **只读检查在执行入口生效。** 隐藏按钮不足以保护其他入口；`postExec` 有实际检查，还拒绝未适配的 MULTI/MONITOR。Rill 现有执行层限制应继续保留，新菜单、导入和工作台都必须经过同一写入策略。[源码][C02] → **保留现有约束**
- **目录展开先转义字面前缀。** 对 `* ? [ ] \\` 等字符做 glob 转义后再添加后缀，避免“文件夹名里恰好有通配符”扩大查找范围。文件夹和键可以逐级展开，这适合迁移为原生命名空间导航。[源码][C04] → **R01、R06**

**不照搬的边界：** 静态只读回退表包含会写目标键的 BITOP，还包含 XREADGROUP；执行检查按命令首词匹配，子命令策略需要更严谨。默认用 SCAN 替换 KEYS 的包装器会一直累计结果到游标为 0，减少 Redis 单次阻塞不等于让客户端交互有界。报告据此只提出保守策略和预算要求，不声称已做远程漏洞复现。[回退表][C03]、[Stream 命令表][C06]、[SCAN 包装][C05]

## 6. phpRedisAdmin：小工具也有可迁移的产品细节

**追踪链路：** 服务端连接配置 → 键作用范围校验 → 类型/成员表单 → load/save 转换 → Redis；显示层提供容量和 TTL 的人类可读格式。[范围检查][P01]、[写入入口][P02]、[转换][P03]、[显示][P09]

- **作用范围检查集中，而非只筛选左侧列表。** 已有键和新键的操作都经过 `require_key_in_server_filter`。若 Rill 后续增加“只显示某个业务前缀”，必须区分导航过滤与真正的操作限制；若承诺后者，重命名目标、新建、工作台等入口也要覆盖。实际数据授权仍应使用 Redis ACL。[范围函数][P01]、[编辑入口][P02] → **R05 的设计约束**
- **按键模式配置数据转换。** `serialization` 将某类键映射到 load/save 闭包，方便业务数据反复查看。迁移时可支持用户手动指定“此命名空间默认按 JSON / base64 查看”，但仅作为本地显示偏好，不能将任意脚本执行和自动写回一起带入。[源码][P03] → **R07**
- **区分单次扫描量与本轮总量。** 配置有 `scansize` 和 `scanmax`，表达了两个独立问题；全局默认和每服务器配置也不同，不能笼统说它始终有严格上限。Rill 需在运行时落实预算，而非只放一个设置项。[源码][P04] → **R02**
- **直接表达用户关心的单位。** TTL 同时显示数值和可读时长，容量选择合适单位。Rill 也应区分“永久 / 已过期 / 无权限读取 / 剩余时长”，并保留精确值用于复制，避免让 `-1`、`-2`、未知值看起来一样。[源码][P09] → **R05、R10**
- **匹配语义需要专门的边界样例。** 测试覆盖字面通配符、字符类、反斜杠及高字节；匹配器也说明 Redis 来源和平台差异。这支持 Rill 对“字面键 / glob / 命名空间”分开建模；优先让服务端执行 MATCH，不自行用通用 glob 或正则宣称完全等价。[测试][P07]、[匹配器说明][P08] → **R01、R06**

**不照搬的边界：** Hash/Set/ZSet 的页面先全量读取，分页展示不等于服务器分页。导出路径的 List 逐项 LINDEX、文本命令转义、ZSet JSON 缺少分值等细节，也不适合直接作为 Rill 的无损格式。应学习明确的类型操作和可读展示，保留 Rill 成员级操作、分页与原始字节。[读取][P05]、[导出][P06]

## 7. P3X：命令目录、格式描述和分析范围值得细看

**追踪链路：** Electron 壳依赖 server/material → socket 请求 → ioredis → 按类型取值/导出；命令元数据归一化 → 前端补全；分析请求 → 扫描 → 分批元数据 → 汇总。[依赖][X01]、[详情策略][X04]、[分析][X06]

- **命令提示以类别、参数语法和子命令组织。** 从服务端命令数据提取类别，配合静态语法，并将 `CONFIG|GET` 这样的标识归一化为可读子命令。Rill 可保持离线提示，再用当前服务器能力做补充；“帮助信息”和“允许执行”是两个独立判断。[源码][X02] → **R08、R05**
- **命令历史去重、有上限。** 前端把最近执行移到首位并限制条数，便于重复任务。Rill 已有内存历史，可改进搜索/去重体验；不直接迁移其全局 localStorage 持久化策略。连接、DB 和潜在敏感参数应有明确处理。[源码][X03] → **R08**
- **导出格式显式带版本、时间、数据库和 TTL。** 字符串/集合值使用 base64，格式描述比“复制可见文本”更适合后续导入。Rill 可补全版本、完整性标志、编码和过期语义，先做单键完整导出，再考虑多键。[源码][X05] → **R11**
- **类型能力可按策略扩展。** 模块类型名被归一化，详情按类型分派；有独立版本辅助函数和 Hash 字段 TTL 请求。值得借鉴能力驱动的界面，但服务器版本号只是线索，代理、ACL 和实际命令支持也要验证。未知模块先提供元信息和只读原始结果，不自动扩大编辑面。[详情][X04]、[版本辅助][X08]、[字段 TTL][X09] → **R05、R12**
- **压缩识别可减少手工切换。** 通过特征字节尝试 gzip/zlib 等格式有实用价值。迁移需把解压移出主线程，限制输入、输出、膨胀比和执行时长；无可靠特征的格式不应在每次选键时反复盲试，更不能仅凭短片段“像 UTF-8”就当成可安全写回的文本。[源码][X07] → **R07**

**不照搬的边界：** 普通键扫描在达到数量时会停止，但 memory analysis 收集够样本后仍继续扫描直到结束，说明“保存 N 个样本”不等于“只做 N 个样本的工作”。详情路径中许多类型一次全量读取。导出虽然有 base64 值，Hash 字段使用字符串对象、Stream 转为字段对象，不能据此宣称所有字段/键均二进制无损或保留重复字段。Rill 已保留的原始字节、Stream 字段对顺序不能退化。[有界普通扫描][X10]、[分析扫描][X06]、[详情][X04]、[导出][X05]

## 8. 对照 Rill：保留优势，优先改掉真实摩擦

以下以首版代码为基线，均可在 `v0.1.0` 标签复查；后续实现后需要更新本表状态。

| 维度 | 首版真实状态 | 值得迁移的方案 | 状态 |
|---|---|---|---|
| 已知键定位 | 所有搜索走 SCAN/MATCH | 显式精确键直达、模式语义可见 | R01 待实施 |
| 扫描交互 | COUNT=200；最多续扫 8 个空页；已做去重和代次检查 | 时间/请求/结果/字节预算、暂停继续、明确取消 | R02 待实施 |
| 列表元数据 | 对每批新键全部查询 TYPE/PTTL，错误可使批次失败 | 名称先显示；可见行按需补齐、局部失败降级 | R03 待实施 |
| 工作台 | 每条命令独立新建连接并关闭，耗时含建连和格式化 | 专用会话复用、合并建连、分阶段耗时 | R04 待实施 |
| 键组织 | 一层前缀、收藏只显示已加载键 | 二进制身份的多层树、精确收藏直达、保存搜索 | R06 / R08 待实施 |
| 编辑 | 原生 JSON/Hex、String 原值 CAS+KEEPTTL、成员级修改 | 显示/草稿/原值分离、有限的可逆转换 | 现有保障保留；R07 待实施 |
| Stream | 从最早记录按页查看，原始字段对保留 | 默认最新、方向与区间选择、有预算的过滤 | R09 待实施 |
| 诊断 | 手动 INFO、最近 50 条 Slowlog | 解释单位/阈值、短窗口趋势、显式范围的按需分析 | R10 待实施 |
| 导出 | 当前已加载页；String 超限仅导出预览；集合 base64 | 版本化单键导出、完整性声明、可恢复校验 | R11 待实施 |

基线实现入口：[扫描和类型读写](../../Sources/RillCore/RedisDatabase.swift)、[异步工作流和工作台](../../Sources/RillApp/AppModel.swift)、[RESP 解码](../../Sources/RillCore/RESP.swift)、[执行策略](../../Sources/RillCore/Models.swift)、[原生编辑器高亮](../../Sources/RillApp/Theme.swift)。

研究还发现两个需要先测量的本地热点：RESP 每次解码将当前 Data 转为完整字节数组，分片响应会反复解析；JSON 高亮在每次文本变化时重建正则并处理全篇。它们值得建立分片/大文本基准后再优化，当前没有数据支持“已经造成明显卡顿”或某个加速倍数。纳入 **R07** 的验证范围。

## 9. 迁移原则

1. **迁移算法、状态边界和交互判断。** SwiftUI/AppKit、Network.framework 和 Keychain 继续构成原生应用，不因上游使用 Electron、Wails、Monaco、Socket.IO 就引入相同运行时。
2. **保护已建立的数据语义。** 原始键/值字节、Stream 字段对、TTL、只读策略、生产确认和写入结果未知提示都必须保留。上游覆盖面更大，不代表每个实现细节更可靠。
3. **为收益保留可核验指标。** 记录命令数、扫描请求数、取消延迟、首屏时间、主线程阻塞和内存峰值；不同项目不做没有相同负载数据支持的性能排名。
4. **严格分清事实、推导和计划。** 上游源码行为有永久链接；Rill 当前行为有标签；迁移方案和验收是待完成工作。本文不构成迁移完成或性能验收。

具体建议按收益和依赖排序于 [迁移路线与验收标准](migration-roadmap.md)。本轮只新增研究文档，未复制上游实现、图标或资源，未修改 Rill 产品代码。

<!-- 固定提交的源码引用；与 upstream-sources.json 一致。 -->

[T01]: https://github.com/tiny-craft/tiny-rdm/blob/4ddb94a3c55f3401dbc66870f0d21cf0d6203cbc/backend/services/browser_service.go#L480-L605
[T02]: https://github.com/tiny-craft/tiny-rdm/blob/4ddb94a3c55f3401dbc66870f0d21cf0d6203cbc/backend/services/browser_service.go#L309-L362
[T03]: https://github.com/tiny-craft/tiny-rdm/blob/4ddb94a3c55f3401dbc66870f0d21cf0d6203cbc/backend/services/cli_service.go#L90-L163
[T04]: https://github.com/tiny-craft/tiny-rdm/blob/4ddb94a3c55f3401dbc66870f0d21cf0d6203cbc/backend/services/browser_service.go#L713-L855
[T05]: https://github.com/tiny-craft/tiny-rdm/blob/4ddb94a3c55f3401dbc66870f0d21cf0d6203cbc/backend/services/browser_service.go#L1146-L1212
[T06]: https://github.com/tiny-craft/tiny-rdm/blob/4ddb94a3c55f3401dbc66870f0d21cf0d6203cbc/backend/utils/convert/convert.go#L35-L85
[T07]: https://github.com/tiny-craft/tiny-rdm/blob/4ddb94a3c55f3401dbc66870f0d21cf0d6203cbc/backend/utils/convert/convert.go#L235-L265
[T08]: https://github.com/tiny-craft/tiny-rdm/blob/4ddb94a3c55f3401dbc66870f0d21cf0d6203cbc/backend/services/connection_service.go#L85-L167
[T09]: https://github.com/tiny-craft/tiny-rdm/blob/4ddb94a3c55f3401dbc66870f0d21cf0d6203cbc/backend/services/browser_service.go#L1251-L1290
[T10]: https://github.com/tiny-craft/tiny-rdm/blob/4ddb94a3c55f3401dbc66870f0d21cf0d6203cbc/frontend/src/stores/browser.js#L527-L576
[A01]: https://github.com/qishibo/AnotherRedisDesktopManager/blob/c149855106628babcdfb7675a8e7ba9434d2492a/src/components/KeyList.vue#L112-L254
[A02]: https://github.com/qishibo/AnotherRedisDesktopManager/blob/c149855106628babcdfb7675a8e7ba9434d2492a/src/util.js#L240-L322
[A03]: https://github.com/qishibo/AnotherRedisDesktopManager/blob/c149855106628babcdfb7675a8e7ba9434d2492a/src/components/KeyListVirtualTree.vue#L24-L54
[A04]: https://github.com/qishibo/AnotherRedisDesktopManager/blob/c149855106628babcdfb7675a8e7ba9434d2492a/src/components/KeyListVirtualTree.vue#L391-L418
[A05]: https://github.com/qishibo/AnotherRedisDesktopManager/blob/c149855106628babcdfb7675a8e7ba9434d2492a/src/components/FormatViewer.vue#L61-L119
[A06]: https://github.com/qishibo/AnotherRedisDesktopManager/blob/c149855106628babcdfb7675a8e7ba9434d2492a/src/redisClient.js#L90-L163
[A07]: https://github.com/qishibo/AnotherRedisDesktopManager/blob/c149855106628babcdfb7675a8e7ba9434d2492a/src/redisClient.js#L9-L48
[M01]: https://github.com/luin/medis/blob/12c87a5a2cc3fd7fa616beb2eaed79413538769a/src/renderer/windows/MainWindow/InstanceContent/DatabaseContainer/KeyBrowser/KeyList/index.jsx#L57-L165
[M02]: https://github.com/luin/medis/blob/12c87a5a2cc3fd7fa616beb2eaed79413538769a/src/renderer/windows/MainWindow/InstanceContent/DatabaseContainer/KeyBrowser/KeyList/index.jsx#L365-L410
[M03]: https://github.com/luin/medis/blob/12c87a5a2cc3fd7fa616beb2eaed79413538769a/src/renderer/windows/MainWindow/InstanceContent/DatabaseContainer/Content/KeyContent/BaseContent/Editor/index.jsx#L74-L117
[M04]: https://github.com/luin/medis/blob/12c87a5a2cc3fd7fa616beb2eaed79413538769a/src/renderer/windows/MainWindow/InstanceContent/DatabaseContainer/Content/Terminal/index.jsx#L43-L139
[M05]: https://github.com/luin/medis/blob/12c87a5a2cc3fd7fa616beb2eaed79413538769a/src/renderer/storage/Patterns.js#L1-L14
[M06]: https://github.com/luin/medis/blob/12c87a5a2cc3fd7fa616beb2eaed79413538769a/src/renderer/redux/actions/connection.js#L71-L96
[I01]: https://github.com/redis/RedisInsight/blob/43bd288ed30dc6d2355723158dad5d7ecf4a280e/redisinsight/api/src/modules/browser/keys/scanner/strategies/standalone.scanner.strategy.ts#L82-L183
[I02]: https://github.com/redis/RedisInsight/blob/43bd288ed30dc6d2355723158dad5d7ecf4a280e/redisinsight/api/src/modules/browser/keys/scanner/strategies/cluster.scanner.strategy.ts#L29-L184
[I03]: https://github.com/redis/RedisInsight/blob/43bd288ed30dc6d2355723158dad5d7ecf4a280e/redisinsight/ui/src/pages/browser/components/key-list/KeyList.tsx#L338-L423
[I04]: https://github.com/redis/RedisInsight/blob/43bd288ed30dc6d2355723158dad5d7ecf4a280e/redisinsight/ui/src/slices/browser/keys.ts#L649-L690
[I05]: https://github.com/redis/RedisInsight/blob/43bd288ed30dc6d2355723158dad5d7ecf4a280e/redisinsight/ui/src/slices/browser/keys.ts#L1249-L1281
[I06]: https://github.com/redis/RedisInsight/blob/43bd288ed30dc6d2355723158dad5d7ecf4a280e/redisinsight/api/src/modules/database/providers/database.client.factory.ts#L47-L120
[I07]: https://github.com/redis/RedisInsight/blob/43bd288ed30dc6d2355723158dad5d7ecf4a280e/redisinsight/api/src/modules/redis/redis.client.storage.ts#L38-L94
[I08]: https://github.com/redis/RedisInsight/blob/43bd288ed30dc6d2355723158dad5d7ecf4a280e/redisinsight/api/src/modules/cli/services/cli-business/cli-business.service.ts#L72-L123
[I09]: https://github.com/redis/RedisInsight/blob/43bd288ed30dc6d2355723158dad5d7ecf4a280e/redisinsight/api/src/modules/workbench/workbench.service.ts#L40-L117
[I10]: https://github.com/redis/RedisInsight/blob/43bd288ed30dc6d2355723158dad5d7ecf4a280e/redisinsight/api/src/modules/workbench/workbench.service.ts#L158-L197
[I11]: https://github.com/redis/RedisInsight/blob/43bd288ed30dc6d2355723158dad5d7ecf4a280e/redisinsight/api/src/modules/commands/commands-json.provider.ts#L46-L87
[I12]: https://github.com/redis/RedisInsight/blob/43bd288ed30dc6d2355723158dad5d7ecf4a280e/redisinsight/ui/src/components/cli/components/cli-input/CliAutocomplete/CliAutocomplete.tsx#L14-L67
[I13]: https://github.com/redis/RedisInsight/blob/43bd288ed30dc6d2355723158dad5d7ecf4a280e/redisinsight/api/src/modules/profiler/models/profiler.client.ts#L25-L62
[I14]: https://github.com/redis/RedisInsight/blob/43bd288ed30dc6d2355723158dad5d7ecf4a280e/redisinsight/api/src/modules/profiler/models/redis.observer.ts#L60-L167
[I15]: https://github.com/redis/RedisInsight/blob/43bd288ed30dc6d2355723158dad5d7ecf4a280e/redisinsight/api/src/modules/slow-log/slow-log.service.ts#L39-L139
[I16]: https://github.com/redis/RedisInsight/blob/43bd288ed30dc6d2355723158dad5d7ecf4a280e/redisinsight/api/src/modules/browser/string/string.service.ts#L73-L155
[I17]: https://github.com/redis/RedisInsight/blob/43bd288ed30dc6d2355723158dad5d7ecf4a280e/redisinsight/api/src/modules/browser/keys/scanner/strategies/standalone.scanner.strategy.ts#L31-L79
[C01]: https://github.com/joeferner/redis-commander/blob/2a222de65ed15832d4d4adfbbce564539b80115f/lib/connections.js#L299-L320
[C02]: https://github.com/joeferner/redis-commander/blob/2a222de65ed15832d4d4adfbbce564539b80115f/lib/routes/apiv1.js#L326-L381
[C03]: https://github.com/joeferner/redis-commander/blob/2a222de65ed15832d4d4adfbbce564539b80115f/lib/redisCommands/redisCore.js#L5-L23
[C04]: https://github.com/joeferner/redis-commander/blob/2a222de65ed15832d4d4adfbbce564539b80115f/lib/routes/apiv1.js#L1334-L1455
[C05]: https://github.com/joeferner/redis-commander/blob/2a222de65ed15832d4d4adfbbce564539b80115f/bin/redis-commander.js#L606-L661
[C06]: https://github.com/joeferner/redis-commander/blob/2a222de65ed15832d4d4adfbbce564539b80115f/lib/redisCommands/redisCore.js#L114-L148
[P01]: https://github.com/erikdubbelboer/phpRedisAdmin/blob/44dad2ad4fd5f7bc6e0c87e27442d7f97c2e9019/includes/functions.inc.php#L192-L221
[P02]: https://github.com/erikdubbelboer/phpRedisAdmin/blob/44dad2ad4fd5f7bc6e0c87e27442d7f97c2e9019/edit.php#L25-L92
[P03]: https://github.com/erikdubbelboer/phpRedisAdmin/blob/44dad2ad4fd5f7bc6e0c87e27442d7f97c2e9019/includes/functions.inc.php#L284-L298
[P04]: https://github.com/erikdubbelboer/phpRedisAdmin/blob/44dad2ad4fd5f7bc6e0c87e27442d7f97c2e9019/includes/config.sample.inc.php#L30-L36
[P05]: https://github.com/erikdubbelboer/phpRedisAdmin/blob/44dad2ad4fd5f7bc6e0c87e27442d7f97c2e9019/view.php#L69-L104
[P06]: https://github.com/erikdubbelboer/phpRedisAdmin/blob/44dad2ad4fd5f7bc6e0c87e27442d7f97c2e9019/export.php#L11-L108
[P07]: https://github.com/erikdubbelboer/phpRedisAdmin/blob/44dad2ad4fd5f7bc6e0c87e27442d7f97c2e9019/tests/redis_pattern_match_test.php#L40-L100
[P08]: https://github.com/erikdubbelboer/phpRedisAdmin/blob/44dad2ad4fd5f7bc6e0c87e27442d7f97c2e9019/includes/functions.inc.php#L29-L49
[P09]: https://github.com/erikdubbelboer/phpRedisAdmin/blob/44dad2ad4fd5f7bc6e0c87e27442d7f97c2e9019/includes/functions.inc.php#L253-L269
[X01]: https://github.com/patrikx3/redis-ui/blob/ffd81b2e118d980792d4b9399d64b2086188980b/package.json#L86-L96
[X02]: https://github.com/patrikx3/redis-ui-server/blob/b587f8610eec5112961b87dc55605916f4c8a0f6/src/lib/redis-command-meta.mjs#L33-L89
[X03]: https://github.com/patrikx3/redis-ui-material/blob/2bba5db1dd6d5256b7694662527b5693cc48bb9b/src/react/pages/console/ConsoleComponent.tsx#L208-L220
[X04]: https://github.com/patrikx3/redis-ui-server/blob/b587f8610eec5112961b87dc55605916f4c8a0f6/src/service/socket.io/request/key/get.mjs#L16-L142
[X05]: https://github.com/patrikx3/redis-ui-server/blob/b587f8610eec5112961b87dc55605916f4c8a0f6/src/service/socket.io/request/key/export.mjs#L18-L151
[X06]: https://github.com/patrikx3/redis-ui-server/blob/b587f8610eec5112961b87dc55605916f4c8a0f6/src/service/socket.io/request/memory/analysis.mjs#L10-L47
[X07]: https://github.com/patrikx3/redis-ui-server/blob/b587f8610eec5112961b87dc55605916f4c8a0f6/src/service/decompress.mjs#L10-L79
[X08]: https://github.com/patrikx3/redis-ui-server/blob/b587f8610eec5112961b87dc55605916f4c8a0f6/src/lib/redis-version.mjs#L1-L21
[X09]: https://github.com/patrikx3/redis-ui-server/blob/b587f8610eec5112961b87dc55605916f4c8a0f6/src/service/socket.io/request/hash-field/ttl-get.mjs#L1-L23
[X10]: https://github.com/patrikx3/redis-ui-server/blob/b587f8610eec5112961b87dc55605916f4c8a0f6/src/service/socket.io/shared.mjs#L121-L191
