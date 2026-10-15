# P05 退修计划：e079f79 复审 R26（冷启动 recovery preflight 泄漏 vault 争用）

2026-10-15（Asia/Hong_Kong）。Codex 对 `e079f79650ea0df6814d7ba36ac08f8c312b63b5`
独立复审 CHANGES_REQUESTED：R26（P1 queue contract）。依据：
`build/native-migration/review-e079f79650ea0df6814d7ba36ac08f8c312b63b5-codex/REVIEW.md`。
R23–R25 修复被认定为实质性正面（成功 nil 读 ≠ 读错误；默认歧义保留 journal+fence +
显式确认 API；真实隔离 Keychain 四崩溃前缀 client reopen），本轮不重做，只修 R26 并补
确定性回归。边界照旧：shadow-only、四 flag false、不接 authority、不真实账户/设备、
不碰 `youtube/`、不改 UI、不降 264 account/245 transaction/148 queue 基线、180/90
预算、断言与九门禁；B2e-2b/Block3/GC/authority 未接受。

## R26 精确现状（源码/测试/实际证据）

- `PiliAccountEnvelopeTransactionStore.enqueue`（约 310–315 行）在 FIFO 准入
  （`writerActive`/`waitingTurns`）与 `executeQueuedWrite` 的类型化重试之前先
  `try await loadRecoveryIfNeeded()`。
- `loadRecoveryIfNeeded`（约 253 行）在未加载 store 上直接
  `vault.loadRecoveryJournal()`；vault 的 `loadRecoveryJournal`
  （`PiliAccountEnvelopeStagingStore.swift` 约 271 行）用与其他发布相同的
  `beginOperation()` fence，忙时抛 `PiliAccountEnvelopeStagingError.operationInProgress`。
- 该错误从 `enqueue` 直接外泄：不是 wait/typed 重试，而是裸 `operationInProgress`。
  这不是 unknown publication，也不是调用方错误，而是**合法共享 vault 争用**。
- 确定性复现路径（既有测试，不得删除/回避）：`checkQueueContention` 第一段——
  storeA/storeB 共享 fenceVault；仅 A 已加载（`recoveryLoaded=true`）；暂停 A 的写
  （vault operation fence 被占用）；B 的**首个** enqueue 冷加载 journal 立即
  `operationInProgress`，B 的任务在恢复后 `writeB.value` FATAL。
- 实际前驱证据：29b0342 artifact 11987186236 queue compile 成功、runtime FATAL
  `PiliAccountEnvelopeStagingError.operationInProgress`（envelope 109/44/40/245、
  account 265/72/analysis 干净）。e079f79 未改此路径 → 不得重复 dispatch 已知坏 SHA，
  也不得通过预热 B 或删测试掩盖。
- 同一 `loadRecoveryIfNeeded` 前置于所有直接公共入口（adopt/install/delete/import/
  cookie/buvid/临时选择/purpose 等，约 699–1078 行）与 `resolveUnresolvedPublication`
  （约 427 行）；冷 resolve/冷直接入口同型外泄。

## 修复（最小统一面：bounded/single-flight 等价 + 明确可重试面）

- 把冷加载拆成单次尝试 `loadRecoveryOnce()`（原逻辑不动：`recoveryLoaded` 防重、
  journal 存在则严格 arm、corrupt → `invalidRecovery`、`recoveryLoaded` 仅在成功读后
  置位）与有界重试包装 `loadRecoveryIfNeeded()`：
  - **只**捕获 `PiliAccountEnvelopeStagingError.operationInProgress`（确定的前置
    vault 争用）→ 用 store 既有共享预算 `maxQueueAttempts` + `retryDelayNanoseconds`
    重试，递增既有 `queueRetrySleeps` 可观测量；耗尽 → 类型化
    `PiliAccountShadowTransactionError.publicationConflict`（不新增 loop、不加长
    超时、不与队列 attempt 语义冲突）。
  - 其它一切错误（`invalidRecovery`、`invalidRecoveryJournal`、读失败、
    `publicationFailed`/unknown 相关）**绝不重试**，fail-closed 语义原样。
  - `Task.sleep` 在取消时抛 `CancellationError`：冷加载等待中的取消不写、不占用
    FIFO、不改变任何持久状态。
  - 重入安全：同 store 并发首次使用可能各读一次同一单槽 journal，arm 的是同一持久
    evidence（幂等）；不引入不一致结论。
- 所有 `loadRecoveryIfNeeded()` 调用点自动获得该策略（enqueue、resolve、
  `loadPersistentRecovery`、直接公共入口），保持 R16 直接入口/写入者协调语义不变。

## 回归（不弱化既有断言/预算/门禁）

1. `checkQueueContention` 第一段强化为 R26 主回归：暂停 A 后，B 的首个 enqueue 必须
   **先产生重试证据**（`waitForRetrySleep(storeB, 1)`，替换原 150ms 盲等）再恢复 A；
   B 成功返回 `.record`，A/B 两个效果 + exact publication count = 4（import+adopt+A+B）
   全部断言；不得预热 B。
2. 新 helper `checkColdRecoveryContention`：
   - 并行同 store 首次使用：共享 vault 被第三方暂停发布者占住时，同一个全新 store
     的两个 enqueue 并发进入 → 各自出现重试证据 → 恢复后两者都成功（不同 key 效果 +
     exact count），FIFO 空闲、无丢失更新。
   - 有界耗尽/后续 follower：全新 store `maxQueueAttempts=3`（1ms backoff）在持续
     争用下抛出类型化 `publicationConflict`（非裸 operationInProgress），
     `retrySleepCount == 2` 精确、零发布、无 fence；争用解除后同一 store 的 follower
     enqueue 冷加载成功并精确发布一次。
   - 冷加载等待中取消：重试等待期 cancel → `CancellationError`、零发布、
     `pendingWriteCount == 0`/`writeQueueIdle`；解除争用后该 store 的后续写成功且只
     发布一次。
   - pending journal 重开 + 争用：隔离 fault vault 中直接写入合法 journal 后，由被
     暂停的 raw import 占住 vault；全新 store 冷加载先重试、争用解除后 arm fence →
     enqueue 仍被 `.unresolvedPublication` 拒绝、journal 仍在；显式
     `allowAmbiguous:true`（该前缀下 pointer 已被 raw candidate 移动，诚实歧义）清除
     journal、零重放、follower 精确一次。
   - corrupt journal 重开 + 争用：同上争用窗口内冷加载，争用解除后读回 corrupt →
     `invalidRecoveryJournal` fail closed（**不被重试吞掉**）、零发布、journal 保留。
3. 既有 b7f6692/e079f79 测试全部保留；264/245/148 计数只增不减；180/90 预算、
   strict Swift6、九门禁不动。

## 验收

- 小 commit/push；先 reconcile 在途 29b0342 release38762493416/preview38762507837
  （只读取、不取消），随后新最终代码 SHA 显式 dispatch `ios.yml`(release5) +
  `ios-home-preview.yml`(preview4)；读实际 artifacts（265 account/72 runtime、109/44/
  40/245/queue 新计数、九 outcome、source hashes、BUILD/FFmpeg、preview 20/压力）；
  交 Codex 独立复审。不得自审 PASS、不得升级 authority、不得声称 whole P05 完成。
