# P05 退修计划：788c11d 复审 R31/R32（混合争用 fixture / 队列执行所有权）

2026-10-15（Asia/Hong_Kong）。Codex 对 `788c11db7ffff6d473b87b086edcc5d4e492c493`
独立复审 CHANGES_REQUESTED：R31（混合预算 fixture 的中间写入无法执行）、R32
（`executingQueuedTurn` 是全局许可而非调用者所有权）。R28 post-await 重验证、R29
FIFO 预留/单一 attempt 循环、R30 owner/waiter 归因被认定为实质正面，不重做。依据：
`build/native-migration/review-788c11db7ffff6d473b87b086edcc5d4e492c493-codex/REVIEW.md`。
边界不变：shadow-only、四 flag false、不接 authority、不真实账户/设备、不碰 `youtube/`、
不改 UI、不降 264/245/148 基线、180/90 预算与断言/门禁；不引入 production
actor-per-writer、不加预算、不弱化断言。

## R31 — 混合争用 fixture：中间写入必须真实执行（P1）

- 精确现状（`tool/check_native_account_envelope_queue.swift` 混合块，约 1397–1435）：
  holder8 与 mixed8 **共用 vault8**；mixed8 的 CAS 比较读被 `pauseManifestReadAfter(2)`
  暂停时，`vault8.operationInProgress` 仍被 mixed8 的 `publishShadow` 持有（defer 未执行），
  因此 `holder8.applyCredentials` 的 `vault8.beginOperation` 直接抛 `operationInProgress` →
  中间写入从未发生、stale 路径未被触达 → catch 退出。这是文档化 fence 的确定性结果，与
  R27（独立 vault 却期望争用）正好相反。
- 修复（沿用既有 accepted CAS 测试的模式，并显式声明为对抗性 fixture）：共享 vault8 只用于
  **冷加载争用**；CAS 阶段的"外部发布者"改为**独立的 out-of-contract vault actor**
  （`PiliAccountEnvelopeStagingStore(secrets: fault8)` 的新实例 = 对抗性外部发布者，
  显式注释声明它不是 production actor-per-writer 组合）。中间写入经该独立 vault 的
  direct `applyCredentials` 真实发布；随后 resume CAS 读 → mixed8 读到新指针 →
  `staleTransaction` → attempt==max → typed `publicationConflict`。
- 保留 `maxQueueAttempts=2`、`retrySleepCount==1`（一份总配额）、零发布/无 fence、
  follower 精确一次；新增**真实中间写入的 receipt/pointer 证据**：
  `interveningReceipt8.transactionID` 与其候选 accessKey=="mixed-intervening"、
  exhausted 后当前 pointer == interveningReceipt8.transactionID、recordCount 精确。

## R32 — 队列执行所有权必须 task-specific（P1）

- 精确现状：`executeQueuedWrite`（约 551–553）在任何 await 之前把 actor 级
  `executingQueuedTurn = true`；`beginOperation`（1256）用
  `!writerActive || executingQueuedTurn`——**任何** outsider 任务在 queued owner 的
  冷加载/交付 await 窗口内都能通过该布尔值并发布（writerActive 被 owner 预留）。冷加载
  前不持有 store operation fence，因此 outsider 可在外泄窗口内执行写事务。旧的 R28
  fixture（staleWrite9 的两次 direct `applyCredentials`，其中一次直接发布 B）正是该违
  规的见证；现有唯一 direct 排除测试（warm7）只覆盖 back-off 窗口
  （`executingQueuedTurn=false`），没有覆盖冷执行窗口。
- 修复（task-specific 私有所有权，不改变队列自身调用）：
  - 删除全局 `executingQueuedTurn`；新增 `@TaskLocal private static var
    queuedWriteExecution = false`。
  - `executeQueuedWrite` 用
    `try await Self.$queuedWriteExecution.withValue(true) { loadRecoveryOnce; requireResolvedPublication;
    performQueuedWrite }` 包裹其整次 attempt——只有队列自身的调用链携带该 token；
    await 期间 token 随任务传播、不泄漏给其他任务。
  - `beginOperation`：`guard !writerActive || Self.queuedWriteExecution else { throw
    store .operationInProgress }`（保留既有 operation fence 与 fence 检查顺序）。
  - 新增 `requireDirectEntryAllowed()`（opInProgress + writer/token 两个 guard，无 await）
    并置于六个直接入口的 `loadRecoveryIfNeeded()` **之前**（adoptMissingIdentities、
    applyInstall、applyDelete、applyImport、applyBuvidSeed、transaction 共享助手）：
    outsider 在**任何冷 shared-vault IO 之前**即被 typed 拒绝；`beginOperation` 在
    load 之后仍做完整复核（"before IO + after-await revalidate"）。
  - 只读恢复入口（`loadPersistentRecovery`、`resolveUnresolvedPublication`）不受
    writer/token 限制（read-only recovery 政策不变）。
- 回归（新冷窗口用例 + R28 改造，均确定性）：
  1. **cold-window outsider rejection**：用交付 gate 把 queued owner 悬停在真实冷加载
     安装边界（writerActive=true、vault 已释放）；outsider 两种 public shape
     （`applyCredentials` 与 `applyDelete`）都必须 typed `.operationInProgress`、
     pointer/journal/recordCount 完全不变、`retrySleepCount==0`（非争用路径）；admitted
     follower 随后与 owner 一起正常完成（owner 先、follower 后，精确计数）。
  2. **R28 改造为合法只读 outstanding initializer**：交付 gate 悬停
     `loadPersistentRecovery()`（只读，不占 writer 角色）；第二个只读调用完成安装 A →
     `resolveUnresolvedPublication()` 清除 A → **合法 queued** unknown B arm/持久化 →
     释放 gate → 延迟只读调用返回并必须报告**更新的 B**（post-await 重验证），
     B 的 exact token/journal 存活且可独立解析、零重放、follower 精确一次；
     不再依赖 queued owner 下的 direct 写。
  3. 既有 blocks（warm back-off、容量/取消、共享 vault 争用、paused/fresh reopen）
     全部保留；`maxQueueAttempts=2` 混合块保留上述单一配额断言。

## 验收

- 先保存本计划 → 修 source（R32 token/pre-check/文档）→ driver（R31 fixture + R32/R28
  回归）→ 文档 → 静态检查 → 小 commit/push；读取在途 48a7fcc runs（不重跑/不取消自证）
  → reconcile 后新最终代码 SHA 显式 dispatch `ios.yml`+`ios-home-preview.yml` → 实际
  九 outcome/artifacts/hashes/计数/strict/BUILD/FFmpeg/preview → 交 Codex 独立复审。
  不得自审 PASS、不得升级 authority、不得声称 B2e-2/3/whole P05 完成。
