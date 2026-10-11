# P05 Block 2 / B2c：durable delete 与 import 事务（shadow）

2026-10-11（Asia/Hong_Kong）。前置：B2b 已在 `1aa3513` 验收（release 38136462609 /
preview 38136464878；envelope 109/44/40/101/51；账户 +239）。本文件是实施前计划，
不改动已验收结论。本组只做 shadow 组件：不接 authority、不产生生产 caller、不做 buvid
补值 durable transaction、不做账号级队列；四能力 flag 保持 false。

## 分片与顺序

同一组内先 delete（结构更简单），后 import（复用 install 的输入结构与身份政策）。

## 与 Dart 现有语义的逐条对照

| 项 | Dart 现状（`Accounts.deleteAll` / `LoginAccount.delete`） | B2c shadow 政策 |
|---|---|---|
| 删除对象 | 仅 login owner；匿名不可删 | 仅 index>0 的 login record；key 查不到即 `unknownRecordKey` |
| 记录序号 | Hive box 剩余 key 保持相对顺序 | 删除后后续 record 重编号，保持 `records[i].record == i` |
| storedOrder | box 删除后剩余 key 相对顺序不变 | 移除条目并重编号（`entry.record == offset+1`） |
| ownerOrder | `_owners` 删除后剩余 owner 相对顺序不变 | 同上移除并重编号 |
| selections | 指向被删账号的槽位置为匿名（index 0） | 槽位：== d → 0；> d → −1；< d 不变 |
| history | 由 heartbeat 槽是否登录推导 | 删除后按同一策略重算：`records[selections[1]].isLogin ? 1 : selections[0]` |
| identity | 无 | 剩余 record 的 identity 原样保留（重编号不改身份） |
| 删除匿名 | 不允许 | 匿名 key 为 nil，无法匹配；空 key → `unknownRecordKey` |
| generation | 请求状态代际，删除要求当前 | `expectedGeneration` 必须匹配否则 `staleGeneration` |

| 项 | Dart 现状（`Accounts.importCredentials`） | B2c shadow 政策 |
|---|---|---|
| 输入 | `Map<key, LoginAccount>`，key 必须等于 storageKey | `[PiliAccountShadowInstall]`（每项自带 storageKey），key 唯一且非空 |
| 同 key 替换 | `box.putAll` 覆盖同 key 值，位置不变；`_beginInstall` 替换 mode 槽指向 | 同 key：原位替换字段（generation/credentials/purposes/activated/jar），**保留原 identity**，顺序不变 |
| 新 key | box 末尾追加；owner 追加；mode 槽不变 | 末尾追加 record + storedOrder/ownerOrder 条目，铸发 identity；selections/history 不变 |
| 用途 | 导入值自带 type（`preserveTypes:false`） | 直接采用输入 `persistedPurposes` |
| 部分写入 | 任一候选不合法整体抛出 | 单 candidate 原子发布；任何拒绝零发布 |
| 重复 key / key≠storageKey | ArgumentError / 拒绝 | 输入内重复 key → `duplicateRecordKey`；空 key / 重复 purpose → `invalidImport` |
| generation | 新对象由 `_completeInstall` 激活新代际 | 输入 generation 必须 >0、输入内唯一且未被未替换记录占用，否则 `staleGeneration` |
| 上限/预算 | Hive 与 envelope 上限 | ≤256 records；共享累计 ledger 越界 → `resourceLimit` |
| 升级前置 | 无 | 仅 schema 3；schema 2 → `invalidImport`（先 adopt） |

delete 前置同为 schema 3，schema 2 → `invalidDelete`。

## 实现边界

- `PiliAccountEnvelopeTransactionStore`：
  - `applyDelete(recordKeyUnits:expectedGeneration:) -> PiliAccountShadowTransactionReceipt`
    （receipt.record = 被删记录的旧序号）。
  - `applyImport([PiliAccountShadowInstall]) -> PiliAccountShadowImportReceipt`
    （`transactionID`、`replaced`、`appended`、两门恒 false）。
  - 复用 `beginOperation`、共享 ledger、`vault.importShadow(expectedTransactionID:)`。
- 新增错误：`invalidDelete`、`invalidImport`；重复 key 用现有 `duplicateRecordKey`；
  generation 用现有 `staleGeneration`。
- 不改 Dart 生产/测试；不新增 Swift 依赖；不触碰 `youtube/`。

## 测试矩阵（driver，计数只增不减）

Delete：
1. 删末尾 login record：count−1、orders 移除、指向它的槽 → 0、identity 保留。
2. 删中间 record（含被 purpose 槽/心跳槽指向）：后续 record 重编号且 `record == 序号`、
   orders 重编号、槽位 −1/归 0、history 按策略重算。
3. 删到只剩匿名：orders 为空、selections 全 0、history 0、仍可通过 validated。
4. 拒绝：unknown key（含空 key）、stale generation、schema 2（`invalidDelete`）、
   paused 重入 `operationInProgress`；全部零发布、指针身份不变。
5. 真实 Keychain close/reopen：剩余记录、identity 与 orders 稳定。

Import：
6. 纯新增：末尾追加、identity 铸发、orders 追加、selections/history 不变。
7. 纯替换：原位、identity 保留、orders 与槽不变、generation 更新。
8. 混合：既有 key 替换 + 新 key 追加；同 candidate；close/reopen 稳定。
9. 拒绝：输入重复 key、空 key、重复 purpose、重复 generation（输入内/与未替换记录）、
   超预算 credentials、schema 2（`invalidImport`）、paused 重入；零发布。
10. 保留既有全部 checks（envelope 109/44/40、transaction 101、authority 51），计数只增。

## 验收与停止边界

- 小 commit + push；组末同 SHA 显式 dispatch `ios.yml` + `ios-home-preview.yml`；读实际
  artifacts：账户实际测试数、envelope 109/44/40/101/51（只增不减）、九强制 outcome、
  BUILD SUCCEEDED/109.1MB/FFmpeg、preview 20 tests。失败读日志修复→提交推送→重跑；
  preview 慢 runner 阶段超时先区分代码回归与 runner 超时，不放宽断言、不跳过阶段。
- 通过后更新 PROGRESS/STATUS_MATRIX/本计划并交交付报告。
- 本组不做 buvid 补值事务、不做账号级队列、不接 authority、无生产 caller；不改 Dart
  authority；四 flag false。
