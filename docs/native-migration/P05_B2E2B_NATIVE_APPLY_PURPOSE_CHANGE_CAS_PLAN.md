# P05 提案计划（R51 修正版；仅提案，尚未实现）：Native `applyPurposeChange` read-transform-publish CAS（原 3b8e821 item8 / 53aed63 遗留行）

2026-10-16（Asia/Hong_Kong）。依据 `review-b4ea200d0ade587c697743ee87532fc291ab39b5-codex`
（R51，源码推导推翻上一版 `pausePointerRead(occurrence: 2)` 相位）与原
`review-44a9818482baad28d9864579f8324091de54d1a8-codex`（plan review）；另有
`review-eb58d5cdfbd709c73db727a4c25c61e9c1666894-codex`（B1h Dart 组有限 PASS，与本行无关，
本行不受其闭合影响）。**本文件只提出计划：不实现、不改生产/测试、不派发 CI**；待 Codex 复核
本 R51 修正版后，再进入实现与 BOTH workflows + 独立复审。

## 目标行（当前 OPEN）

- 目标 API：`PiliAccountEnvelopeTransactionStore.applyPurposeChange`
  （ios/Runner/Native/Persistence/Accounts/PiliAccountEnvelopeTransactionStore.swift:686-723）。
- 目标缺口：没有**定向**用例把 competing durable publisher 插到该调用
  **snapshot 读之后、staging compare-and-publish 之前**，验证陈旧调用被真实 CAS 以
  `staleTransaction` 拒绝、零 stale 发布、winner 完整保留、后续合法发布可用、reopen 后 winner 仍在。
  既有 purpose 用例（顺序 primitive/close-reopen/byte-budget/temporary-selection/rejection）与
  generic staging CAS 用例都不是该定向竞态。

## 上一版相位为何不成立（R51 源码推导；已废弃）

- staging `importShadow`（StagingStore:136-140、:150-159）先 `beginOperation()` 再进入
  `publishShadow`，直到 return 才由 `defer` 释放；`loadShadowSnapshot`（:392-398）同样门控；
  `beginOperation`（:495-499）重入即抛 `operationInProgress`（含重启读/import/discard）。
- 因此 A 暂停在 staging CAS 指针读（或快照读）期间，同 vault 的 B 的 load/import 均被拒，
  B **不可能**在拟议相位合法发布 P2；"先等 B 成功再 resume" 的调度无法成立。这是**计划缺陷**
  （源码推导），**不是**观测到的运行时挂起，也不是生产 CAS 缺陷；真实交错并非全部不可能。
- `pausePointerRead(occurrence:)` 的读序号不是语义相位契约（cold/recovery 路径可增加读次数），
  上一版相位整体废弃；不再以读序号/调度假设/`Task.yield`/sleep 作为相位证明。

## 真实候选窗口（本提案目标相位）

- `transaction()`（:1141-1175）：`await vault.loadShadowSnapshot()` 返回即释放 staging 门
  （:394 `defer`）；其后到 `publishCandidate` 进入 staging `importShadow`（:154）之间：
  记录查找、generation/`isLogin` 校验、`transform`、`candidate.validated(limits:)`
  全部**同步**（:1153-1165），无 await、无后端 IO。
- 该窗口内 A 持有：wrapper 本地 `operationInProgress`（:1148-1149；:1166-1168 注释明确
  wrapper 门**不能**栅栏 shared-vault 其它调用者）、已捕获的 P0 指针与完整 snapshot、已变换
  并预算校验的候选；staging 门空闲 → 同 vault 的合法 B 可以完整发布。
- 由于窗口内无挂起点，secret-store 后端注入 / 调度假设 / sleep / `Task.yield` / 读序号都无法
  构成相位证明 → 需要最小可测试性 seam（见下）。

## 拟议 seam（最小、生产默认惰性；R51 允许的 testability seam）

- 位置：`publishCandidate`（:429+）内，`attemptID` mint（:436）之后、`vault.importShadow(...)`
  （:438）之前，await 一个可选 hook——即"进入 staging importShadow 之前"的确切边界
  （暂停发生时 `attemptID` 已 mint；恢复后不再 mint，直接进入 vault 调用）。
- 形态：仿既有文档化 seam `recoveryReadDeliveryHook`（:222-227 注释、:256-260 setter）：
  `private var prePublicationDeliveryHook: (@Sendable () async -> Void)?` +
  `func setPrePublicationDeliveryHook(_ hook: (@Sendable () async -> Void)?)`。
  生产接线从不安装（缺省 nil；六个既有 `publishCandidate` 调用点行为不变）。
- 语义约束（无生产 bypass）：hook 只能推迟"进入 staging importShadow"的时点；不能读/改
  candidate、指针、门或 CAS 结果。接受/拒绝始终由真实 staging `publishShadow` 的 CAS
  （StagingStore:182-185，**先于任何** candidate/journal/descriptor/pointer 写）在真实 vault
  门内判定；无 copied CAS/resolver、无 preset/relabel receipt、无门禁用、无指针写注入。
- 隔离与重入：hook 是 **store 实例级**（只有 A 安装；B 的 store 无 hook）；A 在 vault actor
  之外挂起，staging 门空闲（B 的成功即直接证据）；resume 后 A 正常进入 `importShadow`。
- 错误/取消/清理：hook 之前的任何抛出都不会 await 到 hook；用例只把精确
  `PiliAccountEnvelopeStagingError.staleTransaction` 计为通过，其它一切错误按原类型失败
  （`.operationInProgress`/`.publicationUnknown` 不得伪装通过）；hook 不吞取消（既有取消用例与
  语义不改）；测试在 defer/cleanup 中先 `resume()` 再 `await` A 任务，并
  `setPrePublicationDeliveryHook(nil)` 清除；生产 `defer { operationInProgress = false }`
  （:1149）在所有路径释放 wrapper 门。
- 兜底：若实现阶段发现该 seam 无法在不改变 CAS/门语义的前提下安全表达真实边界 → **保持该行
  OPEN 并记录精确限制**，不声称闭合、不弱化 CAS。

## 确定性竞态序列（C1 目标用例）

1. fresh namespace；backend 为**实际** `PiliAccountKeychainSecretStore(stagingNamespace:)`；
   **同一个** `PiliAccountEnvelopeStagingStore` 实例（:142-143 要求同 namespace 的所有
   transaction actor 共享同一 vault 实例；不创建第二个 staging actor）；store A 与 B 均指向
   该实例；`importShadow(codec.encode(base))` → 指针 P0。
2. 仅 A 安装 pauser hook（continuation 一次性：`waitUntilPaused()` 观测、`resume()` 恢复；
   无 sleep、无 `Task.yield`）。
3. 启动 A：`applyPurposeChange(recordKeyUnits: secondKey, expectedGeneration:
   base.records[2].generation, purpose: purposeA, previousKeyUnits: nil,
   previousExpectedGeneration: nil)`；purposeA 由 fixture 驱动选取（records[2] 尚未持有，
   与既有 tight 用例同法 guard）。
4. `await pauser.waitUntilPaused()` ⇒ A 已捕获 P0、transform + validated 完成、
   wrapper 门持有、staging 门空闲。
5. B 合法竞争发布：`storeB.applyPurposeChange(secondKey, gen, purpose: purposeB,
   previousKeyUnits: nil, ...)`（purposeB ≠ purposeA、亦未被持有）→ CAS 期望 P0 == 当前 →
   真实发布 W（新 transactionID）；保留 B receipt。
6. `resume()` ⇒ A 恢复：`attemptID` 已在暂停前 mint（hook 位于 mint 之后、vault 调用之前），
   A 直接进入真实 `vault.importShadow(expectedTransactionID: P0)` → `publishShadow` CAS
   见 W ≠ P0 → 抛 `.staleTransaction`。
7. 断言：
   - B 在 A 挂起期间**成功**（receipt 非 nil、无 `operationInProgress`）——直接证明该相位
     staging 门空闲（与既有 fenced :295-310"门真被持有 → 第二 actor 被拒
     `operationInProgress`"形成对照；但本用例不把 `operationInProgress` 当作目标断言）；
   - A 精确抛 `PiliAccountEnvelopeStagingError.staleTransaction`（非 `.operationInProgress`、
     非 `.publicationUnknown`）；
   - A 无 receipt；`await storeA.pendingUnresolvedPublication == nil`（未新 arm unknown
     fence）；`try await raceVault.loadRecoveryJournal() == nil`（journal 未写）；
   - 零 stale 发布，仅以可观察不变量断言（不枚举 secrets 键、不伪造记录级证据）：恢复后
     `loadShadowSnapshot()` 的 transactionID == W 且 envelope decode 相等 W；attemptID 为
     内部 mint、其 record 键不对外暴露，故不声称逐键枚举；
   - winner 完整状态（W 语义）：records[2].persistedPurposes == base + [purposeB] 的 Dart
     追加序、selections[purposeB slot] == records[2].record、history 按既有政策；jars/orders/
     generation/revision/匿名记录不变。

## C2 后续合法发布（P3）与 receipt 断言（R51 更正）

- C1 后清除 hook（`setPrePublicationDeliveryHook(nil)`），A 以新鲜快照 W 再次
  `applyPurposeChange` → 成功发布 N。
- receipt 断言**仅有实际字段**（`PiliAccountShadowTransactionReceipt` :125-132 仅含
  transactionID/record/durableIdentity/nativeWritesAllowed/authoritySwitchAllowed）：
  `transactionID == N`、`record == base.records[2].record`、
  `durableIdentity == base.records[2].durableIdentity`、两门恒 false；
  **generation 不是 receipt 字段**——generation/revision 在**持久化信封**上单独断言
  （policy 不变：records[2].generation == base.records[2].generation、revision == base.revision）。

## C3 reopen：实际 Keychain 新实例（R51 精度更正）

- 以全新 `PiliAccountEnvelopeStagingStore(secrets:
  PiliAccountKeychainSecretStore(stagingNamespace: 同一 namespace))` 读回 N 的完整 envelope。
- 明确：这是 **Security.framework 同 namespace 的新实例**读取（同进程），**不是** process
  kill/重启证明；`TransactionFaultVault`（tool/check_native_account_envelope_transaction.swift:5+）
  是每实例空字典的**合成**后端，新 fault backend 不自动共享持久值，wrapper 重开只构成
  **逻辑重建**——本提案不把合成内存重开标注为 Keychain/进程重开，也从不以假内存重开替代
  实际 Keychain 证据；既有实际 Keychain 用例（driver :86-152、:477-484）保留不改。

## C4 第二竞争变体（B = temporary selection）

- 独立 fresh namespace、同构块：B 以 `applyTemporarySelection(secondKey, gen,
  purpose: purposeB)` 合法发布（slot 移动 + history 派生、purposes 不变）→ A 恢复后同一
  `.staleTransaction` 契约 + winner selections/history 逐值断言；证明两类合法发布
  （purpose change / temporary selection）都无法被陈旧候选覆盖。

## 回归矩阵与计数

- 新增 C1–C4（上述）；另有 **C1c 直接取消对照**（新 hook）：A 暂停、无 B 移动指针 →
  `cancel()` 后**显式** `resume()`（continuation 不自动感知取消）→ 精确 `CancellationError`、
  无 receipt、零 durable 写、无 fence/journal、winner 不变；随后同一 store 的合法写入成功
  （wrapper/hook 清理），且 staging 既有 CAS-先于-checkCancellation 顺序不变。
  既有 sequential/close-reopen/byte-budget/temporary-selection/ambiguous/rejection/
  cancellation/operationInProgress 用例全部保留（C5：不重做、不弱化、不改预算）。
- 证据强化：C1/C4 的 winner 期望信封由 fixture/primitive 语义**独立构建**后与 full decoded
  snapshot + transactionID 比较（非读回 W 再与自身比较）；同 namespace 使用透明转发 write
  计数器（不注入 pointer 值）证明 stale/cancel 零 durable 写；实际 Keychain 无键枚举 →
  不声称 orphan 记录清点（可观察不变量 + 源 CAS-先于写）。
- 既有 fenced 块（:249-310）继续是**独立的** `operationInProgress` 控制；目标 CAS 用例不得把
  wrapper 本地门或 vault `operationInProgress` 当作拒绝原因混淆。
- 新用例只增 check 计数；envelope 基线 109/44/40/245/292/51 不降；**精确新增计数以实际新
  SHA 执行产物为准，不作预测**。

## 边界（不变）

- 仅 Native shadow 层；不接生产 authority、不改 Dart/UI/Aether/`youtube/`、无真实账户写；
- 不改 budget/limits、不发明全局唯一性、不复制 resolver/preset relabel、不引入第二 staging
  actor、不做后端指针注入；
- 保留 previous/temporary 原始语义与全部既有负例/预算门；如实现中发现真实缺陷 → 聚焦修复并
  如实记录（本行当前 OPEN，不预判缺陷）；
- 四 flag false。

## 验收

- 本 R51 修正版先经 Codex 计划复核；通过后实现为**新代码 SHA**，显式 BOTH workflows
  （各一次）+ Codex 独立复审（以实际 CI 产物/日志为准）；本 docs-only 轮不实现、不派发 CI、
  不改生产/测试。
