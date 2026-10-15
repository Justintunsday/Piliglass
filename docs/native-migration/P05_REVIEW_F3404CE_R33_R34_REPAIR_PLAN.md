# P05 退修计划：f3404ce R33/R34（direct primitive fail-fast / 零 IO 断言记账）

2026-10-15（Asia/Hong_Kong）。Codex 对 `f3404ce122652f8ccac5a4aeca4f880eab703d93`
独立复审 CHANGES_REQUESTED：R33（直连原语被改成队列式重试，实际前驱 artifact 已证明
fatal）、R34（冷窗口零 IO 断言把测试自身校验读计入计数器）。R31/R32/R28 修正被认定为
实质正面，不重做。依据：
`build/native-migration/review-f3404ce122652f8ccac5a4aeca4f880eab703d93-codex/REVIEW.md`
与 `review-788c11db7ffff6d473b87b086edcc5d4e492c493-codex/REVIEW.md` 的 Additional R33。
边界不变：shadow-only、四 flag false、不接 authority、不真实账户/设备、不碰 `youtube/`、
不改 UI、不降 264/245/148 基线、180/90 预算与断言/门禁；不预热、不改旧 catch、不删测试、
不加预算。

## R33 — 直连 primitive 保持既有 fail-fast 语义（P1，实际前驱失败）

- 实际证据：Codex 独立下载 48a7fcc native artifact **11991135966**（sourceSHA=workflowSHA
  48a7fcc，status FAILED）；`transaction-result.log` fatal
  `PiliAccountShadowTransactionError.publicationConflict`，queue 阶段未执行；既有
  109native/44negative/40staging 通过，245 transaction/148 queue 均未获执行。
- 精确源码路径：`tool/check_native_account_envelope_transaction.swift` 295–304：
  `fencedStore` 的发布被暂停时，新建 **COLD** `competingStore`（同一 `fencedOuter`）
  调 direct `applyCredentials`，既有契约要求立即抛
  `PiliAccountEnvelopeStagingError.operationInProgress`（vault 级）。自 R26 起，所有
  direct primitive 先走 bounded `loadRecoveryIfNeeded`：其 journal 读撞上被持有的 vault
  fence → 40 次重试 → `publicationConflict`；旧 catch 不匹配 → driver fatal。
- 修复（恢复既有语义、权限分层精确）：
  - 六个 direct 写入入口（adoptMissingIdentities、applyInstall、applyDelete、
    applyImport、applyBuvidSeed、transaction 共享助手）把 `loadRecoveryIfNeeded()` 换成
    **单次 `loadRecoveryOnce()`**：vault `operationInProgress` 立即按原样外泄（fail-fast），
    corrupt/读失败同样 immediate fail-closed；不重试、不产生新终态错误。
  - queued 写入的重试配额保持在 `executeQueuedWrite` 的**单一**循环内（R29，不变）；
    `performQueuedWrite` → op 函数里的单次 `loadRecoveryOnce()` 在已加载时是 no-op，
    不新增配额。
  - `loadRecoveryIfNeeded`（bounded wrapper）只保留给**只读恢复入口**
    （`loadPersistentRecovery`、`resolveUnresolvedPublication`），文档明确该分离政策。
  - `requireDirectEntryAllowed()`（R32，本地 store 所有权前置检查）保持在最前，与 R33 的
    vault fail-fast 叠加：本地队列窗口 → typed store `operationInProgress`；跨 store 共享
    vault 忙 → typed staging `operationInProgress`。
- 回归：既有 transaction driver 295–304 原样保留（不改 catch/不预热/不删测试）；
  在 queue driver 新块中补"fresh competing store 跨 store 直连争用"覆盖多个 public
  shape（credentials + delete）：exact staging `operationInProgress`、零效果
  （pointer/journal/recordCount 不变）、resume 后同一 competing store 的 follower 恢复并
  精确发布一次。queue 计数只增不减；transaction 245 以实际 CI 证据为准。

## R34 — 零 journal-IO 断言的记账修正（P2）

- 精确现状：新冷窗口块在两次 outsider 拒绝后先调 `vault10.loadRecoveryJournal()` 校验，
  再取 `windowReadsAfter = fault10.journalReadCount()`；`loadRecoveryJournal` 自身就是一次
  journal 读（计数器 diff 每个 journal 读都 +1），因此即使 outsider 零 IO，
  `windowReadsAfter == windowReads` 也必然为 false。
- 修复：**先**取 `windowReadsAfter`（紧跟 outsider 之后、任何校验读之前）并断言
  `windowReadsAfter == windowReads`（零 outsider IO）；**再**独立做 journal/pointer/
  recordCount 校验。所有既有断言（两个 typed 拒绝、journal/pointer/计数不变、owner 先行
  follower 精确一次、`retrySleepCount == 0`）保留；不抑制计数、不删检查、不放宽不等式、
  不预热。

## 验收

- 先保存本计划 → 修 source（R33）→ driver（R34 + 直连争用新块）→ 文档 → 静态检查 →
  小 commit/push；reconcile Actions（48a7fcc release COMPLETED FAILURE / preview SUCCESS，
  2599af8 已 cancelled，均保留；无在途 run 需要等待）→ 新最终代码 SHA 显式 dispatch
  BOTH `ios.yml`+`ios-home-preview.yml` → 实际九 outcome/artifacts/hashes/计数/strict/
  BUILD/FFmpeg/preview（transaction core+identity 合计 ≥245 后才谈 queue 执行）→ 交 Codex
  独立复审。不得自审 PASS、不得升级 authority、不得声称 B2e-2/3/whole P05 完成。
