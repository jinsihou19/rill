# 命令工作台：限制、原因与风险

[使用指南](user-guide.md#命令工作台) · [文档目录](README.md)

核对日期：2026-11-04。本文描述 rill 当前工作台的实际策略，命令支持情况仍取决于 Redis 版本、代理和服务端 ACL。

## 为什么 FLUSHDB 被禁止

`FLUSHDB` 会删除**当前 DB 的所有键**；`FLUSHALL` 会删除**实例所有 DB 的所有键**。Redis 没有对应的撤销命令，恢复依赖已有备份等手段。`ASYNC` 也会删除数据，只是改变后台释放的方式。因此两者在本地、开发、预发布和生产连接中都被工作台直接拦截，关闭只读或完成生产确认也不能放行。[Redis FLUSHDB](https://redis.io/docs/latest/commands/flushdb/)、[FLUSHALL](https://redis.io/docs/latest/commands/flushall/)

看到「工作台不执行 FLUSHDB」时，**本次请求在客户端校验阶段被拒绝，没有发送该命令**。这与请求已发送后发生超时的“结果未知”不同。

确需清库，应由有权限的操作人在专用运维终端中核对实例、DB、影响范围和备份后执行。rill 当前没有全库清空入口；应用中的删除操作针对选中的键。

## 限制如何生效

1. **始终禁止：58 个命令名。** 包括下面完整清单中的管理、会话、订阅、阻塞及脚本命令。命令名不区分大小写；按整个命令名拦截的命令，其所有子命令和参数形式都被禁止。
2. **仅开放部分子命令：`MEMORY`、`SLOWLOG`。** 只允许下文列出的诊断子命令，其他形式在可写连接中也会拒绝。
3. **只读连接额外限制：** 仅接受明确识别的只读命令；其他普通写入、未知命令和模块命令都被拒绝。
4. **生产可写连接额外确认：** 通过上述校验的写入或未知命令，仍需输入连接名称确认。确认不会解除前两类限制。

这些是 rill 的产品边界与误操作保护，**不等同于 Redis 自身禁用命令，也不替代服务端 ACL**。限制依据见 [CommandPolicy](../Sources/RillCore/Models.swift)，工作台发送前还会在 [ConsoleSession](../Sources/RillCore/ConsoleSession.swift) 再次校验；账户权限应由 [Redis ACL](https://redis.io/docs/latest/operate/oss_and_stack/management/security/acl/) 控制。

## 完整禁止清单

下面的风险等级是结合命令语义和 rill 会话模型的判断，不是 Redis 官方 ACL 分类，也不是发生事故的概率。**极高**表示可能造成大范围数据丢失、停服或拓扑改变；**高**表示可能破坏数据、权限、可用性或暴露业务内容；**中**主要涉及连接状态错位、等待或结果不明确。只读子命令的风险通常较低，但当前部分命令族采取整体拦截。

### 数据、服务与运维

| 禁止的命令 | 为什么禁止、主要风险 | 风险 | 替代方式 |
| --- | --- | --- | --- |
| `FLUSHDB`、`FLUSHALL` | 清空当前 DB 或整个实例，误选目标会造成大范围数据丢失 | 极高 | 在运维终端核对目标和恢复方案；少量删除使用键操作 |
| `SWAPDB` | 交换两个 DB 的内容，依赖 DB 编号的应用可能立即读写到另一套数据 | 极高 | 通过受控的数据切换流程操作 |
| `SHUTDOWN` | 关闭 Redis 服务；部分选项还会影响退出时的持久化行为 | 极高 | 使用服务管理平台或运维终端 |
| `DEBUG` | 调试命令包含可影响进程、延迟及服务状态的操作，工作台不提供此能力 | 高至极高 | 在隔离环境中使用调试工具 |
| `CONFIG` | 配置修改会影响实例行为、持久化和可用性；目前连 `CONFIG GET` 等只读形式也整体禁止 | 高至极高；只读形式较低 | 常见指标看「服务器」页，完整配置通过运维渠道查看 |
| `ACL` | 用户和权限变更可能扩大访问范围或导致账户不可用；`ACL WHOAMI`、`ACL LIST` 等也整体禁止 | 高至极高；只读形式较低 | 由授权管理员管理账户与权限 |
| `MODULE` | 加载或卸载服务器扩展涉及代码及数据类型生命周期；`MODULE LIST` 也整体禁止 | 高至极高；只读形式较低 | 在服务端部署和变更流程中管理模块 |
| `REPLICAOF`、`SLAVEOF` | 改变复制角色或上游，重新同步可能替换数据、改变读写角色 | 极高 | 使用复制拓扑管理流程 |
| `REPLCONF`、`SYNC`、`PSYNC` | 属于复制握手或同步协议，连接可能进入复制数据流，超出普通请求/响应模型 | 高 | 交由 Redis 节点和复制工具处理 |
| `FAILOVER` | 发起复制角色切换，可能影响写入和业务可用性 | 极高 | 使用受控的故障切换流程 |
| `CLUSTER`、`SENTINEL` | 涉及集群或 Sentinel 的拓扑和管理能力；rill 当前仅支持 standalone，查询子命令也整体禁止 | 高至极高；只读形式较低 | 使用支持对应拓扑的客户端或管理平台 |
| `MIGRATE`、`RESTORE` | 跨实例搬运或恢复序列化数据；`MIGRATE` 默认会移走源键，`REPLACE` 可覆盖目标 | 高 | 使用专门的迁移、恢复工具并核对源和目标；同 DB 复制可用「复制到新键」 |
| `SAVE` | 同步持久化会占用 Redis 执行时间，数据量大时可能使服务长时间停顿 | 高 | 交由持久化和备份流程管理 |
| `BGSAVE`、`BGREWRITEAOF` | 后台保存或重写仍会消耗 CPU、内存和磁盘资源，可能放大实例压力 | 高 | 在监控和容量约束下由运维触发 |
| `KEYS` | 遍历整个 DB，一次返回所有匹配键；大库中可能引起延迟和大响应，即使只读也不安全 | 高 | 使用数据浏览搜索，或分批执行 `SCAN` 并迭代游标 |

上述语义可参照 Redis 官方文档：[SWAPDB](https://redis.io/docs/latest/commands/swapdb/)、[SHUTDOWN](https://redis.io/docs/latest/commands/shutdown/)、[CONFIG SET](https://redis.io/docs/latest/commands/config-set/)、[ACL SETUSER](https://redis.io/docs/latest/commands/acl-setuser/)、[MODULE LOAD](https://redis.io/docs/latest/commands/module-load/)、[REPLICAOF](https://redis.io/docs/latest/commands/replicaof/)、[PSYNC](https://redis.io/docs/latest/commands/psync/)、[CLUSTER](https://redis.io/docs/latest/commands/cluster/)、[MIGRATE](https://redis.io/docs/latest/commands/migrate/)、[RESTORE](https://redis.io/docs/latest/commands/restore/)、[SAVE](https://redis.io/docs/latest/commands/save/)、[BGSAVE](https://redis.io/docs/latest/commands/bgsave/)、[BGREWRITEAOF](https://redis.io/docs/latest/commands/bgrewriteaof/)、[KEYS](https://redis.io/docs/latest/commands/keys/)。表中的工作台限制和风险判断以 rill 当前实现为依据。

### 连接状态与事务

工作台复用专用 Redis 连接，并与界面保持相同的认证、DB 和只读设置。手动改变连接状态，可能使屏幕显示的上下文与实际命令使用的上下文不同；空闲回收、切库和重连也无法保证用户手工建立的事务继续存在。

| 禁止的命令 | 为什么禁止、主要风险 | 风险 | 替代方式 |
| --- | --- | --- | --- |
| `AUTH`、`SELECT` | 手动更换身份或 DB 会偏离应用连接配置，后续命令可能使用意外的权限或数据库 | 中至高 | 使用连接编辑器设置账号，使用顶部 DB 控件切库 |
| `HELLO` | 可协商协议版本、身份与客户端名称；切到 RESP3 等形式可能超出当前解码器支持范围 | 中 | 由应用建立连接并处理认证 |
| `QUIT`、`RESET`、`CLIENT` | 可断开、重置或修改连接状态；`CLIENT` 还包含影响其他连接的管理操作。`CLIENT LIST` 等查询也整体禁止 | 中至高；只读形式较低 | 使用连接设置中的断开/重新连接；客户端管理交给运维工具 |
| `MULTI`、`EXEC`、`DISCARD`、`WATCH`、`UNWATCH` | 事务与监视状态跨多条命令保留，会改变后续命令的排队、执行及结果含义；工作台不维护用户事务生命周期 | 中至高 | 需要事务时，在具有明确连接生命周期的程序或专用终端中执行 |

协议和事务语义见 [HELLO](https://redis.io/docs/latest/commands/hello/)、[CLIENT](https://redis.io/docs/latest/commands/client/)、[MULTI](https://redis.io/docs/latest/commands/multi/)。

### 持续订阅与阻塞读取

| 禁止的命令 | 为什么禁止、主要风险 | 风险 | 替代方式 |
| --- | --- | --- | --- |
| `SUBSCRIBE`、`PSUBSCRIBE`、`SSUBSCRIBE`、`UNSUBSCRIBE`、`PUNSUBSCRIBE`、`SUNSUBSCRIBE` | 订阅状态和持续推送不符合工作台单次请求/响应模型；取消订阅也属于同一类状态管理 | 中 | 使用具有独立订阅连接的 Pub/Sub 工具 |
| `MONITOR` | 持续输出其他请求，可能带来明显性能开销并暴露业务命令及参数 | 高 | 使用有时限和权限控制的运维观测工具；一般排查先看「慢查询」 |
| `BLPOP`、`BRPOP`、`BRPOPLPUSH`、`BLMOVE`、`BLMPOP`、`BZPOPMIN`、`BZPOPMAX`、`BZMPOP` | 可长期等待并占用当前工作台连接；返回时还可能弹出或移动数据，等待期间超时可能使结果不明确 | 中至高 | 在消费者程序中使用专用连接；仅查看时使用 `LRANGE`、`ZRANGE` |
| `XREAD`、`XREADGROUP` | 两者均可能阻塞；消费组读取还涉及消费状态。当前按命令名整体拦截，**即使没有 `BLOCK` 参数也禁止** | 中至高 | 查看消息使用 Stream 详情、`XRANGE` 或 `XREVRANGE`；消费使用专用消费者 |

阻塞的是客户端连接，不意味着所有阻塞命令都会阻塞整个 Redis 服务。工作台没有通过移除 `BLOCK`、缩短超时来自动放行这些命令。相关语义见 [SUBSCRIBE](https://redis.io/docs/latest/commands/subscribe/)、[MONITOR](https://redis.io/docs/latest/commands/monitor/)、[BLPOP](https://redis.io/docs/latest/commands/blpop/)、[XREAD](https://redis.io/docs/latest/commands/xread/)、[XREADGROUP](https://redis.io/docs/latest/commands/xreadgroup/)。

### Lua、函数与脚本管理

| 禁止的命令 | 为什么禁止、主要风险 | 风险 | 替代方式 |
| --- | --- | --- | --- |
| `EVAL`、`EVALSHA`、`FCALL` | 可执行服务端逻辑并批量读写数据，普通命令名检查无法判断脚本或函数的实际影响 | 高至极高 | 使用经过审查、测试并限制权限的程序或运维流程 |
| `EVAL_RO`、`EVALSHA_RO`、`FCALL_RO` | 只读执行也可能进行大范围读取或长时间计算；当前不提供通用脚本/函数执行能力，因此一并禁止 | 高，主要是性能风险 | 拆成范围明确的只读查询，或在受控流程中运行 |
| `SCRIPT`、`FUNCTION` | 加载、清理、删除、恢复或终止脚本/函数涉及实例共享状态；查询与帮助子命令也整体禁止 | 中至高，取决于子命令 | 通过程序发布或运维流程管理 |

“只读”并不代表运行成本可控。语义见 [Redis 可编程能力](https://redis.io/docs/latest/develop/programmability/) 和 [EVAL_RO](https://redis.io/docs/latest/commands/eval_ro/)。rill 的可视化编辑内部会使用固定、受控的 Lua 做原值检查和原子修改；这是应用实现路径，不代表工作台允许输入任意 Lua，服务端 ACL 仍需允许相应命令。

## MEMORY 与 SLOWLOG：只开放明确子命令

| 命令族 | 工作台允许的子命令 | 其他形式为何拒绝 |
| --- | --- | --- |
| `MEMORY` | `USAGE`、`STATS`、`DOCTOR`、`MALLOC-STATS` | 仅提供这四种只读诊断；`PURGE` 会请求分配器释放内存，可能较慢，不属于只读查询。`MEMORY HELP`、省略子命令及未来新子命令也不在当前允许列表 |
| `SLOWLOG` | `GET`、`LEN`、`HELP` | `RESET` 会清空共享慢查询记录，破坏排查线索；省略子命令及未来新子命令也不放行 |

例如，`MEMORY USAGE key`、`SLOWLOG GET 20` 在只读连接中也可通过客户端策略校验；`MEMORY PURGE`、`SLOWLOG RESET` 在可写连接中仍被禁止。服务端仍会检查参数、版本和权限。参见 [MEMORY PURGE](https://redis.io/docs/latest/commands/memory-purge/) 与 [SLOWLOG RESET](https://redis.io/docs/latest/commands/slowlog-reset/)。

## 只读连接还会禁止什么

只读连接使用允许列表。除上面始终禁止的命令外，以下命令也不能执行：

| 类型 | 示例 | 原因和风险 |
| --- | --- | --- |
| 修改键值、成员或消费状态 | `SET`、`MSET`、`HSET`、`LPUSH`、`SADD`、`ZADD`、`XADD`、`XGROUP`、`XACK` | 会改变数据或业务状态 |
| 删除、重命名、复制与修改过期时间 | `DEL`、`UNLINK`、`RENAME`、`COPY`、`EXPIRE`、`PEXPIRE`、`PERSIST` | 可能删除/覆盖数据、改变生命周期或影响其他键 |
| 具有副作用的命令 | `GETDEL`、`GETEX`、`PUBLISH` | 名称可能像查询，实际会删除、修改 TTL 或向订阅者发送消息 |
| 未知、未来新增或模块命令 | `JSON.GET`、`FT.SEARCH`、`FUTURE.READ` | 客户端未明确识别，不能仅凭名称认定为只读；即使服务端定义为只读，也会按写入处理 |

常用的 `GET`、`MGET`、`SCAN`、`TYPE`、`TTL`、`HGET`、`LRANGE`、`SMEMBERS`、`ZRANGE`、`XRANGE`、`XINFO`、`INFO`、`DBSIZE` 等已识别读取可通过策略检查；完整识别列表见 [CommandPolicy.isRead](../Sources/RillCore/Models.swift)。

在关闭只读的连接中，上表普通写入和未知/模块命令可以继续交给服务端处理；生产环境还需确认。**未被拦截不代表低风险**：例如普通 `DEL`、覆盖型 `SET` 或大范围集合读取仍可能造成数据损失或性能问题。rill 不会根据业务用途判断一次写入是否正确，也不把命令名称检查作为安全隔离边界。

## 看到提示后如何处理

| 提示 | 含义 | 下一步 |
| --- | --- | --- |
| 「工作台不执行 …」 | 命中始终禁止清单，本次命令未发送 | 根据上表使用应用控件、只读替代查询或专用运维工具 |
| 「工作台只提供 … 的只读诊断子命令」 | `MEMORY` / `SLOWLOG` 子命令不在允许列表，本次命令未发送 | 改用允许的子命令；确需管理操作时走运维渠道 |
| 「当前连接为只读，不能执行写入或无法确认安全的命令」 | 当前连接禁止写入或未识别命令，本次命令未发送 | 先确认用途和权限；确需普通写入时在连接设置中调整只读，始终禁止项仍不会放行 |
| 服务端 `NOPERM` / `NOAUTH` / `WRONGPASS` | 服务端拒绝权限或认证，并非工作台命令清单拦截 | 核对连接账号、密码和服务端 ACL |
| 「写入结果可能未知」 | 请求可能已经执行，只是响应因超时或断线丢失 | 先查询实际状态，再决定是否重试；应用不会自动重放写入 |

限制提示后的「查看限制与风险」会在默认浏览器中打开本文在线版本。链接为固定文档地址，不附带连接地址、账号、键名或命令参数；在线查看需要网络，旧版应用的规则可能与最新文档不同。

查找大量键应优先使用应用分批搜索，或使用 [SCAN](https://redis.io/docs/latest/commands/scan/) 迭代游标；`COUNT` 是提示值，单批数量不固定，扫描也不是一致性快照。需要运维权限不代表需要在日常客户端中开放所有运维命令。
