# P05 下一组计划（R66–R69 修订版；契约评审）：guarded FIRST 发布/bootstrap（create-only expected-absent）+ captured Dart→adopted Native 关联 + composition 会话/recovery 依赖

2026-10-17（Asia/Hong_Kong）。依据
`build/native-migration/review-081f2d5cf2718a0cf799b481575ac32ea9559188-codex/REVIEW.md`
R66–R68（对上一版计划的 contract plan CHANGES_REQUESTED）、
`build/native-migration/review-afebb3c52d95311ea4d215152a397af8455a9fe8-codex/REVIEW.md`
R69 聚焦修正（staging/authority 编译闭包含 staging store 而不含 TransactionStore；candidate
阶段 IO 抛错与提交后 journal 清除真值）与 `review-6b39ac1…-codex` FINAL DISPOSITION 的
"Next authorized substantive work"。
**本文件只保存修订后的具体契约计划（docs-only，不实现、不派发 CI）**；通过 Codex CONTRACT
review 后才实施。6b limited PASS 仅覆盖只读导出 + selected fixture（不重开）；本计划只选定
一个有界下一组，不把未来 §2/3.1–2 视为整体获批。

## 0. 现状与确定性事实（源码核对）

- 已验收（6b）：`exportCurrentShadow(expectedTransactionID:)` 原子只读导出（单 shared-vault
  fence、fresh persistent journal fail-closed、精确已存字节、严格 schema3、zero writes、
  显式 post-successful-await 取消）。
- **缺口**：不存在 create-only expected-absent 发布原语。raw `importShadow(_:)`（:135-140）
  out-of-contract；correlated `importShadow(_:expectedTransactionID:candidateTransactionID:
  recoveryKind:)`（:149-159）要求非可选 `expectedTransactionID: UUID`（无法表达“期望缺席”）。
  内部 `publishShadow`（:161-266）的 `expectedTransactionID: UUID?` 中 `nil` 只表示“无期望”
  （raw 跳过 CAS）。
- **kind 事实**：`PiliAccountShadowUnresolvedWriteKind: String` 声明于
  `PiliAccountEnvelopeTransactionStore.swift:138-141`，现 case = `adoptIdentities, install,
  importRecords, delete, cookieSave, cookieDelete, cookieDeleteAll, temporarySelection,
  purposeChange, credentials, activated, buvidSeed`——**没有 bootstrap**；无任何 switch 穷举，
  冷加载（`loadRecoveryOnce` :323 与 `armFromRecoveryJournal` :340）仅做
  `rawValue` 转换，未知 kind → `PiliAccountShadowTransactionError.invalidRecovery`。
  `PiliAccountEnvelopeRecoveryJournal.encode` 不校验 kind 形状（仅 ≤4096B），decode 才校验
  （非空/≤64 UTF16/可打印 ASCII 无空格）。
- **fence 事实**：staging `operationInProgress` 只是**实例级序列化门**，`defer` 在 throw 时也
  释放；它**不是** owner/memory fence，也不会 arm 任何 TransactionStore `unresolved`。只有
  `publishCandidate`（transaction）捕获 `publicationUnknown` 时才 arm 自己的内存 fence。
  跨 actor 的持久护栏只有单槽 journal。
- `publishShadow` 现有 collision 检查**只查 record key**（:189-193），不查 descriptor key；
  candidate 阶段失败清理移除 record+descriptor 并验证清 journal（`clearJournalAfterFailedAttempt`），
  ack 未知 → `publicationUnknown` journal 保留；确定未提交 → 清理+原错误；验证提交 → 验证清
  journal + receipt。
- adoption：`adoptMissingIdentities()`（:783-820）要求 schema-2 → 经 reviewed
  `publishCandidate` 发布 schema-3（minted canonical labels/high-water）；schema-3 已 adopted
  → no-op receipt `transactionID: nil`（:792-795），不得伪造 pointer。
- Dart capture：optimistic revision 复核（capture-local，无 lease）；coordinator
  `beginMaintenance()`/`end({permanent})`；`end(false)` 只恢复 admission，不是 handoff 证明。

## 1. R66 —— bootstrap 的 kind / fence 契约（精确选择）

### 1.1 语义 kind（新增原 enum case；无 caller 字符串；R69 下层常量修正）

- **编译闭包事实**（`tool/check_native_account_envelopes.py` 实测）：`STAGING_SOURCES`
  （:44-53）与 `AUTHORITY_SOURCES`（:89-100）只编译 `PiliAccountEnvelopeStagingStore.swift`，
  **不含** `PiliAccountEnvelopeTransactionStore.swift`；transaction 文件只出现在
  `TRANSACTION_SOURCES`（:57-69）/`TRANSACTION_IDENTITY_SOURCES`（:74-86）/`QUEUE_SOURCES`
  （:105-117）/`EXPORT_SOURCES`（:122-134）闭包。因此 staging 层**不得**直接引用
  `PiliAccountShadowUnresolvedWriteKind`（会使既有 STAGING/AUTHORITY 严格编译阶段失败）；
  split 阶段与 180/90 预算不变，不把 transaction/reducer/parser 依赖加进这些闭包。
- **下层固定常量**（R69 首选修正）：在既有 staging 文件的
  `PiliAccountEnvelopeRecoveryJournal`（:36-117）新增 `static let bootstrapKind = "bootstrap"`。
  bootstrap 写入路径以该常量作为 journal kind；bootstrap 入口不暴露 kind 参数。既有
  correlated 公共入口的 `recoveryKind: String?` 与 TransactionStore `kind.rawValue`（:462）
  行为逐字节保留，本组不扩大修改。
- 在**原声明** `PiliAccountShadowUnresolvedWriteKind`（TransactionStore :138-141）新增
  `case bootstrap = "bootstrap"`（字面 rawValue）。冷加载两处 rawValue 转换
  （`loadRecoveryOnce` :323、`armFromRecoveryJournal` :340）无需改动即识别；无 switch 需更新。
- **枚举↔常量一致性由 driver 证明**（新阶段编译闭包同时含两个文件，见 §4.2）：断言
  `PiliAccountShadowUnresolvedWriteKind.bootstrap.rawValue == PiliAccountEnvelopeRecoveryJournal.bootstrapKind`；
  并做**真实冷加载识别**断言：staging bootstrap 写入的 journal 被 TransactionStore 冷加载
  识别为 `.bootstrap` pending fence（而非 `invalidRecovery`）；伪造/未知 kind 仍
  `invalidRecovery`（§1.3、矩阵 12）。
- `PiliAccountEnvelopeRecoveryJournal` 的 kind 形状校验由**构造保证**：bootstrap 写入路径
  不再有 caller 输入；`"bootstrap"` 天然满足 decode 约束（非空/ASCII/≤64）。无效/伪造 kind
  仍需由 decode 拒绝（既有行为），不新增语义。

### 1.2 双层 fence 契约（durable vs owner-memory）

- **durable fence** = 单槽持久 journal。bootstrap/followers 的 fresh 读是唯一跨 actor 护栏：
  - 任何 in-contract 后续发布（correlated import、bootstrap、adoption、队列写）在 journal
    存在时 fail closed（staging → `unresolvedRecovery`；TransactionStore 冷加载把
    `.bootstrap` kind 转为 pending fence）；
  - 新 actor/新进程只需 fresh 读即可看到证据，**不依赖**任何 in-memory fence。
- **owner-memory fence** = 仅 TransactionStore 自己的 `unresolved`。bootstrap（staging 层）
  不 arm 内存 fence；`publicationUnknown` 之后调用方必须自行冷加载/（未来）走显式恢复。
  **禁止**从 staging defer 推导出全局内存 fence 承诺。
- raw out-of-contract `importShadow` 仍在保证之外（文档化，不重开）。

### 1.3 fresh store 冷加载与显式恢复（isolated fixture）

- driver 断言 `PiliAccountShadowUnresolvedWriteKind.bootstrap.rawValue ==
  PiliAccountEnvelopeRecoveryJournal.bootstrapKind`（§1.1）。
- 冷加载断言（journal 由真实 staging bootstrap 路径写入）：`expectedPreviousTransactionID
  == nil`、`attemptedTransactionID` == bootstrap 入参 ID、`attemptedCandidateSHA256` ==
  候选编码 digest、`kind == .bootstrap`；TransactionStore 冷加载识别为 `.bootstrap`
  pending fence，不误报 `invalidRecovery`。
- **正常 bootstrap/只读导出绝不**自动 resolve/clear/replay unknown。
- 显式 `resolveUnresolvedPublication()` 仅在**隔离 fixture**上单独测试分类：pointer ==
  attemptedID → committed；pointer 仍 nil（== expectedPrevious nil）→ notCommitted；其它
  pointer → ambiguous。分类结果不写回 binding、不授权。

## 2. R67 —— create-only 写入生命周期（精确实现选择）

### 2.1 私有 expectation 重构（单一 fenced 序列，无 TOCTOU）

- 把 `publishShadow` 的私有参数从 `expectedTransactionID: UUID?` 改为：
  `private enum ShadowPublicationExpectation { case uncorrelated, exact(UUID), absent }`；
  公共入口映射：raw → `.uncorrelated`（保持跳过 CAS）、correlated → `.exact(id)`（保持
  `staleTransaction`）、新 `bootstrapShadow` → `.absent`。判定点与今日 CAS 同一位置：
  `.absent` 时 `guard previous == nil else { throw bootstrapRefused }`。
  **不**在 fence 外先查缺席再调用 raw（消除 TOCTOU）；**不**从 bootstrap 内部调用公共
  fenced import（会 `operationInProgress`）。既有 raw/correlated 语义逐字节保留。
  create-only 只证明**当前 pointer 在 fence 内缺席**，不证明该 namespace 从未发布、
  无孤儿历史，或可安全重置 high-water，也不授权生产新 namespace。
- `bootstrapShadow` 签名（最终）：
  `func bootstrapShadow(_ input: Data, candidateTransactionID: UUID) async throws
  -> PiliAccountEnvelopeStagingReceipt`（kind 固定为下层常量
  `PiliAccountEnvelopeRecoveryJournal.bootstrapKind`，无 caller kind 参数）。

### 2.2 输入/collision 边界（全部在首个持久写之前）

- 输入：`codec.decode` + `codec.encode(candidate)`（内存拥有 canonical 候选）；**仅接受
  schema-2**（zero-label 初始准入；schema==3 → 新 `invalidBootstrap`）；codec/限额错误按既有
  类型原样传播。
- journal fresh 读：有效存在 → `unresolvedRecovery`；损坏 → `invalidRecoveryJournal`；
  不可读 → `unresolvedRecovery`（与导出一致）。
- pointer present → `bootstrapRefused`（零写）。
- **record 与 descriptor 双重 collision 检查**（新）：`key(id)` 或 `descriptorKey(id)` 任一
  存在 → `bootstrapRefused`，**绝不覆写**试图复用 ID 下的孤儿 immutable descriptor。（既有
  correlated 路径只查 record 的行为不变，作为已验收语义明确保留，不在本组扩大修改。）
- 原 enum 新增两个 case（照旧只加在原声明 staging :4-7）：`bootstrapRefused`（状态
  前置/collision）与 `invalidBootstrap`（schema 策略拒绝）。其余错误复用既有类型。

### 2.3 阶段化取消/失败语义（truthful，不承诺无条件 clean）

复用既有 helper，逐阶段精确（无“cancel 一定干净”承诺）：

| 阶段 | 结果 | 持久状态 |
| --- | --- | --- |
| 首个 IO 前 cancel | `CancellationError` | 零 IO |
| journal 写前 cancel | `CancellationError` | 无 journal/无 record |
| journal 写失败/验证读失败 | 确定未写 → 原写错误；不确定 → `unresolvedRecovery` | journal 保留 |
| record 写前检查点 cancel | 先走 candidate 清理：record/descriptor `try?` 移除 + 验证清 journal | 清理验证成功 → **原始 `CancellationError`**；清 journal 不可验证 → `unresolvedRecovery`（journal 保留） |
| record/descriptor 写入或读回 **IO/注入抛错** | 同上清理路径；清理验证成功时传播**原始 IO 错误**（**不是** `verificationFailed`） | record/descriptor `try?` 移除；journal 验证清除 |
| record/descriptor **字节/解码验证不符** | 同上清理路径；清理验证成功时 `verificationFailed` | 同上 |
| 上述 candidate 清理中 journal 清除不可验证 | `unresolvedRecovery`（替换原错误） | journal 实际状态按故障注入断言：remove 抛错 → 原样保留；remove 已提交而验证读失败 → **实际缺席**（不得声称一定保留） |
| pointer 写失败 + ack 可读且 == previous(nil) | 确定未提交：清理 + 原错误 | journal 验证清除 |
| pointer 写失败 + ack 不可读/异常 | `publicationUnknown` | **journal 保留**（durable fence），不 replay/不自动 resolve |
| ack == nextBytes（即使写报错）且 journal 清除可验证 | 验证提交：receipt（`recoveredWriteAcknowledgment = writeFailure != nil`） | journal 缺失（验证清除） |
| ack == nextBytes 但 journal remove 抛错（`try?` 吞错） | **receipt 仍返回**（pointer ack 即提交证明）；不伪造 `publicationUnknown`、不承诺回滚 | **journal 原样保留**：follower/export 继续 fail closed；显式 isolated resolve 分类 committed 后验证清除 |
| ack == nextBytes 但 remove 已提交而验证读失败 | **receipt 仍返回** | journal **实际缺席**（无 durable fence）：follower 依实际状态继续，不声称保留 |
| 验证提交后 | 无追溯取消：只保留已定义前置检查点 | — |

## 3. P0/P1 与关联校验（test-only；无生产 binding）

- 序列（driver 证明；production composition 仍 OPEN）：真实 Dart capture → `bootstrapShadow`
  receipt **P0**（真实 pointer）→ `adoptMissingIdentities()` receipt **P1**（receipt.transactionID
  非 nil；no-op 分支用 pinned 全校验读的当前 pointer，绝不伪造）→ `exportCurrentShadow(P1)`
  → 校验。
- 关联校验显式 **test-only**：driver 内私有
  `ExportAssociationFixtureOracle.validate(capture: PiliAccountLiveMemoryShadow,
  exported: PiliAccountLiveMemoryShadow, pointer: UUID, envelopeSHA256: String,
  captureRevision: Int64?)`，文档注明**仅 driver fixture oracle，非生产 API/binding/identity**，
  错误为 driver-local typed error；断言 key/mid/generation 对齐、labels canonical/unique、
  digest 相等；负例（缺 label/非 canonical/重复/key-mid-generation 不符/digest 不符）零写
  拒绝。**不**产出生产 binding 对象、不序列化 label 到任何账号结构。
- 诚实边界：Native bootstrap recipe + 离线 Dart consumer **不是**真实 frozen
  Dart→Native→Dart 运行时 composition；association/global retain fence 保持 OPEN。

## 4. R68 —— 双阶段跨运行时证据（可复用 pipeline）

### 4.1 Python 复用阶段 helper（精确签名）

`tool/check_native_account_envelopes.py` 抽出并可复用：

```python
def verify_crossruntime_stage(
    *, stage: str,                       # "export" | "bootstrap"
    sources: list[str], executable_name: str,
    metadata_name: str, wire_name: str, expected_wire_name: str,
    compile_log: str, result_log: str, consumer_test_log: str,
    retained_consumed_name: str,         # stage 专属保留名
    minimum_checks: int, consumer_tests: int,
    run_analyze: bool,                   # 仅第一阶段执行 analyze，共享同一日志
) -> dict
```

固定步骤：清理该阶段输出 → 编译（默认 180 上界）→ 运行 driver（90 上界）→ 严格 metadata
（strict_object/精确 key set/sourceSHA/workflowSHA/schema3/count/digest/`wireFileName ==
expected_wire_name`）→ （第一阶段）`dart analyze --fatal-infos test/services/native_accounts/`
→ consumer `flutter test`（`--dart-define=NATIVE_ACCOUNT_SCHEMA3_EXPORT=<stage metadata>` +
SOURCE define；**新**独立 240 上界）→ consumed 记录严格校验（精确 key set、
`transactionID == 本阶段 metadata.transactionID`（wrong-stage UUID 必失败）、digest/count
一致）→ **把 consumed 改名保留**为本阶段专属 `retained_consumed_name`
（受控 `os.replace`，build 忽略目录）并记录 hash → 消费后重核 metadata/wire hash。
返回该阶段独立 evidence（两阶段各一份）。

### 4.2 两阶段独立记录与 ALL-consumer 后复核

- 阶段一保持现有 `schema3-export.json`/`schema3-export-wire.bin`/日志名与流程；
  阶段二使用 `schema3-bootstrap-export.json`/`schema3-bootstrap-wire.bin` 与新日志名。
- 保留记录名：`schema3-export.consumed.retained.json` /
  `schema3-bootstrap.consumed.retained.json`（consumer 文件**不改**；依次复写后立即改名避免
  第二次覆盖第一条真实消费记录）。
- 两阶段 consumer 全部完成后：重核 **6 个产物**（2×metadata/wire/retained-consumed）hash ==
  各自记录值；随后既有 final HEAD/source-hash/goldens 复核；全部通过才写 passed summary
  （仍在同一 mandatory envelope outcome 内）。
- 必失败项：缺 metadata/wire/consumed、stale（SHA 不符）、wrong-stage UUID、retained 记录被
  覆盖/篡改、consumer 进程失败/缺 pass 行；两阶段计数分别观察记录，不互相借用。
- mock QA（`tool/qa_native_account_envelope_export.py`）扩展为**两阶段各自** happy/负例
  （不得用一条 happy 记录同时证明两阶段）；覆盖上述必失败项与覆盖/篡改检测。
- 触发/接线（仅此清单，无其它源文件）：修改
  `ios/…/PiliAccountEnvelopeStagingStore.swift`（新增 `bootstrapKind` 常量与 bootstrap 路径）、
  `ios/…/PiliAccountEnvelopeTransactionStore.swift`（仅新增 kind case）、
  `tool/check_native_account_envelopes.py`、
  `tool/qa_native_account_envelope_export.py`、`.github/workflows/ios.yml`（仅 trigger path
  `tool/check_native_account_envelope_bootstrap*`）；新增
  `tool/check_native_account_envelope_bootstrap.swift`；Dart consumer/ios-home-preview.yml 不变。
- 阶段二编译闭包（新 `BOOTSTRAP_SOURCES`）：与 `EXPORT_SOURCES`（:122-134）同构，仅将 driver
  换为 `tool/check_native_account_envelope_bootstrap.swift`（含 staging 与 transaction 两个
  envelope store 实际文件，`verify_crossruntime_stage` 的 `sources` 参数传入）；既有
  `STAGING_SOURCES`/`AUTHORITY_SOURCES` 闭包与 180/90 预算不变。

## 5. 受控证明矩阵（bootstrap driver；全阶段 + 独立 oracle）

1. 空 vault → bootstrap：receipt == 入参 ID；pointer/record/descriptor 齐备；journal 缺席；
   winner 全字节 oracle == `codec.encode(schema2 候选)`。
2. pointer present → `bootstrapRefused` 零写；全字节快照不变。
3. schema-3 输入 → `invalidBootstrap` 零写；codec/限额错误按既有类型。
4. journal 有效/损坏/不可读：`unresolvedRecovery`/`invalidRecoveryJournal`/`unresolvedRecovery`；
   字节保留；**unknown/伪造 kind 的 journal** 按“存在”处理（bootstrap → `unresolvedRecovery`；
   TransactionStore 冷加载 → `invalidRecovery`），不因 kind 内容跳过护栏。
5. record collision（复用的 ID 已有 record）→ `bootstrapRefused` 零写。
6. **orphan descriptor collision**（复用 ID 已有 descriptor、无 record）→ `bootstrapRefused`
   零写，descriptor 原样保留。
7. pre-cancel（自取消任务）→ 精确 `CancellationError`、read/write/remove 计数 0。
8. journal 写前/写后/不可读验证：按 §2.3 表精确断言（含 `unresolvedRecovery` 保留路径）。
9. candidate 阶段失败三分类：写入或读回 **IO/注入抛错**且清理验证成功 → 传播**原始错误**
   （非 `verificationFailed`）；**字节/解码验证不符**且清理验证成功 → `verificationFailed`；
   清理中 journal 清除不可验证 → `unresolvedRecovery`（journal 实际状态按故障注入：remove
   抛错 → 保留；remove 已提交/验证读失败 → 实际缺席）。清理验证成功时
   record/descriptor 已 `try?` 移除、journal 验证清除、无 pointer。
10. pointer 写前失败 / 写后 ack 可读 nil → 确定未提交清理+原错误；ack 不可读/异常 →
    `publicationUnknown` + journal 保留 + 全字节快照；导出/bootstrap 随后
    `unresolvedRecovery`；绝不 resolve/clear/replay。
11. 验证提交（ack == nextBytes，含写报错）分支：(a) journal 清除可验证 → receipt +
    journal 缺失；(b) remove 抛错 → **receipt 仍返回**（pointer ack 即提交证明）、journal
    原样保留：follower/export 继续 fail closed（`unresolvedRecovery`），显式 isolated
    resolve 分类 committed 后验证清除；(c) remove 已提交但验证读失败 → **receipt 仍返回**、
    journal **实际缺席**（无 durable fence），follower 依实际状态断言。绝不伪造
    `publicationUnknown`/回滚/“总是干净”。无追溯取消。
12. fresh store 冷加载隔离 fixture：§1.3 字段（含枚举 rawValue == 下层常量断言与
    `.bootstrap` 识别）+ 显式 resolve 三态分类；正常路径不自动 resolve。
13. 合法并发：暂停 bootstrap 时同 vault 第二 bootstrap / correlated import →
    `operationInProgress`、winner 不变；release 后二次 bootstrap → `bootstrapRefused`；
    journal 存在时所有 in-contract follower fail closed（跨新 actor）。
14. same-process reopen：同 namespace 真实 Keychain 新实例读 P0 一致（同进程、非 kill）。
15. adoption：P1 != P0、schema-3 labels canonical/unique/high-water；再次 adopt no-op 不伪造。
16. 关联 oracle 负例（§3）与两阶段跨运行时（§4）全部通过；失败时 mandatory outcome 必须失败。
17. provenance：sourceSHA=workflowSHA；ledger 含新 driver/修改源；goldens 前后一致；HEAD
    前后一致；新阶段命令沿用 180/90 上界（新命令、既有值不变），第二阶段 consumer 为新显式
    240 上界；既有计数/预算/aggregate 不变；driver 计数以实际 CI 观察（计划不预写）。
18. 计数诚实性：成功写调用计数 ≠ attempted writes/removes/orphan 枚举；unresolved 路径不得
    声称零孤儿；本组不得声称 process-kill/device/composition/authority。

## 6. 明确不在本组（保持 OPEN）

- Block3 production composition/startup/revert、nonempty-target reverse apply、MethodChannel、
  authority/handoff、GC、process-kill/设备、remaining Block1/4、Block5 真机清单。
- 全局 in-memory retain fence / handoff admission 表；`end(false)` 不当 thaw/handoff；
  association 生产 binding、真实 frozen Dart→Native→Dart 运行时组合均 OPEN。
- 四 flag false；无真实账户 auth/写、captcha、设备伪造；Flutter/Dart fallback 与 Aether 独立；
  不读/改 `youtube/`；不改 UI visual；不改任何既有断言/预算/门。

## 7. 验收顺序

1. 本 docs-only 计划先经 Codex CONTRACT review（返回本文 SHA；未获批前不实现）。
2. 获批后：实现 → 本地 Python mock QA（两阶段，如实标注 mock）→ commit/push 新 code SHA →
   **STOP BEFORE CI** 交 Codex SOURCE PREFLIGHT → 通过后同一 SHA 各派发 ios.yml /
   ios-home-preview.yml 一次 → Codex 独立实际证据复审 → 有限验收后再进依赖组。
