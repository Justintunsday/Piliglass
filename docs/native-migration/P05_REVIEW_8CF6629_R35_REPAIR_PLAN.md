# P05 退修计划：8cf6629 R35（journal-clear preflight 取消边界）

2026-10-15（Asia/Hong_Kong）。Codex 对 `8cf6629cf54917e2e44ea6b51ffde46d83077db5`
独立复审 CHANGES_REQUESTED：R35（resolver 在 durable clear 的 journal 读期间被取消仍会
删除持久证据并返回成功）。R33 单次 direct 冷加载与 R34 计数记账修正被认定为正面，不重做。
依据：`build/native-migration/review-8cf6629cf54917e2e44ea6b51ffde46d83077db5-codex/REVIEW.md`。
边界不变：shadow-only、四 flag false、不接 authority、不真实账户/设备、不碰 `youtube/`、
不改 UI、不降 264/245/148 基线、180/90 预算与断言/门禁；不伪造 process-kill/设备证据。

## R35 精确现状（源码级）

- `PiliAccountEnvelopeTransactionStore.resolveUnresolvedPublication`（约 531–533）在指针
  读回与分类之后调用 `vault.clearRecoveryJournal`；其后仅剩 `unresolved = nil`。最后一个
  `Task.checkCancellation()` 在指针快照之后，**clear 的 journal 读（新引入的异步阶段）
  之后没有任何取消检查**。
- `PiliAccountEnvelopeStagingStore.clearRecoveryJournal`（约 280–288）：`beginOperation`
  → `await recoveryJournal()`（=`secrets.read`）→ 仅校验 attempted ID → 直接
  `removeRecoveryJournalVerifying()`。Swift 取消是协作式的：`secrets.read/remove` 的 actor
  await 不会自动抛 `CancellationError`。
- 受控反例：pending journal/memory A；resolver 完成指针分类；在 clear 的 journal 读处暂停；
  在**删除尚未发起**时取消并释放读 → 现有代码仍校验 A、删除并验证、`unresolved=nil` 且返回
  resolution；重建 store 也看不到 pending。既有 Part 5 manifest-read 取消测试只覆盖更早的
  指针读，不覆盖该最后阶段。

## 修复（commit/point-of-no-return 语义精确化）

- `clearRecoveryJournal` 在"已读取并校验 exact attempted ID"与"发起不可逆删除"之间加入
  **`try Task.checkCancellation()`**：
  - **pre-clear-commit 取消**（含 journal 读 await 期间被取消）→ 抛 `CancellationError`，
    journal 字节与调用方内存 fence 原样保留；不删除、不验证、不返回 resolution。
  - **post-commit 语义（点无返回）**：一旦发起删除，删除+验证按既有保守逻辑跑到结论，
    **不再重复检查取消**——不存在人为回滚，也不得在已提交删除后伪造"journal 仍保留"；
    后续 await 不会把已提交的 clear 变成幻影 fence。
  - nil journal no-op 与 token 不匹配 `staleRecoveryJournal` 行为不变；读/删除失败处理
    （unresolvedRecovery 等）不变；无重放。
- store 侧不变（`unresolved = nil` 仍在 clear 成功之后），因此取消时内存 fence 自然保留。

## 回归（确定性、绑定真实 clear 路径；保留既有全部测试）

- fault vault 增加 **journal 读暂停注入**（`pauseJournalReadAfter(skip)`、
  `waitUntilJournalReadPaused`、`resumeJournalRead`、`isJournalReadPaused`），与既有
  manifest-read 暂停同型；driver 增加 `waitForJournalReadPaused`。
- `checkPersistentRecoveryJournal` 新增 **Part 7（R35）**：
  1. committed unknown（`.pointerReadAfter` write-after）→ journal A + fence A；
     在 clear preflight 的 journal 读处暂停并取消 → `CancellationError`、journal A 与
     内存 fence 原样保留、重建 store 仍 pending、零发布；
  2. 指针移动到 foreign candidate F 后，对**显式歧义确认**（`allowAmbiguous:true`）重复同一
     pre-commit 取消 → 证据保留；
  3. 取消后重新以非取消的显式确认 resolve → ambiguous receipt（exact A）、journal 清除、
     follower 精确发布一次（exact counts）。
- 既有 R20 manifest-read 取消回归、Part 5/6、token guard、strict canonical 解码、
  R23 选择性失败处理、R25 真实 Keychain 前缀全部保留。

## 验收

- 先保存本计划 → 修 source（vault clear 取消边界）→ driver（fault 注入 + Part 7）→
  文档（含 B2E2 计划 2.1 item 8 的 commit 语义更新）→ 静态检查 → 小 commit/push；
  读取在途 8cf6629 release38773617985/preview38773622908（保留/读取、不重复 dispatch）
  → reconcile 后新最终代码 SHA 显式 dispatch BOTH workflows → 实际九 outcome/artifacts/
  hashes/计数（transaction ≥245 后才谈 queue）/strict/BUILD/FFmpeg/preview → 交 Codex
  独立复审。不得自审 PASS、不得升级 authority、不得声称 B2e-2/3/whole P05 完成。
