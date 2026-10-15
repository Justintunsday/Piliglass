# P05 B2e-2 计划：持久化未决发布 journal、重启恢复与 identity 消费者

2026-10-15（Asia/Hong_Kong，tagged-reader 有限 PASS 后按授权续跑）。Codex 对
`e3ea5ae` 的 FINAL DISPOSITION 明确：下一步保存并实施 **B2e-2 persistent unknown/restart
recovery 与 identity-consumer 计划**，并把 tagged-reader 计划中未执行的
`restoreEmptyCaptured` captured-window 回归纳入本组。依据：
`build/native-migration/review-e3ea5ae7eec4ce7847577dd5347a2d73d97d823d-codex/REVIEW.md`、
`docs/native-migration/P05_DURABLE_IDENTITY_QUEUE_PLAN.md` B2e-2 段与保留项、
`docs/native-migration/P05_PERSISTENT_RESTORE_PLAN.md`（Dart 恢复 Vault 的 crash-ordering
先例）。边界照旧：shadow-only、四 flag false、不接 authority、不改 UI/Aether、不碰
`youtube/`、不真实账户写、不降断言/预算/门禁；B2e-3 生产 composition 是独立 gate。

## 1. 现状与缺口（精确源码）

- `PiliAccountEnvelopeTransactionStore`：`unresolved`
  未决 fence 只在**内存**（`a5ce478` 起），`resolveUnresolvedPublication()` 单飞 +
  token 复核 + 取消不释放（`0ea82b1`）。进程/actor 重建后内存为空 → 重新创建的 store
  会立即允许 follower 发布，可能抹掉未决 unknown 的 reconciliation 证据（R13 的
  "persistence recovery is a later slice" 即指此）。
- `PiliAccountEnvelopeStagingStore`：唯一发布者、`operationInProgress` + CAS +
  写后读回；候选 record/descriptor 在指针前写入并验证；unknown 时**有意保留**孤儿候选
  （`b7f6692` 语义）。vault 没有持久化的未决证据，也没有 namespace 级 journal 前置检查。
- attempted operation identity（caller-minted `candidateTransactionID` + 三态 resolution）
  已存在；B2e-2 要把它**跨进程持久化**，而不是把内存 fixture 改名。

## 2. 契约：持久 recovery journal（B2e-2a）

- 存放：vault 的 secret store，单槽 key `account-envelope-recovery-journal-v1`；
  同一 namespace 一个 vault/一个发布者（沿用既有 assumption；跨 store 由 vault 前置
  检查强制，见下）。
- 内容（canonical JSON，`JSONEncoder .sortedKeys`；≤4096 bytes、字段精确集合）：
  `{schemaVersion:1, state:"unresolved", attemptedTransactionID:<uuid>,
    expectedPreviousTransactionID:<uuid>|null, attemptedCandidateSHA256:<64 位小写 hex>,
    kind:<写入种类 raw value>}`。
- 严格解码/完整性：字段类型/形状/枚举值校验；decode 后按 canonical 重编码必须与存档
  字节**逐字节相等**，否则抛新增 `PiliAccountEnvelopeStagingError.invalidRecoveryJournal`，
  **fail closed**（绝不当作"无 journal"）。损坏/不可读 journal 使所有写与 resolution
  抛错，直到运维清除——安全保留优先于删除。
- 写入/清除所有权在 vault（单一位置定义 crash ordering）；store 只消费。

### 2.1 crash ordering（`publishShadow`，仅当 caller 提供 `candidateTransactionID` + kind）

1. decode/encode、`previous = manifest()`、CAS expected 校验（不匹配 → `staleTransaction`，
   无 journal 副作用）。
2. `Task.checkCancellation()`。
3. id/recordKey、碰撞校验（`b7f6692`）。
4. **写 journal 并读回验证**（在任何候选/指针写入前）：
   - 写入抛错 → 读回：确无 journal → 抛原始错误（确定未发布，无 fence）；
     journal 已提交 → 尝试清除并验证：清除成功 → 抛原始错误；仍存在/状态不确定 →
     抛 `unresolvedRecovery`（journal 即证据，fail closed）。
   - 读回不匹配/读取失败 → 尝试清除；无法确认清除 → `unresolvedRecovery`。
5. 候选 record + descriptor 写读验证（既有；失败清理按既有语义）。
6. 指针写 + ack 读：
   - observed == nextBytes（提交被证实）→ **清除 journal 并验证**；清除成功 → 返回
     success receipt；清除失败/不确定 → 仍返回 success receipt（提交已由指针证实，
     不伪造未知），journal 保留给后续恢复分类（committed）。
   - ack 读抛错或 observed != nextBytes：
     - observed == previous（确定未发布）→ 清除 journal（尽力＋验证）→ 抛原始写错误；
       清除失败 → journal 保留 + `unresolvedRecovery`。
     - 其余 → `publicationUnknown`（journal 保留）。
7. **vault 前置检查**：任何带 journal 的 namespace 上，新的 `importShadow` 先读 journal，
   存在即抛 `unresolvedRecovery`（另一 store/另一调用者也不能越过）；只允许
   `clearRecoveryJournal(expectedAttemptedTransactionID:)`（读当前 journal、token 匹配、
   remove + 验证；nil 为 no-op；token 不匹配 → `staleRecoveryJournal`）。
8. Resolution 清除顺序：读回分类 → **durable clear journal** → 内存 `unresolved = nil`。
   取消/失败/stale 一律保持 journal + 内存 fence。

### 2.2 store 集成

- 新增异步 `loadRecoveryIfNeeded()`：所有 async 写入口（`enqueue`、`transaction()`、
  adopt/install/delete/import/buvid）与 `resolveUnresolvedPublication()` 先加载一次：
  journal 存在且内存 fence 为空 → 以 journal 字段 arm `unresolved`（token/digest/kind
  与 journal 完全一致）；损坏 → 抛错（fail closed）；已加载标记避免重复 IO。
- 新增只读 `func loadPersistentRecovery() async throws -> PiliAccountShadowUnresolvedPublication?`
  供测试/恢复调用方显式查询（不写、不清）。
- `pendingUnresolvedPublication` 保持 sync 观测口（文档注明：重建后需先经 async 加载）。
- 捕获 `PiliAccountEnvelopeStagingError.unresolvedRecovery` 时：从 vault 读 journal 并
  arm（不臆造 attempted ID）；随后原样上抛。
- 内存/持久 evidence 必须一致：resolve 的 token 复核同时覆盖 journal token；同值/nullable
  凭据不作为 operation identity（沿用 attemptedTransactionID）。

## 3. identity 消费者（B2e-2b，精确定义、依赖 Block3 composition）

- 目标：snapshot bridge / reverse import 与 shadow envelope 的 `durableIdentity` 对齐：
  - bridge staging export 目前是 `schemaVersion:1` + tracker identity token
    （`native_account_snapshot_service._identity(stamp)`），不含 envelope durable identity；
  - reverse import 严格解码 schema-2 捕获（`durableIdentityConfigured=false`）。
- 契约（后续组先计划后实施，不在 B2e-2a 内伪装）：导入/导出必须在同一 frozen revision
  下携带并校验每个 record 的 durable identity（缺失/不匹配 → 拒绝，零写）；identity 只作
  关联/对账，绝不授权；崩溃/重启后用 `lookupRecord` + `loadPublishedCandidate` 对齐；
  tracker token 与 durable identity 不得混用。
- 依赖：Block3 freeze→drain→export→publish composition 与启动 apply 政策；因此本计划把
  2b 明确列为**未实施子组**，避免"改名的内存 fixture 冒充持久化 identity"。

## 4. captured-window reader 回归（B2e-2c，本组必做）

- tagged-reader 计划承诺但未执行：受控 persistence seam 下调用
  `Accounts.restoreEmptyCaptured`，在其 `await writeLegacyImport` 窗口内对匿名
  stamped context 读取：`boundCsrf/boundAccessKey` = rejected（非 notInstalled/bound）、
  `csrfOf` 抛 StateError、`accessKeyOf` null、无 raw 回退、`requestRevision` 零副作用；
  窗口外显式 no-stamp 兼容路径另有断言（未安装对象直读）。
- 用 test 内 `_GatedInstallPort`（`account_reverse_import_test.dart` 先例）控制窗口。

## 5. 测试矩阵（B2e-2a/2c）

- journal 字节级：写入后读回 canonical 相等；篡改（截断/改字段/非 canonical）→
  `invalidRecoveryJournal` fail closed（新 store 写/resolve 均抛，零发布）。
- 重启恢复：write-before+unreadable-ack（未提交 + 孤儿候选保留）后**重建 store/vault**
  （同一 fault secrets）→ `loadPersistentRecovery` 与 journal 一致；follower
  `unresolvedPublication`；resolve → notCommitted → journal 清除 → follower 发布。
  write-after+unreadable-ack（已提交）同型 → committed；raw 孤儿不等于 committed。
- 崩溃点：journal 后、候选后、指针后、ack 后、清除前各自重开 → 分类仅由
  pointer==attempted/expected/foreign 决定；foreign 指针 → ambiguous，保留 journal 直到
  可判定（或按策略记录 ambiguous 并清除——见下"foreign policy"）。
- journal 写/清除故障注入（fault vault 增加 journal key 故障）：写前失败（确定无
  journal）、写后错误（清除成功→原始错误；清除失败→unresolvedRecovery）、读回持续失败
  （fail closed）、清除读回不一致（fence 保持）、取消 resolve（journal 保持）。
- 队列：journal 存在时 enqueue/direct 均 fail closed；budget/overflow/取消释放原断言保留；
  publicationConflict 路径不产生 journal。
- captured-window：见 4；保留 tagged-reader 既有 rejected/nullable/swap 测试。
- 不降 264 account/245 transaction/148 queue baselines、180/90 budgets、断言/门禁。

### foreign/ambiguous 指针策略（B2e-2a 定稿）

- observed == attempted → committed（清除 journal）。
- observed == expected（含双 nil）→ notCommitted（清除 journal）。
- 其它（foreign/损坏指针）→ 保留 journal **不自动清除**，resolve 抛
  `publicationConflict`? 不——抛新增/既有类型化 `ambiguousRecoveryPointer`，要求显式
  `clearRecoveryJournal` 外加独立确认才可继续（fail closed，安全保留）；测试断言
  零自动清除、零发布。

## 6. 边界与验收

- 小 commit：计划 → vault journal/crash ordering → store 集成 → fault vault 扩展 →
  driver 测试 → Dart captured-window 测试 → 文档；同一最终代码 SHA 显式 dispatch
  `ios.yml` + `ios-home-preview.yml`，读实际 artifacts（九 outcome、109/44/40/
  245/148/51、264+ account、BUILD/FFmpeg、preview 20/压力）。
- 明确未做（不得声称）：B2e-2b identity 对齐实施、B2e-3 生产 composition、Block3
  handoff/revert/启动 apply、安全 GC（保留引用候选）、100+ endpoint tagged 消费；
  authority/四 flag 不变；P05 未完成。
