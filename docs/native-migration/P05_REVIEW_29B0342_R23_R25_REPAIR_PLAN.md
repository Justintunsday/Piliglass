# P05 退修计划：29b0342 复审 R23–R25（journal 验证读/歧义持久策略/真实 Keychain 证据）

2026-10-15（Asia/Hong_Kong）。Codex 对 `29b0342c967ca69eb55d73c820ae458b6048e469`
（B2e-2a/2c journal 实现）独立复审 CHANGES_REQUESTED：R23（P2 验证读错误被当成
journal 不存在）、R24（P1 歧义读回自动删除持久证据，与已保存计划的 fail-closed 政策
矛盾）、R25（P2 缺少真实 Keychain 未决 journal/new-client reopen 与崩溃前缀证据）。
依据：`build/native-migration/review-29b0342c967ca69eb55d73c820ae458b6048e469-codex/REVIEW.md`。
本组只修 B2e-2a 的这三项；不重开已 PASS 的 B2e-1/tagged-reader 组件；B2e-2b/B2e-3/
GC/authority 仍未接受。边界：shadow-only、四 flag false、不接 authority、不真实账户/
设备、不碰 `youtube/`、不改 UI、不降 264 account/245 transaction/148 queue 基线、
180/90 预算、断言与九门禁。

## R23（P2）：验证读失败不得等价于 journal 不存在

- 精确现状（`PiliAccountEnvelopeStagingStore.swift` `writeRecoveryJournalVerifying`
  约 319/331/338 行）：三处 `guard (try? await secrets.read(key)) == nil else {...}`
  用 `try?` 把"读成功且无条目"与"读抛错"都变成 nil；journal 写/ack 失败 + 移除失败 +
  验证读失败可能落入"已验证干净"分支并抛通用/verificationFailed，绕过 store 的
  `unresolvedRecovery` 取证 arm；已加载 store 可能显示无 pending 而 namespace journal
  从未被证明不存在。
- 修复：删除全部 `try?` 验证读；新增
  `private func recoveryJournalAbsentVerified() async throws -> Bool`：
  `do { return try await secrets.read(key) == nil } catch { throw unresolvedRecovery }`
  （只有"成功读到 nil"才证明不存在；任何不可读都保持 unresolved）。写成功分支的验证读
  改为 do/catch：读失败 → **不删除 journal**（原样保留供 arm/resolve）→ `unresolvedRecovery`
  （不得视为 verificationFailed/干净）。写失败 catch 内：读失败 → **不删除**、抛
  `unresolvedRecovery`（绝不把读失败当"未提交"）；读成功且为 nil → 抛原始写错误；读成功
  且非 nil → `try? remove` + `recoveryJournalAbsentVerified()` 严格复核：确认 nil 才抛
  原始写错误，否则 `unresolvedRecovery`。写成功但读回不匹配 → remove + 严格复核：确认
  nil → `verificationFailed`，否则 `unresolvedRecovery`。`removeRecoveryJournalVerifying`
  已严格（读抛错传播、present → unresolvedRecovery），保持。
- 回归（fault vault 增加 `failJournalReadAfter(skip,failures)` 相位读故障与
  `failNextJournalRemovals` 移除故障；现有 `failJournalReadsForever` 在入口 precheck
  即失败，够不到清理路径）：
  1. 写成功后验证读失败（precheck 读 #1 跳过 → 验证读 #2 抛）→ vault 抛
     `unresolvedRecovery`；journal 保留；store arm 精确 token；无候选发布；follower
     `.unresolvedPublication`；随后 resolve → notCommitted（候选未写）→ journal 清除 →
     follower 发布精确一次。
  2. `journalWriteBefore`（提交前抛）+ 下一次 journal 读失败 → 抛 `unresolvedRecovery`
     （绝不原始 injected 冒充确定）；store 严格 re-read 后确认 absent → 无 fence；
     follower 正常发布。
  3. `journalWriteAfter`（提交后抛）+ journal 读失败 → `unresolvedRecovery` + 保留已提交
     journal → arm 精确 token → resolve notCommitted → follower 发布精确一次。
  4. `journalWriteAfter` + **移除失败**（读正常）→ remove 失败后严格复核 present →
     `unresolvedRecovery` + 证据保留 → arm → resolve → follower 发布精确一次。
  5. 持续验证读失败（failures=Int.max）→ fail closed（arm 读也失败）；允许读后由 vault
     pre-check backstop 拒绝 correlated 写并 arm 精确 token → resolve → follower 发布；
     全程无"读失败=干净"。

## R24（P1）：歧义读回必须保留持久证据与 fence（按已保存政策）

- 精确现状（`PiliAccountEnvelopeTransactionStore.swift` resolve 约 446–464 行）：
  构造 `.ambiguousObservedCandidate` 后无条件 `clearRecoveryJournal` 并 `unresolved=nil`；
  崩溃在清除后会丢失 operation identity，重建 store 从"无 journal"放行 follower。
- 修复（实现已保存计划：保留 + 类型化 + 显式确认）：
  - `resolveUnresolvedPublication(allowAmbiguous: Bool = false)`：
    - committed/notCommitted → 按既有顺序 durable clear 后释放。
    - ambiguous 且 `!allowAmbiguous` → **不读不写 journal**，fence 保持，抛新增
      `PiliAccountShadowTransactionError.ambiguousRecovery`（含 receipt 可经显式第二次调用
      获取）。
    - ambiguous 且 `allowAmbiguous == true` → 返回含 observed/attempted 的 resolution
      receipt **且** durable clear（显式操作者决定，记录在 receipt）后释放。
  - 文档明确：自动路径绝不把歧义当 committed/notCommitted，也不自动删除唯一持久
    correlation；`allowAmbiguous` 是显式管理确认，不是"自动安全恢复"。
- 回归：同值 foreign/identical-byte 场景：第一次 resolve 抛 `ambiguousRecovery`；
  journal 仍存在、`pendingUnresolvedPublication` 仍 armed、overwriting follower 仍
  `.unresolvedPublication`；reopen 后新 client 仍 pending；挂起中 cancel 的显式确认
  保持 journal+fence；随后显式 `allowAmbiguous: true` → ambiguous receipt（observed
  identity 非 attempted/expected）、pointer 未动（无重放）、journal 清除、follower 发布。

## R25（P2）：真实 Keychain 未决 journal / new-client reopen / 崩溃前缀

- 新增 queue driver helper（真实 `PiliAccountKeychainSecretStore(stagingNamespace:)`，
  隔离 namespace，运行于 macOS CI envelope 阶段；每阶段用**新实例** secret-store +
  vault + store 读取同一 namespace 的 Keychain 项）：
  - 前缀 1（journal-only）：仅写合法 journal（attempted=U1，expected=当前 pointer，
    digest 64 hex）→ 新 client `loadPersistentRecovery` 命中 U1；overwriting follower
    `.unresolvedPublication`；resolve → notCommitted（pointer==expected）→ journal 以
    fresh secret read 证明实际清除 → follower 发布。
  - 前缀 2（journal+candidate 无 pointer）：在 record key
    （`account-envelope-shadow-v2.<U2>`）直写候选字节、无指针 → 新 client pending →
    resolve notCommitted → pointer 未动、保留候选字节仍在（不早删）、journal 清除、
    follower 发布。
  - 前缀 3（journal+committed pointer）：raw 1-arg import 发布候选 P 后写 journal
    （attempted=P 的 transactionID，expected=发布前 pointer）→ 新 client pending →
    resolve committed（observed==attempted）→ journal 清除、pointer 未动（无重放）、
    follower 从 P 继续精确一次。
  - 前缀 4（journal+foreign/ambiguous pointer）：raw import 发布 foreign F 后写 journal
    （attempted=U4、expected=发布前 pointer）→ 新 client pending + follower fenced →
    默认 resolve 抛 `ambiguousRecovery`、journal+fence 保留 → 显式 `allowAmbiguous:true`
    → ambiguous receipt（observed==F、content match=false）、journal 清除、pointer 仍 F
    （无重放/覆盖）、follower 发布精确一次。
  - 真实性边界：这是 isolation Keychain 的 **client reopen** 证据，**不是**进程 kill；
    不伪造后者。真实 Keychain 无注入 seam，故 R23 的读/移除失败边界由 fault-vault
    相位用例覆盖（见上）。
- 现有 fault-vault 调度测试全部保留（逻辑级）；R23 相位故障用例保留在 fault vault。

## 计划文字更正（bounds）

- `P05_B2E2_PERSISTENT_RECOVERY_PLAN.md` 第 2.1 节 7：改为精确界限——只有 correlated
  publications 走 journal 前置检查；raw 1-arg `importShadow` 仍是显式 out-of-contract
  primitive（不冻结、不拦截，只能制造诚实的 foreign ambiguity）；"全部 namespace writer
  已冻结"或 production-single-writer composition 均不得声称，直至 Block3 执行/约束。

## 验收

- 小 commit/push；新最终代码 SHA 显式 dispatch `ios.yml`(release5) +
  `ios-home-preview.yml`(preview4)（先 reconcile 在途 29b0342 runs，避免 cancel/重复）；
  读实际 artifacts（264+ account、109/44/40/245/148/51、九 outcome、BUILD/FFmpeg、
  preview 20/压力）；交 Codex 独立复审。B2e-2b/生产 composition/GC/authority 未接受。
