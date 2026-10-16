# P05 契约计划（R59–R61 聚焦修订版；仅计划）：OptionB 独立 schema-3 envelope wire —— 下一实施切片收窄为原子只读导出 + 真实 Swift 产出→Dart 消费证明

2026-10-17（Asia/Hong_Kong）。依据
`build/native-migration/review-0a78e9a786c9a306cb6f055136b6c5f565bdece9-codex/REVIEW.md`
R59–R61（对 `P05_B2E2B3…` v2 的 contract plan CHANGES_REQUESTED）。R56–R58 的具体设计
（mandatory expected pointer、单 fence + fresh journal、精确已存字节导出、maintenance 会话
生命周期、guarded bootstrap 与 raw overwrite 分离）保留；本版只修复 R59（bootstrap 次序不可
满足、排除出下一切片）、R60（cross-runtime 消费必须并入同一 mandatory outcome）、R61（导出保证
范围/合法竞争 vs out-of-band 注入/取消检查/原 enum 与真实 typed 错误/schema3-only）。
**本文件只保存修订计划：不改生产/测试、不派发 CI**；返回本 docs SHA 供 Codex contract review。
318 limited PASS 与既有失败历史保持、不重开。

## 0. 真实 API/状态事实（修订依据；源码核对）

- 错误枚举：`PiliAccountEnvelopeStagingError` 声明于 **原文件**
  `PiliAccountEnvelopeStagingStore.swift:4-7`，现有 case = `operationInProgress,
  invalidManifest, missingRecord, verificationFailed, publicationUnknown, staleTransaction,
  invalidRecoveryJournal, unresolvedRecovery, staleRecoveryJournal`——**没有** `shadowUnavailable`/
  `staleExport`/`recoveryRequired`；Swift **禁止**在 extension 里新增 enum case，只能修改原声明。
- staging（`PiliAccountEnvelopeStagingStore`）：`beginOperation()`（:495-500）为实例级
  operation fence；`recoveryJournal()`（:300-305）为**原始 secret 读 + canonical decode**（不经
  任何缓存 API）；`manifest()`（:452-455）读 current pointer；`readRecord`（:423-431）校验
  byteCount/digest 后 `codec.decode`；raw `importShadow(_:)`（:135-140）为 out-of-contract
  primitive；`loadPublishedCandidate(transactionID:)`（:402-421）**故意**可读历史 immutable
  candidate，**不构成 current pointer 证明**。secret 抽象 = `PiliAccountSecretStore`
  （`PiliAccountSecretStore.swift:4-7`：`read/write/remove`），既有队列 driver 已有
  `QueueFaultVault`（`tool/check_native_account_envelope_queue.swift:6+`）pause/读失败注入模式。
- codec（`PiliAccountLiveMemoryShadowCodec`）：`decode` 严格 schema-aware（schema-3 可含
  `generationHighWater`/`durableIdentity`，schema-2 保持 legacy key set）、enforce 既有
  byte/node/UTF16 上限；`encode`（:135-142）才是重编码路径。staging 已存字节 = `codec.encode`
  产物（`publishShadow` :166-167），manifest digest 校验精确字节。
- transaction（`PiliAccountEnvelopeTransactionStore`）：`loadPersistentRecovery()`（:260）经
  `loadRecoveryOnce` 缓存——**不是 fresh journal 缺席证明**；`adoptMissingIdentities()`
  （:783-820）要求 schema-2、发布 **schema-3**（:811，minted `durableIdentity`）；schema-3 已
  adopted → no-op receipt `transactionID: nil, adopted: 0, adoptedIdentities: []`（:792-795；
  不得据此伪造 pointer）。
- coordinator（`AccountWriteBackCoordinator`）：`freeze()` 无 unfreeze（终态）；
  `beginMaintenance()`/`end(permanent:)` 为 drain/admission barrier（生产先例
  `lib/utils/storage.dart:112-139`）。`end(permanent:false)` **只恢复 admission**，不是单写者
  handoff 证明。
- Dart capture/reverse：`NativeAccountSnapshotService._capture/_verify` = optimistic revision
  复核（capture-local，**非** freeze lease）；`NativeAccountReverseImport.decode`
  （`native_account_reverse_import.dart:30-42`）严格 schema 2/3、schema-3 login record 必须有
  canonical `durableIdentity`、输出只读 `recordDurableIdentities`（关联 label，绝不授权）；
  `pubspec.yaml:70` 有直接依赖 `crypto: ^3.0.6`（Dart 端 sha256 可用）。
- CI 事实：`ios.yml` 的 `group-account-dart`（:315-324）在 `group-account-envelope`
  （:334-337）**之前**运行整个 `test/utils/accounts/`；aggregate（:556-577）只绑定
  `steps.group-account-envelope.outcome`；`test/services/native_accounts/` 当前**不存在**且不被
  任何既有 sweep 运行（`test/services/native_login/` 只按具体文件跑，:474-475）。
  `tool/check_native_account_envelopes.py` 的 `summary.update(status="passed", …)` 在全部阶段
  之后（:387），在此之前任何异常 → `status=failed` → exit 1。

## 1. R56 解决方案（R61 精确化）—— 原子 fresh journal + pinned current pointer 只读导出

### 1.1 签名/结果/wire/错误（修改**原 enum** + 真实 typed errors）

```swift
struct PiliAccountEnvelopeExport: Sendable, Equatable {
  let transactionID: UUID      // exact current immutable publication pointer（线性化点）
  let envelopeBytes: Data      // pointer 命名记录的精确已存字节（byte-identical；不重新 encode）
  let envelopeSHA256: String   // sha256(envelopeBytes)，provenance/关联用
}

// 修改原声明 PiliAccountEnvelopeStagingStore.swift:4-7，新增且仅新增两个 case：
//   case shadowUnavailable   // 不存在可导出的 schema-3 shadow
//   case staleExport         // expectedTransactionID != 当前 pointer
func exportCurrentShadow(expectedTransactionID: UUID) async throws -> PiliAccountEnvelopeExport
```

- `expectedTransactionID` **必填**（pinned-current）。unpinned capture 模式不在本契约/切片。
- **schema3-only validated exporter**：返回前对已存字节调用严格 `codec.decode` 并要求
  `schemaVersion == 3`（enforce 既有 byte/node/UTF16 上限）；**绝不调用 `codec.encode`**、
  绝不 JSON 重解析重编码，返回 `secrets.read` 的原始 `Data` 本身。
- 错误映射（全部为真实 case；无新造平行名称）：

  | 情形 | 错误 |
  | --- | --- |
  | fence 忙（同 vault 并发调用） | 既有 `operationInProgress` |
  | journal 有效存在（unresolved） | 既有 `unresolvedRecovery` |
  | journal 字节损坏（canonical decode 失败） | 既有 `invalidRecoveryJournal`（原样重抛） |
  | journal 读取抛错（非取消） | 既有 `unresolvedRecovery`（不可证明缺席 → fail closed） |
  | pointer 缺席，或已存字节严格解码为 schema 2（未 adoption） | **新增** `shadowUnavailable` |
  | `expectedTransactionID != 当前 pointer` | **新增** `staleExport` |
  | pointer 记录缺席 | 既有 `missingRecord` |
  | byteCount/digest 不符，或 digest 一致但严格解码失败 | 既有 `verificationFailed` |
  | 任务取消 | Swift `CancellationError`（精确类型；**绝不**映射为 recovery 错误） |

### 1.2 读线性化点与次序（一次 `beginOperation` fence；R61 取消检查显式化）

1. `try beginOperation()`；`defer { operationInProgress = false }`——**所有**退出路径
   （成功/typed 错误/取消）都释放 fence。
2. `try Task.checkCancellation()`（**first IO 之前**）。
3. **fresh** journal 读：`try await recoveryJournal()`（原始读 + canonical decode，不经缓存
   API）。非 nil → `unresolvedRecovery`；decode 抛 `invalidRecoveryJournal` → 原样重抛；
   读取抛错 → 先 `catch is CancellationError { throw error }`，其余映射 `unresolvedRecovery`。
   **零写；journal 原样保留；绝不 clear/resolve/replay。**
4. `try Task.checkCancellation()`（journal 读 await 之后）。
5. `manifest()` → current pointer；nil → `shadowUnavailable`；`transactionID != expected` →
   `staleExport`。历史 candidate/descriptor **不得**替代 current pointer
   （`loadPublishedCandidate` 不用于导出）。
6. `try Task.checkCancellation()`（pointer 读 await 之后）。
7. `secrets.read(key(pointer))`：缺席 → `missingRecord`；`count != byteCount` 或
   `digest != sha256` → `verificationFailed`。
8. `try Task.checkCancellation()`（record 读 await 之后）。
9. 严格 schema-3 校验（§1.1）：schema 2 → `shadowUnavailable`；解码失败 → `verificationFailed`；
   不产生任何写、不 encode。
10. `try Task.checkCancellation()`（**return 之前**）；计算 `envelopeSHA256` 并返回；fence 在
    返回时释放——**返回即 as-of 线性化点的不可变快照**。
11. fence 释放后 winner 可移动：导出**不承诺持续货币**、不自动 revalidate；消费方按需以新
    expected pointer 重新调用。

### 1.3 保证范围（vault-as-of-persistent-journal；**不是**全局权威 fence）

- 本导出保证 = (a) 线性化点处，经 vault 原始读路径 **fresh 证明**持久单槽 recovery journal
  缺席；(b) 返回字节 = pinned pointer 命名的**精确已存字节**，严格 schema-3 校验且 digest
  一致；(c) 该序列对**同一 vault 实例**的其它 staging 调用由 `operationInProgress` 串行化。
- **不保证**：对所有 Dart/Native writer 的全局 owner/authority fence；其它 actor（如
  TransactionStore）的 **in-memory** fence；journal-read 线性化点之后发生的 **out-of-band/
  外部写入**（单次读是 point-in-time 证据）。分属不同 vault、外部 secret store 注入属**明确
  不支持**——测试必须区分"合法同 vault 竞争"与"合成外部注入"，不得对外部注入承诺
  `recoveryRequired`；若未来要支持，须另立**经 review 的验证协议**，本计划不承诺。
- in-memory 过渡窗精度（替代 v2 "armed unknown 必有持久 journal" 的过宽说法）：
  `clearRecoveryJournal` 在验证 clear 成功后**先释放 vault fence**，transaction actor 之后才清
  自己的 in-memory unresolved 状态——存在"持久 journal 已缺席、in-memory fence 仍 armed"的
  过渡态。staging-only 导出无法观察其它 actor 的内存；因此**未来调用方必须自行检查其已知
  in-memory fence**，导出结果**不是** handoff/authority 授权。显式恢复仍是单独的、经 review 的
  操作；导出绝不自动 resolve/clear/replay。
- 导出的 `envelopeSHA256`/pointer 仅作**关联**（binding/label），绝不授权 apply/revert/handoff；
  future unknown/admission 表保持 **OPEN**（见 §2.3）。

### 1.4 受控证明矩阵（实现切片必须包含；driver = `tool/check_native_account_envelope_export.swift`）

| # | 用例 | 设置 | 断言 |
| --- | --- | --- | --- |
| 1 | 成功导出（schema-3，pinned current） | 真实 Dart capture →（fixture-only）既有 import 原语 + `adoptMissingIdentities()`（reviewed adoption，publication 为真实 pointer）；pinned export | bytes == 存储字节；schema-3 严格校验通过；digest 匹配；**成功写计数 0**；pointer/record 不变 |
| 2 | pointer 缺席 | 空 vault / `discardShadow()` 之后 | `shadowUnavailable`；零写 |
| 3 | schema-2 pointer（未 adoption） | 仅既有 raw import 发布 schema-2 后 | `shadowUnavailable`；零写；不 encode、不改动 |
| 4 | expected != current | 导出前合法同-vault B 发布新 pointer | `staleExport`；不返回旧/新字节；winner 完整 |
| 5 | historical candidate ≠ current | 旧 descriptor/candidate 存在而 pointer 已移 | `staleExport`；不得用 `loadPublishedCandidate` 替代 |
| 6 | journal 有效存在（armed） | 导出**开始之前**：真实 unknown-ack 路径 arming，或经同一 vault secret store 写入 canonical journal bytes | `unresolvedRecovery`；journal 原样保留；零写；绝不 clear/resolve/replay |
| 7 | journal 损坏 | 导出开始之前写入非 canonical journal bytes | `invalidRecoveryJournal`；字节保留；零写 |
| 8 | journal 不可读 | 导出开始之前故障 store 对 journal key 读抛错（非取消） | `unresolvedRecovery`（绝不当作缺席）；字节保留 |
| 9 | 合法 writer 竞争（export paused） | 故障 store 在 journal 读之后的 manifest/record 读上 pause；同 vault 合法 writer（staging publication 或第二 export）进入 | writer 得 `operationInProgress`、零写、winner/export 不受影响；resume 后导出成功；release 后 writer 可合法发布 → 旧 expected 导出 → `staleExport` |
| 10 | 取消（多点） | (a) manifest 读 pause 后 cancel+resume；(b) record 读 pause 后 cancel+resume；(c) journal 读自身抛 `CancellationError` | 精确 `CancellationError`（(c) 不被映射为 recovery 错误）；零写；pointer/journal/record 不变；fence 释放（后续操作可进入）；无 journal 残留 |
| 11 | adoption no-op | schema-3 已 adopted 后再次 `adoptMissingIdentities()` | receipt `transactionID == nil`/`adopted == 0`（:792-795）；不伪造 pointer；随后 pinned export bytes 不变 |
| 12 | same-process reopen | 新 staging/transaction store 实例、同一真实 Keychain namespace | pinned export bytes/digest 与 reopen 前一致（**同进程**新实例；**非** process-kill 证明） |

- 明确**不支持**、不测试为保证的：journal-read 之后的 out-of-band 外部注入；分属不同 vault
  actor 的同 namespace 并发；其它 actor 已被 clear 的 in-memory fence。
- fixture 准备诚实性：既有 import/adopt 原语只用于**隔离 fixture**，**显式不是** production
  bootstrap 证据，不得据此声称 initial adoption 协议已批准。

## 2. R57 解决方案 —— composition 会话生命周期（Block3 设计；本切片不获取 lease）

### 2.1 选择的状态机（不再引用终态 `freeze()`）

- **quiesce session**（composition-owned）= `beginMaintenance()` 独占 token：success/失败/取消 →
  `finally end(permanent:false)`；`close` 路径 → `end(permanent:true)`。`freeze()` 保持终态、
  仅 authority 语义；maintenance **绝不**解除既有 authority freeze。生产先例 = `GStorage.compact/close`。
- release/retain 规则表：
  | 结局 | admission | token | 持久状态 |
  | --- | --- | --- | --- |
  | success（导出/迁移完成） | `end(false)` 恢复 | 恰一次 | 无未决 |
  | precommit failure / 取消等待 | `end(false)`；drain 自身零写 | 恰一次 | 无未决 |
  | pending acquisition 被取消 | **禁止 abandon**：仍 await 到 grant 后立即 `end(false)` | 恰一次 | 不遗留 `_maintenance=true` |
  | postcommit unknown（Native） | token 按上述 end | 恰一次 | **unknown journal/fence 保留**，与 admission 恢复相互独立；不得以 end 当 thaw |
- 已 admitted 的 Dart 效应**不假取消**：drain 等其完成；Dart future 取消 ≠ Swift Task 取消。
- pending acquisition 取消回归（确定性）：holder 持 token → A 等待 acquisition → 取消/放弃 →
  holder `end(false)` → A 得到 token 后立即 `end(false)` → admission 恢复、无越权写。

### 2.2 参与写者清单（drain 覆盖）与明确未覆盖

- 已接 entry 的 writer（drain 可覆盖）：`Accounts.set/selectTemporarily/refresh`（`tryAdmit`）、
  install/import/delete ports、`LoginUtils.setWebCookie`/`onLoginMain`/`onLogoutMain`、
  `RequestUtils.syncHistoryStatus`、`Accounts.clear`/匿名 reset、`GStorage.compact/close`、
  Native HTTP lease finish。
- 明确**未覆盖/不等价**：coordinator 之外的裸 Hive 写入、页面只读、snapshot capture（只读）、
  未经 port 的第三方写入；"已命名 coordinator" ≠ all-writer freeze。

### 2.3 R61 精确化：单写者排他性未证明

- `end(permanent:false)` 只恢复 admission，**不构成** single-writer handoff 证明；
  future unknown/admission 表（哪些 writer 允许在 handoff 期间运行、需要何种显式 global retain
  fence）保持 **OPEN**，直至该 fence 设计经 review。本切片与导出结果**不得**声称任何 handoff
  排他性、不得用于授权 handoff/启动 apply/revert。

## 3. R58 解决方案（R59 修正）—— 未来 bootstrap/binding（OPEN/deferred）与下一可实施切片

### 3.1 修正的未来 bootstrap 序列（本切片不实施；v2 的"先 export 再 bootstrap"作废）

- v2 §3.2 次序矛盾：bootstrap 要求 pointer **缺席**、export 要求 pointer **存在**，无状态同时
  满足；**禁止**导出不存在的初始 pointer、**禁止**以 no-op receipt 的 nil pointer 伪造关联。
- 修正的未来序列（deferred；待另行 review）：真实 reviewed session 下 capture Dart owned
  schema-2 → guarded bootstrap（receipt **P0** = 真实新 pointer）→ adoption receipt **P1** →
  `exportCurrentShadow(expected: P1)` 得权威 bytes+digest → binding；对**显式 already-adopted**
  分支：verified pre-adoption P0 + subsequent pinned export。
- 未来 bootstrap 写入必须另有 attempt/journal/failure-cancel-crash 设计并**先行**获批；不得
  隐式 raw overwrite；raw `importShadow` 继续 out-of-contract（driver fixture 用途除外）。
- 删除 `bootstrapShadow`/`bootstrapRefused` 于下一切片：见 §3.3。

### 3.2 owned immutable binding（未来 gate；本切片不构建）

- 形状（待 §3.1 获批准后另立 gate）：
  ```
  bindingID: UUID
  expectedPointer: String            // P1（Native immutable publicationID）
  envelopeSHA256: String             // 权威导出 digest
  captureRevision: int               // Dart capture-local，仅乐观复核证据
  records: [{ storageKey(UTF16), mid, generation(capture-local), durableIdentity? }]
  ```
- 规则：generation 是 capture-local，**不是**跨重启 request credential；同 key/MID ≠ 同
  incarnation；missing/mismatched/reused context → typed 拒绝、零写；labels 只作关联、绝不授权；
  tracker token 不进入 binding。

### 3.3 下一可实施切片（bounded；**仅**原子只读导出 + 真实 Swift 产出→Dart 消费证明）

改动文件（无其它）：
- 修改 `ios/Runner/Native/Persistence/Accounts/PiliAccountEnvelopeStagingStore.swift`
  （`exportCurrentShadow` + §1.1 两个新 case）。
- 新增 `tool/check_native_account_envelope_export.swift`（driver，矩阵 §1.4）。
- 修改 `tool/check_native_account_envelopes.py`（cross-runtime 阶段）。
- 新增 `test/services/native_accounts/native_account_schema3_export_consumption_test.dart`（consumer）。
- 新增 `tool/qa_native_account_envelope_export.py`（本地 mock QA）。
- 修改 `.github/workflows/ios.yml`（trigger paths + artifact `*.bin`；**不动** step/aggregate）。
- **不**新增 MethodChannel 命令；**不**实现 `bootstrapShadow`；**不**改 transaction store/coordinator。

1. **Swift 导出**：§1.1 签名 + §1.2 次序/取消 + §1.1 错误映射（原 enum 修改）。
2. **Swift driver**：fixture 准备 = 真实 Dart capture（`live-memory.json`）→ 既有 raw import
   → `adoptMissingIdentities()`（reviewed；publication 为真实 pointer；fixture-only，非
   production bootstrap 证据）；随后执行 §1.4 矩阵。driver 以 argv 接收
   `[liveMemoryPath, metadataPath, wirePath, sourceSHA, workflowSHA]`，写出：
   - `build/native-account-envelope-check/schema3-export.json`（严格字段：
     `schema:"pili.account.schema3-export.v1"`、`sourceSHA`、`workflowSHA`（null 可）、
     `transactionID`、`envelopeSchemaVersion:3`、`envelopeByteCount`、`envelopeSHA256`、
     `wireFileName:"schema3-export-wire.bin"`）；
   - `build/native-account-envelope-check/schema3-export-wire.bin` = **精确已存字节**
     （CryptoKit digest 与 JSON 字段一致；不 encode、不重编码）。
   driver 打印确定性 `N native account envelope export checks passed`（实现按精确矩阵断言；
   实际以 CI 观察记录，计划不预写数字）。
3. **Python 阶段（并入同一 mandatory outcome；R60）**：在 `check_native_account_envelopes.py`
   现有 authority 阶段之后、`source-revision-after`/`source_hashes()` 复核之前、
   **`summary.update(status="passed", …)` 之前**顺序执行：
   a. **fresh cleanup**：main() 起始 unlink 列表加入 `schema3-export.json`、
      `schema3-export-wire.bin`、`schema3-export-compile.log`、`schema3-export-result.log`、
      `schema3-export-consumer-analyze.log`、`schema3-export-consumer-test.log`（缺失=失败；
      不存在 stale 产物被接受）。
   b. 编译 `EXPORT_SOURCES`（镜像 `TRANSACTION_IDENTITY_SOURCES` 编译闭包 + 新 driver）→
      `schema3-export-compile.log`（沿用既有 180s per-command 上界；不改任何既有值）。
   c. 运行 driver → `schema3-export-result.log`（沿用既有 90s 上界）。
   d. **严格产物校验**（absent/stale/digest/schemaSHA 全失败）：两文件必须存在；metadata 以
      `strict_object`（拒重复键）+ 精确 key set 解析；`sourceSHA`/`workflowSHA` == python 已
      验证的 `source_sha`/`GITHUB_SHA`；`envelopeSchemaVersion == 3`；
      `envelopeByteCount == len(wire bytes)`；`envelopeSHA256 == sha256(wire bytes)`——对
      **精确文件字节**计算，绝不做 JSON parse→reencode digest。
   e. consumer analyze：`dart analyze --fatal-infos test/services/native_accounts/` →
      `schema3-export-consumer-analyze.log`（默认 180s 上界）。
   f. consumer 执行：`flutter test --no-pub --reporter expanded
      --dart-define=NATIVE_ACCOUNT_SCHEMA3_EXPORT=<abs metadata path>
      test/services/native_accounts/native_account_schema3_export_consumption_test.dart` →
      `schema3-export-consumer-test.log`；**新显式有界预算 240s**（新增 allowance；既有
      180/90/240/native-account 120/60 任何数值不变）。从 expanded 报告解析实际通过数并记录；
      consumer 打印 `schema3-export-consumed <transactionID> <sha256>`，python 断言其 digest ==
      metadata digest（证明消费的是这些字节，而非仅"存在产物"）。
   g. **消费后复核**：重新读取两产物、重算哈希并与 (d) 记录一致（output hashes rechecked after
      actual consumer execution）；不一致=失败。
   h. summary 新增 `schema3Export{metadataSHA256, wireSHA256, wireByteCount, transactionID,
      consumerTests, consumerAnalyzeLog, consumerTestLog}`；`source_hashes()`/
      `clean_contract_sources()` 列表加入新 driver、consumer test、
      `tool/qa_native_account_envelope_export.py` 与 `EXPORT_SOURCES`（source ledger 覆盖新
      driver/consumer/harness）。
   i. 失败语义：本阶段任何异常 → 既有 except → `status=failed` → exit 1 →
      `steps.group-account-envelope.outcome=failure` → 既有 aggregate 失败。**aggregate 与
      step 定义不动、不弱化。**
4. **Dart consumer**（`test/services/native_accounts/native_account_schema3_export_consumption_test.dart`）：
   - 位置在早期发现目录 `test/utils/accounts/` **之外**（该目录由 `group-account-dart` 在
     envelope 步骤之前整体运行，不能依赖未产出的 fixture）；不加入任何 ios.yml 的 analyze/
     test 列表，只由 envelope pipeline 分析+执行。
   - `const String.fromEnvironment('NATIVE_ACCOUNT_SCHEMA3_EXPORT')`；为空 → 立即失败
     （required fixture path；**无** default、**无** skip、**无** pass-on-missing）；metadata/
     wire 两文件必须存在。
   - 读取 wire **精确字节** → `sha256`（`package:crypto`，pubspec.yaml:70）== metadata
     `envelopeSHA256`；byteCount、`envelopeSchemaVersion == 3`、canonical `transactionID` 一致。
   - `utf8.decode(..., allowMalformed: false)`（对同一字节）→ `jsonDecode` →
     `NativeAccountReverseImport.decode`（现有严格 schema-3 consumer，B2e-2b-1 `ea60931`）：
     断言 schema-3 通过、login records 的 `recordDurableIdentities` 全为 canonical lowercase
     UUID、storedOrder/ownerOrder/selections/history 语义合法；labels 只作关联（绝不授权）。
   - 文件内确定性正例 + 本地负例（对解析副本做 mutate → `NativeAccountReverseImportException`），
     不修改产物文件；用例数以实际 CI 输出观察并记录（计划不预写数字）。
   - 纯离线：无网络、无真实账户、无 Hive 写。
5. **ios.yml**：push/pull_request `paths` 各加 `- "test/services/native_accounts/**"` 与
   `- "tool/check_native_account_envelope_export*"`；artifact `native-account-envelope-contracts`
   （:344-347）增加 `build/native-account-envelope-check/*.bin`（wire 证据持久化）。
   **不新增 step**（consumer 由既有 `python3 tool/check_native_account_envelopes.py` 在
   `group-account-envelope` 内驱动，天然并入 `ACCOUNT_ENVELOPE_OUTCOME`）；aggregate 列表不变。
6. **Python 负例/mock QA（`tool/qa_native_account_envelope_export.py`；本地 mock，非运行时证据）**：
   导入真实 `check_native_account_envelopes.py` 模块，只 mock 进程执行 seam 与 OUTPUT 目录，
   驱动**真实**新阶段代码：missing wire、stale metadata（SHA 不匹配）、mutated wire（digest
   不匹配）、consumer failure（returncode≠0 / 报告缺 pass）→ 断言新阶段 raise 且 `status` 不写
   passed（退出码 1）；另含 happy mock 对照。静态 wiring 断言：main() try 内调用新阶段且位于
   `summary.update(status="passed"` 之前（AST/文本级）、ios.yml 仍运行
   `python3 tool/check_native_account_envelopes.py` 且 aggregate 仍绑定
   `ACCOUNT_ENVELOPE_OUTCOME: ${{ steps.group-account-envelope.outcome }}`。输出标注
   "local mocked QA — NOT Mac/Swift/Dart/device runtime evidence"。
7. **计数/预算不变（R60）**：producer 8/观察 10/2 goldens 不变；既有各阶段计数下限/实测基线
   （envelope/native 109、负例下限 43（实测 44）、synthetic 1、staging ≥40、
   transaction 合计 ≥245（实测 285=108+177）、queue ≥40（实测 292）、authority ≥51）不变；
   既有 180 compile/90 runtime/240 producer、native-account 120/60、`test/utils/accounts/`
   套件（322 基线）与其 analyze 日志全部不变；新 driver compile/runtime 沿用 180/90 上界（新
   命令、既有值不变）；新 consumer analyze 180 / consumer test 240 为新命令的独立显式上界；
   新 driver/consumer 计数以实际 CI 观察记录。
8. **明确未实施 gate**（§3.4）见下；本切片结果**不得**声称双向 handoff、bootstrap、composition
   或 whole P05。

### 3.4 明确未实施 gate（本切片不得声称）

- `bootstrapShadow`/initial adoption 写入协议、owned binding/adoption 关联、production
  composition/startup apply/revert、双向 durable-identity carriage、MethodChannel 命令、
  authority handoff、nonempty-target reverse apply/idempotency、GC；future unknown/admission 表
  保持 OPEN（见 §2.3）。

## 4. 边界

- 四 flag false；Flutter/Dart fallback、Aether 独立、不读/改 `youtube/`、无 UI visual/
  真实账户写/auth/captcha/设备伪造；不改任何既有断言/预算/门；不重发任何未变 SHA。
- 未来 bootstrap 写入在**另行 review 批准**前不实施；导出结果绝不超过 §1.3 保证范围。
- 本 docs-only 修订先经 Codex contract review；通过后才实现 §3.3 切片（新 code SHA + BOTH
  workflow 各一次 + 独立复审）。318 limited PASS 与既有失败历史保持。
