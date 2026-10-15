# P05 退修计划：0ea82b1 复审 R19–R21（resolution 身份/并发/取消见证）

2026-10-15（Asia/Hong_Kong，用户恢复 P05 委托）。Codex 对精确代码 SHA
`0ea82b138b5e2ad63f867e7466fb31a08a42cbef`（HEAD `762da2f` 仅四个文档文件）独立复审：
CI 5+4/九个 outcome/109/44/40/245/104/51/账户258/72/20 preview/87 源 hash(85+2 pubspec)/
golden/严格性/BUILD/FFmpeg 全部核实通过，R14–R18 被认定为已修复的有效改进，**但结论仍为
CHANGES_REQUESTED**：R19（P1）、R20（P2）、R21（P2）。本计划只处理这三项，不重复已闭合的
R14–R18，不改生产接线，不升级 authority。依据：
`build/native-migration/review-0ea82b138b5e2ad63f867e7466fb31a08a42cbef-codex/REVIEW.md`、
`build/native-migration/opencode-p05-new-20261012/HANDOFF.md`（2026-10-15 恢复段）。
范围/安全边界照原 P05_BRIEF.md：四 flag false、shadow-only、不接 authority、不改 UI、
不碰 `youtube/`、不操作真实账户/设备、不降断言/预算/门禁、未知写不重放。

## R19（P1）：内容 hash 不是 attempted-publication identity

- 精确现状（`PiliAccountEnvelopeTransactionStore.swift`）：
  - `publishCandidate`（约 283–298 行）只保留 `expectedTransactionID` 与
    `digest(codec.encode(candidate))`；vault 内部 `let id = UUID()` 铸造候选 ID 且
    unknown 结果不返回它。
  - `resolveUnresolvedPublication`（约 314–332 行）以
    `observedDigest == attemptedCandidateSHA256` 作为 `observedMatchedAttempt`。
  - `applyCredentials`/`applyActivated` 即使值不变也会发布；adopt 后有效水位已持久，
    `replace` 不 bump revision，因此"同值写入"的候选字节可能与前一候选**逐字节相同**。
- 确定性反例：adopt 基线上请求与当前完全相同的 credentials（含 nullable 字段），注入
  `pointerWriteBefore` + 不可读 ack → 指针未推进，但 old envelope 的 hash 与本次 attempt
  相同，`observedMatchedAttempt` 错误地为 true。现有写前回归改用了 `unknown-before` 值，
  掩盖了该 no-op 情形。
- 修复（携带 attempted immutable transaction ID，不再以内容推断 operation 提交）：
  1. vault `PiliAccountEnvelopeStagingStore` 的 CAS 发布方法增加可选
     `candidateTransactionID: UUID? = nil`（缺省仍内部铸造，既有调用不变），
     caller 提供时先校验 `recordKey` 不存在（防碰撞），并以该 ID 作为本次 record/manifest
     ID。unknown 场景下 store 因此持有"本次 attempt 的精确 ID"。
  2. `PiliAccountShadowUnresolvedPublication` 增加 `attemptedTransactionID: UUID`。
  3. `PiliAccountShadowPublicationResolution` 改为显式三态 + 诚实字段：
     `outcome ∈ {attemptCommitted, attemptNotCommitted, ambiguousObservedCandidate}`、
     `observedTransactionID`、`attemptedTransactionID`、
     `observedContentMatchesAttempt`（内容证据，明确"不是 operation 证明"）。
     判定：observed == attempted → committed；observed == expectedPrevious（含双 nil）
     → notCommitted（**指针未动即未落地，即使字节相同**）；其它/外来候选 → ambiguous。
  4. 注释与计划文档同步：digest 只作内容旁证，不再声称"证明该 operation 提交"。
- 回归（queue driver，fault vault）：
  - 同值 credentials：`pointerWriteBefore`+不可读 ack → notCommitted 且
    contentMatches true（复现反例）；`pointerWriteAfter`+不可读 ack → committed 且
    observed==attempted ID（字节相同仍能证明提交）。
  - 同值 activated：同前/写后两分支。
  - 同值"外来候选"歧义：本 store unknown 冻结期间，第二 store 发布字节相同的 no-op 候选
    → outcome=ambiguous、contentMatches true、observed 既非 attempted 也非 expected；
    释放后 follower 从当前指针继续。
  - 两个不同 attempt（同字节）token 互异：A 未提交 → 显式重试发布 C → D 已提交的
    resolution 只指向 D 的 ID，不指向 C。无自动重放；冻结期间 follower 抛
    `unresolvedPublication`（保留 R13 行为）。

## R20（P2）：过期 resolver 不得清除更新的 fence

- 精确现状：`resolveUnresolvedPublication` 捕获 `unresolved` 后 `await
  vault.loadShadowSnapshot()`，返回后**无条件** `self.unresolved = nil`。两个 resolver
  可捕获同一 pending A；其一完成清 A 后，新写可 arm B；迟到的旧 continuation 会用 A 的
  读回清掉 B。期间 vault 的 `operationInProgress` 只保护单次读，不保护 store 的
  capture/await/clear 序列。
- 修复：
  1. resolver 独占 gate：`resolutionInProgress`；并发第二个 resolve 抛新增类型化
     `PiliAccountShadowTransactionError.resolutionInProgress`，不接触状态。
  2. 每个 await 之后用不可变 token（`attemptedTransactionID`）重新校验：与当前
     `unresolved` 不一致 → 新增 `staleResolution` 上抛且**不清除**任何 fence
     （防御性，与 gate 共同保证 B 存活）。
  3. 清除前两次 `Task.checkCancellation()`（进入时、读回后）：取消的 resolver 抛
     `CancellationError` 且**不释放** fence；`defer` 归还 gate。
- 回归（queue driver）：
  - 受控 pause（`pauseManifestReadAfter(0)`）挂起 resolver 1 的读回；resolver 2 立即抛
    `resolutionInProgress`；resume 后 resolver 1 正常记录 resolution。
  - resolution 完成后重新 arm 新的 unknown B：`pendingUnresolvedPublication` 的
    attemptedTransactionID == B，队列 follower 仍 `unresolvedPublication`，B 的
    resolution 正常完成（B 从未被 A 的读回清除）。
  - 取消路径：挂起 resolver 后 cancel，resume → `CancellationError` + fence 保持 +
    gate 不悬挂（随后 resolve 成功）。
  - 失败读回保持 fence（R13 已有，保留）；queued follower 不跨越任何 unresolved 边界。

## R21（P2）：取消回归的 overwriting follower 掩盖禁止发布

- 精确现状（queue driver 约 469–493 行）：queued 取消段的 `cancelled` 是
  `.credentials(queue-cancelled)`，follower 是 `.credentials(queue-follower)`；最终只断言
  accessKey==queue-follower。若被取消的 credentials 被错误发布，follower 会覆盖其
  accessKey 证据；预算段的"相对记录数"基线在取消之后捕获，也会接受该多余发布。
- 修复（保留原否定覆盖，不做生产语义变更）：
  1. `holder = .cookieDeleteAll`；`cancelled = .cookieSave(fx.save)`（若被错误发布会重新
     引入 txn-cookie，jar != cleared）；follower 改回非覆盖的
     `.credentials(queue-follower)`。
  2. 捕获取消段精确前置状态：`preCancelRecords = recordCount()`；
     结束后断言 `recordCount == preCancelRecords + 2`（仅 holder + follower），且
     `records[1].jar == fx.cleared`（cancelled save 未落地）、`accessKey ==
     queue-follower`（follower 已落地）；cancelled task 仍必须为 typed
     `CancellationError`，admission/顺序屏障不变。
  3. in-flight 取消段：保留 jar 断言，并追加 recordCount 不增（指针前取消不留发布）。
  4. 预算段：`preBudgetRecords` 相对断言保留，并钉住其绝对值（等于取消段结束计数），
     使"取消段多发布的候选"无法混入基线。

## R22（P2）：raw retained candidate 不是 published pointer（fixture 修正）

- Codex 对 `9669fa7` 的运行证据：queue phase 编译通过、runtime FAILED，fatal 为
  `checkResolutionSerialization` 的 `fault.recordCount() == 2`。原因：`QueueFaultVault.
  recordCount` 统计 raw `account-envelope-shadow-v2.*` 候选；import+adopt=2 之后，
  `pointerWriteBefore` + 不可读 ack 会先写入并验证候选 record+descriptor、再无法判定
  pointer 写入，vault 为未知发布**有意保留**第 3 个孤儿候选/descriptor（过早删除可能
  破坏真正 committed 的 unknown）。因此"raw 3 / published pointer 未变"是正确行为，
  原断言把 raw 候选与 published manifest 混为一谈。
- 修正（不删断言、不等价放宽）：
  1. 在 unknown A 前捕获真实基线：`originalPointer`（transactionID + envelope）与
     `baselineRecords == 2`；
  2. unknown A 后分别证明：published pointer/envelope 逐字节未变；attempted
     transaction ID 与 pointer 不同；`loadPublishedCandidate(attemptedID)` 可读出被保留
     的候选；`recordCount == baselineRecords + 1`（恰好一个额外 raw 候选）；
  3. resolution 后证明 `.attemptNotCommitted`、observed == original pointer、envelope
     不变、保留候选仍在且计数仍为 `baselineRecords + 1`（无重放/无 follower 发布）；
  4. unknown B 重复同型证明（`baselineRecords + 2`）；B 的 resolution 后 follower 显式
     发布 → pointer 指向新 manifest、`recordCount == baselineRecords + 3`（只新增一个
     published 候选，不重放任何 retained candidate）；
  5. 同值 R19 helper 亦补充：写前 attempt → `baselineRecords + 1`（保留孤儿）；写后
     committed attempt → pointer == attempted ID 且 `baselineRecords + 2`（保留孤儿 +
     已发布候选并存），显式区分 raw retained 与 published。
- 等价假设审计：逐条核对 queue driver 全部 `recordCount()` 断言（FIFO5、取消±2、
  in-flight0、预算0/+1、retry 4、chaos 5、purpose 4/4）与其时点状态，均为 stale-在写前
  /成功路径；transaction driver 的 `unknownVault.recordCount()==2` 位于已提交的
  `pointerReadAfter` unknown 之后，语义正确。唯一错误即 R22 处，已按上修正。
- 不删除任何 unknown 候选、不降预算/断言；新增断言只增不减。

## 验收

- 小 commit/push；同一最终代码 SHA 显式 dispatch `ios.yml`(release5) +
  `ios-home-preview.yml`(preview4)；读实际 logs/artifacts（九 outcome、源 hash、
  envelope/queue/transaction/account 计数、严格分析、BUILD/FFmpeg、preview 压力）。
- 通过后交 Codex 独立复审（不自审 PASS）；未获 PASS 前不进入 B2e-2/Block 3，不升级
  authority，不写账号级队列生产接入或 P05 完成。生产接线/B2e-2 持久恢复面仍是显式未做项。
