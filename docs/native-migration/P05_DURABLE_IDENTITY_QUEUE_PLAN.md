# P05 Block 2 / B2e：durable identity 消费、账号写入队列与 receipt/unknown 语义

2026-10-12（Asia/Hong_Kong，复审后重写）。**当前基线：验证代码 `672e216`（transaction
driver 245 checks；release 38188706831 / preview 38188709339 双 CI 5+4，Codex 已对该
有限退修组 PASS）**。上一版本文件写的"B2d 已在 `9724ddb` 验收 / 178 checks"是过时前置，
已更正；当时承诺的"账号级排队"与"完整 durable 消费者"也不能由
`operationInProgress` 拒绝或单加 receipt 标签/`lookup` 代替。四能力 flag 保持 false；
不接 authority；本组只做 shadow。

数据与发布约束（沿用已验收组件，不改语义）：strict codec + 共享累计 ledger；schema 3 的
`generationHighWater` 单调且任何发布都持久化变换前有效水位；单一 vault actor 是唯一
发布者（一个 Keychain namespace 一个 vault 实例，见
`PiliAccountEnvelopeStagingStore` 文档），vault 以 `operationInProgress` fence + CAS
`expectedTransactionID` + 写后读回保护发布；`publicationUnknown` 表示"是否已发布未知"，
**任何重试前必须先读回判定，禁止把 unknown 当未写重放，禁止盲目再次 seed/import**。

## 1. 子组划分（依赖顺序）

- **B2e-1（本组，实施中）**：
  a. receipt 身份：单记录事务（cookie save/delete/deleteAll、temporary selection、
     purpose、credentials、activated）与 buvid receipt 携带目标记录的
     `durableIdentity`；install 携带新铸身份；delete 携带被删记录身份；import 按输入
     顺序携带结果身份（替换保留旧身份、新追加铸新身份）；adopt 携带本次铸造的身份列表。
  b. 只读消费：`lookupRecord(durableIdentity:)`（纯读、未命中 nil、不 activate/写）与
     store 级 `loadShadowSnapshot()` 透传（配合 vault transactionID 做跨重启核对）。
  c. 真实账号写入队列：store 内**有界全局 FIFO**（单发布者），`enqueue(_:)` 接受
     `PiliAccountShadowQueuedWrite`（cookie/purpose/credentials/activated/buvid/install/
     import/delete/adopt 全事务）并返回 tagged `PiliAccountShadowWriteOutcome`；队满立即
     `writeQueueOverflow`（丢弃即拒绝，不静默），取消（排队中/发布前）不得发布，队列
     必须继续排空；每次尝试都基于**新快照**重校验 key+generation（同 key 顺序 = 提交
     顺序；不同 key 无丢更新）。
  d. 竞争与 CAS：同 store FIFO 串行、store 级 fence 拒绝直接并发入口；跨 store（共享
     同一 vault actor）以有界重试吞并 `operationInProgress`/`staleTransaction`，重试
     基于新快照重新变换（无丢更新），重试耗尽 → `publicationConflict`（不伪成功）。
  e. unknown 结果 fence：`publicationUnknown` 原样上抛且**不自动重试**；后续队列项从
     读回后的持久真值继续；恢复判定 = `loadShadowSnapshot`/`lookupRecord` 读回核对
     （写后错误=已发布、写前错误=未发布），并提供"再次提交同请求必须被既有身份/代际
     拒绝（如 duplicateRecordKey/已存在 no-op）"的测试，证明未把 unknown 当未写。
  f. 测试矩阵（driver，真实 Keychain staging + 受控 fault vault）：receipt 身份与
     lookup 命中/未命中/不改变指针；同 key FIFO（后项快照包含前项）；不同 key 双效应；
     队满溢出零副作用；排队中取消、发布前取消（不发布且队列继续）；queue-unknown
     （install + buvid：上抛、读回、重放被拒/no-op）；跨 store fence 竞争（重试后两效应
     都在）；CAS `staleTransaction` 干预（第二 vault 实例介入发布后，队列项重试并保留
     干预效应）；delete 重编号后按身份寻址；import 代际替换后旧代际拒绝/新代际成功；
     reopen 后队列可用；预算拒绝后队列继续释放（不泄漏 turn）；generation 溢出沿用
     R11 用例。
- **B2e-2（下一组）**：unknown 的**持久恢复面**（identity 读回 + 消费方：snapshot
  bridge / reverse import 的 identity 对齐）与队列在其余写路径的接线；buvid/install/
  import 的 unknown 语义补测。依赖 B2e-1 的 outcome/identity 不变量。
- **B2e-3（随 Block 3 composition）**：生产调用方统一改走队列（一个 namespace 一个
  vault/store 实例）、handoff/revert 期间的冻结-排空-未知恢复策略、GC 引用安全。**在
  B2e-3 完成前不得宣称"账号级队列已接入生产"**；Block 2 的完成声明必须保留此边界。
- **保留项（生产 composition 前闭合/精确限制，独立于 B2e-1）**：
  ① `boundCsrf`/`boundAccessKey` 的 tagged 区分（未安装 / 已有 stamp 被 reader 拒绝 /
  合法 nullable）与真实消费者盘点；`csrfOf` 旧兼容 fallback 不是 fail-closed reader，
  被拒上下文不得恢复成直接凭据；保留显式无 stamp 旧兼容路径，不改无关 UI/端点行为。
  ② purpose CAS 的**读→变换→发布竞争**定向用例（真实暂停发布、竞争发布后拒绝/零
  副作用），不是通用 staging CAS 例子。两者按依赖排在 B2e-2/B2e-3 前完成（② 随
  purpose 队列/竞争测试一并落）。

## 2. 队列契约（B2e-1 精确语义）

- `enqueue(_:)`：无在途且无等待 → 立即执行；否则入 FIFO（上限
  `maxPendingWrites`，默认 32；测试用小值）；队满 → `writeQueueOverflow`（不接收）。
- 排队项被取消（Task.cancel）：轮到它时 `CancellationError`，`passTurn` 继续，后续项
  不受影响；执行中取消沿用 vault 的发布前 `checkCancellation`（未写指针则丢弃孤儿
  record/descriptor 并抛 `CancellationError`），已发布则不得回滚（未知按读回判定）。
- 每次尝试（含重试）都重新 `loadShadowSnapshot` 并重校验 key+generation；`staleTransaction`
  与 vault `operationInProgress` 有界重试（默认 40 次 × 25ms），耗尽
  `publicationConflict`；其余错误（含 `resourceLimit`、`staleGeneration`、
  `publicationUnknown`）立即上抛，释放 turn。
- 单发布者不变：队列不并行发布，不引入多写者；跨 store 正确性由 CAS + 重试保证。

## 3. 验收流程

- 小 commit（计划 → 队列/receipt → driver 测试 → 文档），push；同最终代码 SHA 显式
  dispatch `ios.yml` + `ios-home-preview.yml`；读真实 logs/artifacts：账户 strict
  分析/测试计数只增、envelope 109/44/40/N/51、九强制 outcome、BUILD
  SUCCEEDED/109.1MB/FFmpeg、preview 20/`failures=[]`、source/golden hash。
- 通过后交 Codex 独立复审（不自审 PASS）；未通过不进入下一组、不升级 authority。
- 边界：四 flag false；保留 Dart fallback 与 Aether 独立；不改 UI 视觉、不碰
  `youtube/`、不操作真实账户/认证/验证码；未知写不重放；不降断言/预算/门禁。
