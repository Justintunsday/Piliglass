# P05 Block 2 / B2a：持久用途双账户 durable transaction（Native shadow）

2026-10-10（Asia/Hong_Kong）。前置：Block 1 的 B1a/B1b/部分 B1c 已实现（
[P05_WRITE_BARRIER_PLAN.md](P05_WRITE_BARRIER_PLAN.md)、
[P05_SELECTION_BARRIER_PLAN.md](P05_SELECTION_BARRIER_PLAN.md)、
[P05_READER_WRITER_INVENTORY.md](P05_READER_WRITER_INVENTORY.md)），同 SHA 验收以
CI 为准。本文件是实施前计划；本组只做 Block 2 的第一个切片。

## 现状盘点（代码事实）

- `PiliAccountEnvelopeTransactionStore`（actor，`ios/Runner/Native/Persistence/Accounts/`）
  已实现 shadow 单账户 durable transaction：`applyCookieSave/Delete/DeleteAll`、
  `applyTemporarySelection`、`applyCredentials`、`applyActivated`。每次事务：
  `beginOperation` fence → `vault.loadShadowSnapshot` → 按 `recordKeyUnits` 找唯一
  login record（`generation == expectedGeneration`）→ transform → 全量
  `validated(limits:)` → `vault.importShadow(..., expectedTransactionID:)` CAS 发布；
  receipt 中 `nativeWritesAllowed/authoritySwitchAllowed` 恒 false。
- 缺：**持久用途变更**（Dart `Accounts.set` 的双账户 type add/remove 语义）没有
  durable transaction；目前 shadow 只有临时选择（`applyTemporarySelection` 不写
  `persistedPurposes`）。
- Dart 权威仍是 `Accounts`；本组不接 authority、不产生 durable identity。

## 契约（B2a）

新增 `applyPurposeChange`（双记录原子事务）：

- 输入：`selectedKeyUnits` + `expectedGeneration`、`purpose`、可选
  `previousKeyUnits`（同一 purpose 的原持有记录）；语义对齐 Dart `set`：
  - selected 的 `persistedPurposes` 加入 purpose（已存在则幂等）；
  - previous（若给定且存在且含该 purpose）的 `persistedPurposes` 移除 purpose；
  - `selections[purpose]` 指向 selected.record；history 仍按原策略重算
    （heartbeat 登录则 heartbeat，否则 slot0）；
  - 其余 record、storedOrder/ownerOrder、generation、revision 不变。
- 校验：两个 key 都必须 `record > 0` 且 `isLogin` 且 generation 匹配；unknown/stale
  使用现有错误枚举；candidate 必须通过共享累计 ledger；发布必须 CAS（vault 侧
  `expectedTransactionID`）；`beginOperation` 重入返回 `operationInProgress`。
- receipt 保持 `nativeWritesAllowed=false`、`authoritySwitchAllowed=false`。
- 除 `persistedPurposes`/`selections`/`history` 外不得改任何字段；不得触碰 jar。

## 测试（扩展 `tool/check_native_account_envelope_transaction.swift`）

1. add-from-none：原来无持有者 → selected 获得 purpose，selections 更新。
2. move A→B：A 与 B 同一 candidate 内原子变更，恰好一个持有者，失败时不发布。
3. remove：previous 指定、selected 与原持有者为同一记录的去重/幂等路径。
4. 重复应用同一变更幂等（persistedPurposes 不重复、状态不变）。
5. stale generation（previous 或 selected）拒绝且 vault 指针不变。
6. unknown record key 拒绝。
7. 累计预算超限拒绝（共享 ledger 与事务 store 同 limits）。
8. CAS：读取后 vault 被其它事务推进 → 发布失败、无半写。
9. operationInProgress：重入调用立即拒绝。
10. 保留既有 35 项 transaction checks 全过。

## 验收与边界

- 小 commit + push；同 SHA dispatch release5+preview4；读 `transaction-result.log`
  实际计数、Swift6 strict compile、九个 outcome、BUILD SUCCEEDED/109.1MB/FFmpeg。
- 本组不做 install/import/delete/buvid durable transaction、durable record identity、
  账号级队列与生产 composition；不改 Dart authority；四 flag 保持 false。
