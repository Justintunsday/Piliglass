# P05 提案计划（仅提案，尚未实现）：Native `applyPurposeChange` read-transform-publish CAS（原 3b8e821 item8 / 53aed63 遗留行）

2026-10-16（Asia/Hong_Kong）。依据 `review-eb58d5cdfbd709c73db727a4c25c61e9c1666894-codex`
（R50）与 `review-44a9818482baad28d9864579f8324091de54d1a8-codex`（plan review）；原
`codex-review-3b8e821` item8 / `codex-review-53aed63` remaining note。**本文件只提出计划：
不实现、不改生产/测试、不派发 CI**；待 Codex 先复核 R50 docs 收窄、B1h Dart 范围与本文，
再进入实现与 BOTH workflows + 独立复审。

## 目标行（当前 OPEN）

- 目标 API：`PiliAccountEnvelopeTransactionStore.applyPurposeChange`
  （ios/Runner/Native/Persistence/Accounts/PiliAccountEnvelopeTransactionStore.swift:686-723）。
- 目标缺口：没有**定向**用例把 competing durable publisher 插到该调用
  **snapshot 读之后、staging CAS 读之前**，验证陈旧调用被 CAS 拒绝、零 stale 发布、
  winner 完整保留、后续合法上下文可用、close/reopen 后 winner 仍在。
  既有 purpose 用例（顺序 primitive/close-reopen/byte-budget/temporary-selection）与
  generic staging race 都不是该定向竞态。

## 实际 Native 语义（源码核对；本提案不改动）

- `transaction(recordKeyUnits:expectedGeneration:kind:_:)`（:1141-1175）：
  1. `requireDirectEntryAllowed()`；`loadRecoveryOnce()`；`beginOperation()`（store 本地
     `operationInProgress`；源码注释 :1166-1168 明确 **wrapper gate 不能栅栏 shared-vault
     其它调用者**，必须由 vault 在同一 operation fence 内做比较+发布）；
  2. `await vault.loadShadowSnapshot()` → 指针 `snapshot.transactionID`（记为 P1）；
  3. 查找 record + 校验 `generation`/`isLogin`；
  4. `transform(current, index)`（同步）：selected 幂等追加 purpose；可选 previous 必须
     命名真实持有者（未持有→不触碰；`previous == selected` 为幂等 no-op；**无全局唯一性
     扫描**）移除 purpose；`selections[slot] = selected`；history 按既有政策；
  5. `candidate.validated(limits:)` 共享累计预算；
  6. `publishCandidate(candidate, expectedTransactionID: P1, kind: .purposeChange)`
     （:429+）：先 mint `attemptID`，再 `vault.importShadow(...)`。
- staging `PiliAccountEnvelopeStagingStore.publishShadow`（:161+）：
  - decode/encode candidate →（关联发布）recovery journal 预检 → **CAS**：
    `previous = await manifest()`；`previous?.value.transactionID != expected →
    throw PiliAccountEnvelopeStagingError.staleTransaction`（:183-185），**先于任何
    candidate/journal/descriptor/pointer 写入**；
  - 之后：journal 写 → descriptor ensure → candidate 记录写+读回校验 → descriptor 写+
    读回校验 → pointer 写+读回；pointer 未按预期 → `publicationUnknown` → store 记录
    unresolved fence 并原样传播（不重放）。
- 结论：本行的可测试契约 = **在 load→publish 窗口内由合法 competing publisher 移动指针，
  陈旧调用必须在 CAS 处 `staleTransaction` 拒绝且零 stale 发布**；`operationInProgress`
  只是本 store 门，不能替代 vault CAS。

## 拟议测试 seam（仅测试工具；无生产改动）

- 现有 `tool/check_native_account_envelope_transaction.swift` 的 `TransactionFaultVault`
  已有 `pauseWrite()/waitUntilPaused()/resume()`（一次性暂停下一个 `write`）与
  `pointerWriteAfter/pointerReadAfter` fault。
- 拟议扩展（test-only）：`pausePointerRead(occurrence: Int)`——一次性暂停第 N 次对
  pointer key 的 `read`（`resume()` 恢复；`waitUntilPaused()` 观测；无 sleep）。
  用例 arm `occurrence = 2`：第 1 次是 store `loadShadowSnapshot` 的指针读，
  **第 2 次是 staging CAS 的 `manifest()` 指针读**。
- 拟议确定性竞态序列：
  1. 用现有 actual Dart envelope golden 建 fixture；store A 与 competing publisher
     **共享同一 fault vault 实例**（同 namespace，源码文档化要求）；
  2. `await vault.pausePointerRead(2)`；启动 `storeA.applyPurposeChange(...)`
     （合法 previous/generation 前置条件）；
  3. `await vault.waitUntilPaused()` ⇒ A 已完成 snapshot、暂停在 CAS 读；
  4. competing publisher（合法路径：同 vault 的第二个 store B 的
     `applyTemporarySelection`/`applyPurposeChange`，或直接 staging `importShadow` 一个
     完整合法 envelope）发布 P2；
  5. `vault.resume()` ⇒ A 的 CAS 读返回 P2 ≠ P1 ⇒ `.staleTransaction`；
  6. 断言：typed error（非 `.publicationUnknown`）、无 receipt、未 arm unresolved fence、
     recovery journal 保持 nil/不变；
  7. winner 指针 + 完整 envelope 逐值保留（records/purposes/selections/history/schema/
     high-water；decode 相等 + pointer/descriptor 一致）；陈旧候选的 record/descriptor
     不存在（`recordCount()` 不增加）；
  8. 后续合法上下文：重新 `loadShadowSnapshot` + `applyPurposeChange`（fresh
     generation/pointer）成功发布 P3；previous 前置条件语义不变；
  9. close/reopen：新 store/vault 实例（同一 secrets 值域，对应 Keychain 重开）读取 P3 的
     winner 完整 envelope。
- 若该 seam 无法安全暴露（例如 actor 重入使竞争发布无法在暂停窗口内完成，或暂停读语义
  与真实 Keychain 读不一致），则**保持该行 OPEN 并记录精确限制**，不声称闭合。

## 拟议回归矩阵（全部新增；不删/不改既有）

- C1 陈旧 CAS 拒绝（上述序列）：typed `.staleTransaction`、零 stale 发布、winner 逐值、
  无 fence/journal；
- C2 后续有效 `applyPurposeChange` 成功（P3）+ receipt 语义（record/generation）正确；
- C3 reopen（新实例）读回 P3 winner 完整 envelope；
- C4 两个 purpose 事务竞争（B 先以合法 purposeChange 发布 P2）→ A stale 拒绝；winner
  purposes/selections/history 一致；不推断/不发明全局唯一性；
- C5 既有 sequential/close-reopen/byte-budget/temporary-selection/ambiguous 用例全部保留
  （不重做、不弱化）；
- 计数：新用例使该 driver 的 checks 只增；envelope 109/44/40/245/292/51 基线不降。

## 边界

- 仅 Native shadow 层；不接生产 authority、不改 Dart/UI/Aether/`youtube/`、无真实账户写；
- 不改 budget/limits、不发明全局唯一性、不复制 resolver/preset relabel；
- 如实现中发现真实缺陷 → 聚焦修复并如实记录（本行当前 OPEN，不预判缺陷）；
- 四 flag false。

## 验收

- 实现该组时：新代码 SHA 显式 BOTH workflows（各一次）+ Codex 独立复审（以实际 CI
  产物/日志为准）；本 docs-only 轮不实现、不派发 CI、不改生产/测试。
