# 单键导出格式 v1

入口：键操作菜单 →「完整导出此键」。当前页导出仍保留，二者含义不同。完整导出使用独立连接，支持停止；默认最多 256 MiB 文件、100 万条记录、10,000 页和 60 秒请求边界预算。单条 JSONL 限 1 MiB，String 按 256 KiB 原始块读取；较大单成员可能无法在限额内导出，会明确失败。

文件以 UTF-8 JSONL 写入，每行一个 JSON 对象，顺序为一个 `header`、零或多个 `entry`、一个 `footer`。Data 字段为标准 Base64，数值分值保留服务端字符串。写入临时 `.partial` 文件，权限 0600；完整结束并同步到磁盘后才原子替换所选目标。停止/读取失败保留 `.partial`，原有目标文件不受影响。磁盘写失败可能无法补上 footer；缺 footer 的文件总是不完整。

## 记录结构

| record | 对象 | 内容 |
|---|---|---|
| header | header | `version: 1`、`keyBase64`、`kind`、开始长度/成员数 `count`、`collectedAt`、一致性说明、过期策略、排除范围 |
| entry | entry | 按下表编码的当前块/成员 |
| footer | footer | `complete`、`entries`、原始 `payloadBytes`、前序全部行（含 LF）的 `sha256`、`finishedAt`、可选 `failure` |

| 类型 | entry 字段 |
|---|---|
| String | `offset` 为原始字节偏移，`value` 为 Base64 字节块；空 String 没有 entry |
| Hash | `field`、`value` 为 Base64；空字段/空值保留 |
| List | `index` 和 Base64 `value` |
| Set | Base64 `value` |
| ZSet | Base64 `field` 与原始字符串 `score` |
| Stream | Base64 条目 ID `field` 与 Base64 扁平数组 `streamFields`；保留顺序、重复字段名及空字段 |

`payloadBytes` 为各 entry 的 field/value/streamFields 原始字节总和，不包含分值字符串、序号、偏移或 JSON 编码开销。文件 SHA-256 可检查截断/误改，不提供来源认证。

## 过期语义与一致性

- `expiryMode: permanent`：读取时为永久键。
- `absolute-unix-milliseconds`：PEXPIRETIME 返回的绝对截止时刻 `expiresAtUnixMilliseconds`。
- `estimated-absolute-unix-milliseconds`：不支持 PEXPIRETIME 时，由服务端 TIME + PTTL 顺序读取估算；存在采样间隔误差。
- `unknown`：权限或响应不足以确定过期策略。值内容仍可导出，但不能据此恢复原 TTL。

本格式不保存“剩余 TTL 后重新计时”的默认语义。任何后续恢复工具应尊重绝对截止时刻，已经过期时不得延长寿命。未知策略必须另行明确选择。

`consistency` 固定为 `live-segmented-read-not-snapshot`。开始/结束检查类型及长度，成员去重，String 检查每块长度；发现变化就不标完整。**长度不变的并发修改仍可能无法发现**，因此 `complete: true` 只表示本次键值读取流程完整，不能证明一致性快照。Stream 只读取开始时最新 ID 以内的普通条目；消费组、PEL、Hash 字段 TTL、模块及服务器内部状态不在范围内，header 的 `excludedState` 明示这些排除。

## 检查与当前边界

运行 `python3 scripts/verify-export.py /path/to/key.jsonl` 可以离线检查版本、Base64、块/下标连续性、数量和摘要，不连接 Redis。首版没有导入入口；集成测试在独立合成 Redis 上解码文件并还原六种类型及绝对过期时间，用于验证格式，不能描述为已支持生产迁移。

「复制到新键」使用当前连接、当前 DB 的服务端 COPY（Redis 6.2+），不发送 REPLACE；目标存在时拒绝覆盖，遵守只读/生产确认。COPY 不支持或被拒绝时报告实际能力，不自动回退 DUMP/RESTORE，也不重试失败写入。参考 [COPY](https://redis.io/docs/latest/commands/copy/) 与 [TIME](https://redis.io/docs/latest/commands/time/) 官方说明。
