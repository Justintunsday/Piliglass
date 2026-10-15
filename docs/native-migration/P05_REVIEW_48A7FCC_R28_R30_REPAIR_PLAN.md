# P05 退修计划：48a7fcc 复审 R28–R30（冷初始化 token/协调准入/单一预算/归因 barrier）

2026-10-15（Asia/Hong_Kong）。Codex 对 `48a7fcc56caaeebf716b187870da207c02361dd1`
独立复审 CHANGES_REQUESTED：R28（延迟冷读结果可覆盖更新后的内存 fence：仅 await 前检查、
无 post-await/初始化 token 校验）、R29（冷 preflight 绕过已接受的 FIFO/backpressure/直接
入口排除，且形成第二份独立 attempt 配额）、R30（聚合重试计数 + 30×5ms 名义窗口不能归因
两个任务，也没有真实 elapsed deadline）。R27 共享 vault/fresh 分离/清理修正与 R23–R26
修复被认定为正面，不重做。依据：
`build/native-migration/review-48a7fcc56caaeebf716b187870da207c02361dd1-codex/REVIEW.md`。
边界不变：shadow-only、四 flag false、不接 authority、不真实账户/设备、不碰 `youtube/`、
不改 UI/不降 264/245/148 基线、180/90 预算、断言/门禁；不预热、不加预算、不 actor-per-writer。

## R28 — 延迟冷读覆盖更新 fence（P1）修复

- 精确现状：`loadRecoveryOnce`（`PiliAccountEnvelopeTransactionStore.swift` 约 282–295）
  只在 `if unresolved == nil, let journal = try await vault.loadRecoveryJournal()` 的
  **await 前**求值 `unresolved == nil`；await 返回后无条件安装并 `recoveryLoaded = true`。
  actor 重入下 L1/L2 都通过前置检查、vault 串行返回同一 journal A 后 L2 的 continuation
  被延迟；L1 安装 A → R 解析清除 → 新 unknown B arm/持久化 → L2 用已捕获的 A 覆盖
  `unresolved`（journal 为 B）。解析 A 时 `staleRecoveryJournal` → fence 挂死、B 不可再
  加载。合规交错要求"vault 已返回、其 operation fence 已释放"，因此延迟必须在 store 侧。
- 修复：`loadRecoveryOnce` 在 vault 读返回后做 **post-await 重验证**：
  `guard !recoveryLoaded, unresolved == nil else { return }`——任何更新的 arm 都以
  完成初始化（loaded=true）为前提，因此延迟结果绝不安装/复活已清除或更新的 evidence；
  严格读错误与取消语义不变（读抛错在重验证前传播、`recoveryLoaded` 保持 false）。
- 测试 seam（review 明确允许，且必须控制真实安装边界）：store 增加
  `recoveryReadDeliveryHook: (@Sendable () async -> Void)?` 与内部 setter，在"读已完成、
  安装之前"被 `await`；生产接线不设置（恒 nil）。测试用 `DeliveryGate` actor（一次性
  suspend/release + `isSuspended` barrier）控制真实安装边界。
- 回归：seed journal A → 冷 owner W1 读 A 后停在 gate（vault fence 已释放）→ 直接
  installer 冷读安装 A（首完成，合法）→ `resolveUnresolvedPublication()` 清除 A →
  直接 unknown 触发 arm B（精确 token）→ 释放 gate → W1 用 stale A 继续：
  post-await 重验证必须返回、**不得**覆盖 B。断言：内存 fence == B 的
  attemptedID/expected/digest/kind；journal == B；`resolveUnresolvedPublication()` 返回
  attempted==B（不是 `staleRecoveryJournal`）并清除；follower 恰好发布一次；A/W1 零发布。

## R29 — 协调冷 preflight 进入 FIFO 生命周期与单一配额（P2）

- 精确现状：`enqueue`（约 339–369）在任何 `writerActive/pendingWrites/maxPendingWrites`
  预留之前 `loadRecoveryIfNeeded()`（自带有界循环）；`executeQueuedWrite`（约 516–543）
  再独立从头计数。结果：冷提交不占容量（maxPendingWrites=1 时 C 仍进 retry 而非 overflow）、
  `pendingWriteCount`/`writeQueueIdle` 不表示等待中的冷提交、同 key 提交顺序 = 独立
  sleep 顺序、直接入口在冷 retry 期间不被排除、一次 queued write 可花两份配额。
- 修复（等价的协调设计，保持既有契约）：
  - `enqueue` **先**预留：`writerActive` 中的新提交按 `pendingWrites < maxPendingWrites`
    计算容量（冷等待者同样计费）并进入 `waitingTurns`；取消 waiter → `passTurn` + 不发布。
  - 冷初始化移入 `executeQueuedWrite` 的**单一重试循环**：`loadRecoveryOnce()` +
    `requireResolvedPublication()` + `performQueuedWrite` 在同一 `attempt` 计数内；
    `PiliAccountEnvelopeStagingError.operationInProgress/staleTransaction` 与 store 级
    `operationInProgress` 共用一个 `maxQueueAttempts`/`retryDelayNanoseconds`（耗尽 →
    `publicationConflict`）——不再有第二份冷配额；同 key 顺序 = 观察到的 enqueue 进入顺序；
    直接入口在 retry back-off 期间仍被 `writerActive && !executingQueuedTurn` 排除。
  - 只读恢复入口（`loadPersistentRecovery`、`resolveUnresolvedPublication`）与直接
    primitives 保留独立的 `loadRecoveryIfNeeded` 有界包装（明确独立政策，不扩张 queued
    预算、不破坏 read-only 入口）。
  - 文档同步：queued write 的冷加载 + 发布共享**同一份**配置配额（不是两份）。
- 回归（新 helper `checkCoordinatedColdAdmission`）：
  1. A/B/C 容量/顺序/直接排除：共享 vault 被暂停发布者占住；A（冷 owner）先在 retry
     barrier（仅 A 一个提交，归因由构造保证）；B 提交后 `waitForPending == 1`（仅 B 一个
     waiter）→ 证明参与；C 立即 typed `writeQueueOverflow`；retry back-off 期间直接入口
     typed store `operationInProgress`、零发布；resume 后 A 先发布（deleteAll）、B 后发布
     （credentials）：A 候选仅含 holder 凭据态、B 候选含两效果（确定性顺序），receipt
     互异、exact count、`writeQueueIdle`。
  2. 混合 preflight+publication 单一预算耗尽：`maxQueueAttempts=2`；attempt1 冷加载被
     暂停发布者争用（sleep#1）；恢复发布者（其 ack 读为 manifest read#1）后，
     `pauseManifestReadAfter(2)` 使 attempt2 的 CAS 比较读（read#3）被暂停 → 中间写入 →
     resume → `staleTransaction` → attempt==max → typed `publicationConflict`；
     `retrySleepCount == 1`（**总配额一份**；旧双循环会得到 2 次 sleep 且不耗尽 → 用例可
     区分）；零发布、无 fence；随后 follower 冷加载（loaded）成功且精确一次。
  3. R28 延迟 stale 交付（见上，含 gate seam）。
  4. 保留 `checkColdRecoveryContention` blocks 2/3（配额耗尽、取消，语义不变）与
     blocks 4/5（pending/corrupt 共享 vault 争用）及既有全部断言。

## R30 — 去除名义窗口，改为身份归因 barrier（P2）

- 删除 `waitForRetrySleepWithin`（不再有"30×5ms 名义 deadline"推断）。
- 首次使用 fixture 重写为 review 建议的形态：**一个真实 recovery owner + 一个已证实的
  admitted waiter**——A 是唯一提交时用 `waitForRetrySleep` 归因其冷加载重试；B 提交后
  用 `waitForPending == 1` 归因其 FIFO 预留；不用聚合计数推断第二个任务，也不再用更长
  back-off 或近似窗口。断言保持精确 effect/receipt/publication。

## R31/R32 修正（详见 `P05_REVIEW_788C11D_R31_R32_REPAIR_PLAN.md`）

- 混合块 CAS 阶段的"外部发布者"改为显式声明的独立 vault actor 对抗性 fixture（与既有
  accepted CAS 测试同模式）；shared vault 只用于冷加载争用，并补真实中间 receipt/pointer
  证据。
- 队列执行所有权改为 task-local token；`requireDirectEntryAllowed()` 在任何冷 IO 前拒绝
  直接 outsider（两个 public shape），新增冷执行窗口回归；R28 回归改为合法只读
  `loadPersistentRecovery` 延迟调用者，不再依赖 queued owner 下的 direct 写。

## 顺序与验收

- 先保存本计划 → 修 source（R28/R29）→ driver（R30 + 新回归）→ 文档 → 静态检查 →
  小 commit/push；读取在途 48a7fcc/2599af8 runs（不重跑、不取消自证）→ reconcile 后新
  最终代码 SHA 显式 dispatch `ios.yml`+`ios-home-preview.yml` → 实际九 outcome/artifacts/
  hashes/计数/strict/BUILD/FFmpeg/preview → 交 Codex 独立复审。不得自审 PASS、不得升级
  authority、不得声称 B2e-2/3/whole P05 完成。
