# P05 退修计划：a4f6bb6 复审 R13–R18（queue/unknown/receipt 语义）

2026-10-12（Asia/Hong_Kong）。Codex 对 `a4f6bb6`（及 `4944557`/`c007c8c`）独立复审为
**CHANGES_REQUESTED**：结构拆分把 queue 编译移出 transaction driver 是合法降载，但
R13 unknown fence、R14 unknownA/B 顺序、R15 队列失败/CAS/receipt 覆盖、R16 直接入口
策略、R17 实际 golden 的 activated 基线、R18 A/C immutable candidate 断言均未闭合。
依据：`build/native-migration/review-a4f6bb6473f495a8e6f7159afce8485d975f3fcd-codex/REVIEW.md`、
`review-c007c8c6d58685025bbf128683449ae416afd302-codex/REVIEW.md`、
`review-494455724a0b5aca2d5b24959ec6028e387a3fb8-codex/REVIEW.md`、
`build/native-migration/codex-review-53aed63/REVIEW.md`。

基线更正：本地 HEAD 现为 `33d1922`（用户侧提交：overflow 改用
`.credentials(queue-overflow)`、取消 follower 改用 `.credentials(queue-follower)`，并删除
了 `activated == false` 断言）。本计划保留该“可观察 witness”思路，但按 R17 重新补回
**显式**基线断言，不删除/不弱化任何断言。

范围边界不变：四能力 flag false、不接 authority、不改 Dart/Flutter fallback、不碰
`youtube/`、不改 UI；未知写不重放、不伪造 receipt；不降 180/90 预算、严格 Swift 6、
基线的 245 transaction checks 与 queue 阈值只增不减。本组只处理 B2e-1 shadow queue；
生产 composition 接线仍是 B2e-3（未接受前不得声称账号级队列已接入生产）。

## R13（P1）：publicationUnknown 的 fail-closed 未决发布 fence 与读回 resolution

- 现状：`enqueue` 的 catch 一律 `passTurn`，`publicationUnknown` 与其他错误一样只上
  抛；后续同 key follower 立即从新快照发布，可抹掉前一 unknown 的 reconciliation 证据。
- 生产修复（`PiliAccountEnvelopeTransactionStore`）：
  1. 所有发布统一经私有 `publishCandidate(candidate, expectedTransactionID, kind)`：
     vault `publicationUnknown` 时先记录 **immutable 未决记录**再原样上抛：
     `{expectedPreviousTransactionID, attemptedCandidateSHA256, kind}`。
     `attemptedCandidateSHA256` = 实际提交字节（codec 规范化 encode）的 SHA-256，
     与 vault manifest 的 `sha256` 同域，是候选身份关联而非“payload 语义猜成功”。
  2. 未决期间 **fail closed**：`enqueue` 入口、等待者获得 turn 后、以及所有直接
     public 写入口（`beginOperation`）在 fence 未清时抛
     `PiliAccountShadowTransactionError.unresolvedPublication`；只读
     `loadShadowSnapshot`/`lookupRecord` 保持可用作读回。
  3. `resolveUnresolvedPublication()`（唯一清除口）：读回当前 manifest，
     返回 `{expectedPreviousTransactionID, attemptedCandidateSHA256,
     observedTransactionID, observedCandidateSHA256, observedMatchedAttempt}`；
     读回失败则 fence 保持且错误上抛。它不重放、不为 unknown 生成写 receipt。
  4. 持久恢复面（跨进程 fence、启动 recovery）明确留给 B2e-2：本组只保证
     **同进程 fail-closed 且证据不先于 resolution 被 follower 覆盖**；文档不得宣称
     已持久化未决记录。reopen 后 vault 指针本身一致，任何新写仍从新快照 CAS，
     不构成丢更新。
- 测试（queue driver，fault vault）：
  - 同 key overwriting follower：unknown 后 follower 抛 `unresolvedPublication`，
    记录数/指针不变；`resolve` 后 follower 才发布。
  - write-before-error + unreadable ack（pointer 写前抛 + ack 读失败）：
    unknown 上抛、fence 记录；resolution `observedMatchedAttempt == false`
    （指针仍是变换前候选）；随后显式重试才发布（读回判定后的调用者决策）。
  - write-after-error + unreadable ack（pointer 写已提交后失败 + ack 读失败）：
    resolution `observedMatchedAttempt == true` 且 observed==该候选；不重放。
  - persistent read-back failure：读回持续失败时 `resolve` 上抛、fence 保持、
    新写仍 fail closed；恢复读回后 `resolve` 成功、队列继续。
  - reopen/recovery 边界：原 store 仍 fail closed；新 store（同 secrets）读回当前
    指针后从其 CAS 继续，不重放 unknown。
  - 不重放：landed unknown install 重提交 → `duplicateRecordKey`；
    buvid unknown → resolution 后重提交为真实 no-op（`transactionID == nil`）。

## R14（P2）：unknownA/unknownB 与取消等待者的显式 admission 屏障

- `checkQueuedFifoFaults`：unknownA 先 `pauseWrite` 并 `waitUntilPaused`（已 admitted
  且停在发布前），再创建 unknownB 并 `waitForPending(store,1)`；resume 后 A 消费
  `.pointerReadAfter` fault 产生 unknown，B 在 fence 下 fail closed。不再依赖 Task 创建
  顺序，不加 sleep、不删断言。B/C 与取消等待者已有 `waitForPending` 屏障保留。

## R15（P2）：队列失败释放、purpose 竞争与 receipt 身份覆盖

- 队列 `resourceLimit` 后跟随合法写：enqueue 超长 `buvidSeed`
  （`buvidMaximumValueUnits + 1`）→ `resourceLimit`；断言指针/envelope 逐字节不变、
  无 receipt、turn 释放；随后合法 `.credentials` 发布且 receipt 身份正确；
  vault record 计数精确 +6（base+adopt+A/B/C+follower）。
- 有界竞争/maxQueueAttempts 耗尽：`maxQueueAttempts = 3` 的 store 对同一 vault
  连续 3 次在 load→publish 间插入第二 store 发布（`pauseManifestReadAfter(1)` 精确
  卡在 publish 读）→ 第 3 次抛 `publicationConflict`（无 receipt、零发布、指针仍是
  最后一次干预候选）；随后同一 store 的合法 follower 正常发布。
- 直接入口与 retry 协调（同时覆盖 R16）：`maxQueueAttempts = 50`、retry 1s 的 store
  第一次尝试被 stale 干预后，在 retry back-off 窗口内直接 `applyCredentials` 必须
  抛 `operationInProgress`，且该直接写未发布；queued 重试按新快照重新变换成功后，
  最终效应与计数精确。
- 真实 queued purpose 读→变换→发布竞争：queued `.purposeChange` 发布读被暂停时，
  第二 store 插入 credentials/import 发布；resume → `staleTransaction` 有界重试 →
  **重新读快照重算**：干预效应保留、purpose 移动语义（选中者 append、指定 previous
  持有者移除、slot/history）正确、receipt 携带目标 identity；previous 持有者被干预
  失效（generation 替换）时重试必须 `staleGeneration` 拒绝且零副作用。
  不引入全局 purpose 唯一性（保留 legacy import 重复 purpose 兼容）。
- receipt 身份：queued temporarySelection/activated/buvid 的 receipt 必须携带目标
  durable identity、gates false、typed 语义确切（activated 取反基线、buvid 先清空
  jar 保证真实 seed）；purpose 在竞争用例内覆盖。

## R16（P2）：真实协调入口策略

- 生产修复：`beginOperation` 除 `operationInProgress` 外，还必须拒绝
  `writerActive && !executingQueuedTurn`（queued turn 执行中/retry back-off/预约等待者
  期间）的直接 public 入口 → `operationInProgress`；queued 执行自身以
  `executingQueuedTurn` 只包住每次 attempt 的实际执行（不含 back-off 睡眠），
  不改变 fence 语义。文档明确：直接 API = 仅空闲期 legacy/primitive 入口，不参与
  FIFO 排序；生产 composition（B2e-3）统一走 `enqueue`。
- 回归：见 R15 第二/第三条（retry 窗口直接入口被拒 + 无发布）。

## R17（P2）：实际 golden 的 activated 基线与可判别断言

- 保留用户 `33d1922` 的 credentials witness（overflow=`queue-overflow`、
  cancellation follower=`queue-follower`），并补回显式断言：
  - 运行时捕获实际基线 `baselineActivated = fx.record.activated`（真实 Dart golden，
    `stored-10-2-owner-2-10` 为 true）；
  - 队满时再 enqueue `.activated(activated: !baselineActivated)`，同样必须
    `writeQueueOverflow`（两次 typed rejection 都断言）；
  - 排空后断言 `activated == baselineActivated`（overflow 从未落地且基线未被改变）、
    `accessKey == queue-c`、指针 `transactionID == receiptC.transactionID`、
    vault 记录数仍 5（overflow 零发布）；不删除/不弱化任何既有断言。

## R18（P2）：恢复 A/B/C receipt→immutable candidate 关联

- 恢复 c007c8c 的 A/B/C 三重 `loadPublishedCandidate(transactionID:)` 断言，使用
  小型静态 typed helper（`accessText` 提取 accessKey；候选逐条对照）：
  A 携带 `queue-a`；B = A + `deleteAll` 且仍 `queue-a`；C 携带 `queue-c` 且 jar 为
  `cleared`。保留 B 的中间状态、最终快照、publication 计数 5、overflow、pending/idle、
  取消断言；baseline 245 checks 与 180/90 预算、严格 Swift 6 不变。

## CI 编译预算：transaction phase 结构拆分（不削弱测试）

2026-10-12 下午实际 Actions 证据：`33d1922` 与本退修 `db90260` 的 release（含 job
重跑）**三次**均在 `check-native-account-envelope-transaction` 的 `xcrun swiftc` 编译上
命中 **180s 超时**（`transaction-compile.log` 只有 "Command timed out after 180
seconds"，无诊断输出；同一 transaction 源码 `672e216` 早前已成功编译并运行 245
checks），queue/authority 阶段因脚本中止而未执行。这属于编译预算问题，不是断言/语义
问题；按 reviewer 指引 "preserve all 180/90 budgets and strictness, structurally
split/explicitly type/measure the driver if needed" 处理：

- 把 1795 行 driver 按**逐行内容不变**的方式拆成两个编译单元：原文件保留 fixture +
  vault/CAS/gate/cancellation/purpose 前段；新增
  `tool/check_native_account_envelope_transaction_identity.swift` 承载
  identity/install/delete/import/buvid 后段（含 `patchedEnvelope`/water matrix helper）。
  拆分由脚本按行区间生成，已做 "原始行集合 = 两文件行集合（样板除外）" 的内容保持校验。
- Python gate 对两段分别使用**原有 180s 编译 / 90s 运行预算**与同一 Swift 6
  strict-concurrency 参数；两段计数之和必须 `>= 245`（门槛只增不减）；source
  hash / clean check / 清理列表 / `summary.json`（`transactionChecks` 总和 +
  `transactionIdentityChecks`）同步覆盖新文件。
- 该拆分只是编译单元降载，不改任何检查、断言、fixture 或生产代码语义；queue phase
  的失败/竞争覆盖保持不变。

## 文档与验收

- 更新 `P05_DURABLE_IDENTITY_QUEUE_PLAN.md`（unknown fence / 入口策略 / B2e-2 边界）、
  `P05_STATUS_MATRIX.md`、`PROGRESS.md`、`P05_COMPLETION_REPORT.md` 对应段落，明确
  本组仍是 shadow、四 flag false、生产接线未验收。
- 小 commit push 后，同一最终代码 SHA 显式 dispatch `ios.yml`(release5) +
  `ios-home-preview.yml`(preview4)；读实际 logs/artifacts：9 强制 outcome、源码 hash、
  actual 计数（queue 只增）、严格分析、BUILD SUCCEEDED/大小/FFmpeg、preview 压力。
- 不重跑 `33d1922`（只读其在途结果作对照）；不取消用户已派发的 run；修复完成后交
  Codex 独立复审，不自审 PASS、不进入 B2e-2/Block 3、不升级 authority。
