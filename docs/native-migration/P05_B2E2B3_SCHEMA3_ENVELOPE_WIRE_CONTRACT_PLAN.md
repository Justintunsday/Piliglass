# P05 契约计划（R56–R58 修订版；仅计划）：OptionB 独立 schema-3 envelope wire —— 原子只读导出服务 + composition 会话生命周期 + 初始关联/下一可实施切片

2026-10-16（Asia/Hong_Kong）。依据
`review-d011fc0f8b037e4c9e039edf81a47e39e72ff0c4-codex/REVIEW.md` R56–R58（对
`P05_B2E2B3…` v1 的 contract plan CHANGES_REQUESTED；318 limited PASS 保持、不重开）。
**本文件只保存修订计划：不改生产/测试、不派发 CI**；返回本 docs SHA 供 Codex contract
review。v1 的"方向正确但不可安全实施"部分按 R56–R58 改为**具体 API/状态/次序设计**。

## 0. 真实 API/状态事实（修订依据；源码核对）

- staging（`PiliAccountEnvelopeStagingStore`）：`beginOperation()`（:495-499）为实例级
  operation fence；`loadRecoveryJournal()`（:271-275）与 `loadShadowSnapshot()`（:392-398）
  各自 begin/defer 释放——**两次调用不共享 fence**；raw `importShadow(_ input:)`（:136-140）
  为 out-of-contract primitive（`expectedTransactionID == nil`，可在 pending journal 旁发布
  schema 2）；`loadPublishedCandidate(transactionID:)`（:402+）**故意**可读历史 immutable
  candidate（descriptor 命中或当前 manifest 命名该 transaction），**不构成 current pointer 证明**。
- transaction（`PiliAccountEnvelopeTransactionStore`）：`loadPersistentRecovery()`（:260）
  经 `loadRecoveryOnce` 缓存（`recoveryLoaded=true` 后直接返回）——**不是 fresh journal 缺席
  证明**；`adoptMissingIdentities()`（:783-795）schema 3 已 adopted → no-op receipt
  `PiliAccountShadowIdentityReceipt(transactionID: nil, adopted: 0, …)`（不得据此伪造 pointer）；
  `lookupRecord(durableIdentity:)`（:417）为只读对齐工具。
- coordinator（`AccountWriteBackCoordinator`）：`tryAdmit()` 在 `_frozen || _maintenance ||
  _closed` 时拒绝（零写、不注册）；`freeze()` 置 `_frozen=true` **无任何 unfreeze**（终态）；
  `quiesce()` 仅 drain 不拦新 admission；`beginMaintenance()` 为**独占** barrier：拒绝新
  admission、等待在途链、返回 token，`end(permanent:false)` 恢复 admission /
  `end(permanent:true)` 永久 close——**maintenance 绝不解除既有 authority freeze**。生产先例：
  `GStorage.compact/close`（storage.dart:112-139）`try { … } finally { end(permanent:false/true) }`。
  pending acquisition 风险：`beginMaintenance` 在 `_maintenanceWaiters` 上 await，**调用方
  放弃 future 时仍会在前一 holder end 后获得 token** → 必须由调用方 await 到 grant 并立即 end。
- Dart capture/reverse：`NativeAccountSnapshotService._capture/_verify` 为 optimistic
  revision 复核；`NativeAccountReverseImport.decode` 严格 schema 2/3 + 只读
  `recordDurableIdentities`；`NativeAccountReverseImportService.apply()` 仅空目标、不携带
  labels；`Accounts.requireEmptyCapturedRestoreTarget()`（accounts.dart:605）非空目标拒绝、
  **绝不清理**。

## 1. R56 解决方案 —— 原子 fresh journal + pinned current pointer 导出

### 1.1 签名/结果/wire/错误（新只读 API，staging 层）

```swift
struct PiliAccountEnvelopeExport: Sendable, Equatable {
  let transactionID: UUID      // exact current immutable publication pointer（线性化点）
  let envelopeBytes: Data      // 该 pointer 命名的记录精确字节（codec 产生的 canonical 线）
  let envelopeSHA256: String   // sha256(envelopeBytes)，provenance/关联用
}

extension PiliAccountEnvelopeStagingError {
  // 新 typed 情形（只读导出专用；既有 case 不变）
  case recoveryRequired   // fresh journal present / corrupt / unreadable —— fail closed
  case staleExport        // expectedTransactionID != 当前 pointer
}

func exportCurrentShadow(expectedTransactionID: UUID) async throws -> PiliAccountEnvelopeExport
```

- `expectedTransactionID` **必填**（pinned-current 模式）；v1 的 "or none" 删除。unpinned
  capture 模式不属于本契约/本切片（如未来需要，另行 explicit 语义）。
- wire = 当前 pointer 记录**已存字节**（与 `account-envelope-shadow-v2.<uuid>` 键下字节一致），
  不重新 encode、不替换 candidate/descriptor。

### 1.2 读线性化点与次序（一次 `beginOperation` fence 覆盖全序列）

1. `try beginOperation()`（同 vault 单实例；同 namespace 多 vault actor 继续**不支持**，见
   staging :142-143 注释）。
2. **fresh** journal 读（`recoveryJournal()`，不经过任何 cached store API）：`nil` 必需；
   present / corrupt / unreadable → `recoveryRequired` —— **零写、journal 与 fence 原样保留、
   绝不 clear/resolve/replay**。
3. `manifest()` 读 → current pointer；`nil` → `shadowUnavailable`；
   `current.value.transactionID != expectedTransactionID` → `staleExport`。
4. `secrets.read(key(pointer))` 精确字节；缺失/不可读/与 manifest byteCount/sha256 不符 →
   `missingRecord`/`verificationFailed`（typed，零写）。
5. 计算 `envelopeSHA256`；返回。方法结束时释放 fence；**返回即 as-of 线性化点的不可变快照**。
6. fence 释放后 winner 移动：导出**不承诺持续货币**、不自动 revalidate；消费方（Block3
   composition）按需重新调用并携带新 expected pointer。

### 1.3 其它语义

- in-memory armed fence：armed unknown 必有持久 journal（journal 先写、`publicationUnknown`
  保留 journal 直至显式 resolve），fresh journal 检查覆盖该情景；若调用方自身是携带 armed
  fence 的 TransactionStore，必须走**单独经 review 的显式恢复操作**后再导出。
- 历史 candidate：`loadPublishedCandidate` 仍可用于显式恢复/对账；导出服务不得以历史
  descriptor/候选替代 current pointer。

### 1.4 受控证明矩阵（实现切片必须包含）

| 用例 | 设置 | 断言 |
| --- | --- | --- |
| cached-clean + B 后 arm unknown | 先经 TransactionStore 读出 clean（缓存），另一 store 在共享 vault 上 arm 已持久化 unknown | 导出 `recoveryRequired`；journal 保留、零写、pointer/envelope 不变 |
| journal 在 await 窗口出现 | controlled fault secret store 在导出序列某 await 注入 journal | `recoveryRequired`；不 clear |
| journal 不可读/损坏 | fault read 抛错/字节损坏 | `recoveryRequired`（绝不当缺席） |
| historical candidate ≠ current | 旧 candidate/descriptor 存在，pointer 已移动 | 旧 expected → `staleExport`；不返回旧字节 |
| same-vault 合法竞争 | 导出前合法 B 发布新 pointer | 旧 expected → `staleExport`；winner 完整保留 |
| 成功导出 | pinned current | bytes==存储字节、digest 匹配、写计数 0、pointer 不变 |

## 2. R57 解决方案 —— composition 会话生命周期（Block3 设计；本切片不获取 lease）

### 2.1 选择的状态机（不再引用终态 `freeze()`）

- **quiesce session**（composition-owned）= `beginMaintenance()` 独占 token：
  success/失败/取消 → `finally end(permanent:false)`（恢复 admission）；`close` 路径 →
  `end(permanent:true)`。`freeze()` 保持终态、仅 authority 语义；maintenance **绝不**解除既有
  authority freeze。生产先例 = `GStorage.compact/close`。
- release/retain 规则表：
  | 结局 | admission | token | 持久状态 |
  | --- | --- | --- | --- |
  | success（导出/迁移完成） | `end(false)` 恢复 | 恰一次 | 无未决 |
  | precommit failure / 取消等待 | `end(false)`；drain 自身零写 | 恰一次 | 无未决 |
  | pending acquisition 被取消 | **禁止 abandon**：仍 await 到 grant 后立即 `end(false)` | 恰一次 | 不遗留 `_maintenance=true` |
  | postcommit unknown（Native） | token 按上述 end | 恰一次 | **unknown journal/fence 保留**，与 admission 恢复相互独立；不得以 end 当 thaw |
- 已 admitted 的 Dart 效应**不假取消**：drain 等其完成（`quiesce`/maintenance 语义）；Dart
  future 取消 ≠ Swift Task 取消，二者不得互相冒充。
- pending acquisition 取消回归（deterministic）：holder 持 token → A 等待 acquisition → A
  的等待方被取消/放弃 → holder `end(false)` → A 得到 token 后立即 `end(false)` → 新 admission
  恢复、`isMaintenanceActive == false`、无越权写。

### 2.2 参与写者清单（drain 覆盖）与明确未覆盖

- 已接 entry 的 writer（drain 可覆盖）：`Accounts.set/selectTemporarily/refresh`（`tryAdmit`）、
  install/import/delete ports、`LoginUtils.setWebCookie`/`onLoginMain`/`onLogoutMain`、
  `RequestUtils.syncHistoryStatus`、`Accounts.clear`/匿名 reset、`GStorage.compact/close`
  （beginMaintenance）、Native HTTP lease finish。
- 明确**未覆盖/不等价**：coordinator 之外的裸 Hive 写入、页面只读、snapshot capture（只读）、
  未经 port 的第三方写入；"已命名 coordinator" ≠ all-writer freeze。
- **本切片前提**：只读导出**不获取任何 freeze/drain lease**；调用方（driver/未来 composition）
  必须传精确 expected pointer；导出结果**不得**用于授权 handoff、启动 apply 或 revert。

## 3. R58 解决方案 —— 初始关联与下一可实施切片

### 3.1 bootstrap 与后续 import 分离（替代 raw importShadow 的 out-of-contract 使用）

- **零标签初始 bootstrap**：新增 guarded
  `func bootstrapShadow(_ input: Data) async throws -> PiliAccountEnvelopeStagingReceipt`
  （staging，一次 fence）：fresh journal 必须缺席（否则 `recoveryRequired`）→ pointer 必须
  缺席（否则 `bootstrapRefused`，零写）→ 按 raw 语义发布 schema-2 wire（零标签）。
  **禁止**在已有 pointer 或 pending journal 旁无条件 raw overwrite。
- **后续 import**：仅 schema-3 线的相关发布（`applyImport`/`importShadow(expectedTransactionID:)`
  语义），不再使用 raw primitive。

### 3.2 关联（owned immutable binding）

- 序列：capture P0 = `exportCurrentShadow(expected: 初始 pointer)` → `bootstrapShadow` →
  `adoptMissingIdentities()` → P1 = `receipt.transactionID ?? P0`（no-op 不伪造 pointer）→
  `exportCurrentShadow(expected: P1)` 得权威 bytes+digest → 构建 binding。
- Dart-owned binding（不可变）：
  ```
  bindingID: UUID
  expectedPointer: String            // P1（Native immutable publicationID）
  envelopeSHA256: String             // 权威导出 digest
  captureRevision: int               // Dart capture-local，仅乐观复核证据
  records: [{ storageKey(UTF16), mid, generation(capture-local), durableIdentity? }]
  ```
  规则：generation 是 capture-local，**不是**跨重启 request credential；同 key/MID ≠ 同
  incarnation；missing/mismatched/reused context → typed 拒绝、零写；labels 只作关联、绝不授权；
  tracker token 不进入 binding。

### 3.3 下一可实施切片（bounded；待 Codex 批准后实现，新 code SHA + BOTH CI）

1. Swift：实现 `exportCurrentShadow(expectedTransactionID:)` + `bootstrapShadow(_:)` 与
   typed 错误（新增 `recoveryRequired`/`staleExport`/`bootstrapRefused`）；文件
   `ios/…/PiliAccountEnvelopeStagingStore.swift`；**不**新增 MethodChannel 命令。
2. Swift driver（扩展现有 identity driver 或新 driver）：§1.4 矩阵 + bootstrap 拒绝
   （已有 pointer/pending journal）+ adoption no-op 不伪造 pointer + same-process reopen 后
   导出一致 + 写计数 0/预算 120/60 不变；并把成功导出的 wire 写成
   `build/native-account-envelope-check/schema3-export.json`：
   `{sourceSHA, workflowSHA, transactionID, envelopeSHA256, envelopeWire}`（wire 与 hash 另存，
   provenance 由 native python ledger 覆盖输出 hash）。
3. Dart 消费（real cross-runtime）：新测试
   `test/utils/accounts/native_account_schema3_export_consumption_test.dart` 读取上述产物，
   `NativeAccountReverseImport.decode` 断言 labels/records 与 binding 语义对齐、哈希一致；
   纯离线、无网络/真实账户。
4. CI 顺序：`ios.yml` 在 `group-account-envelope` 之后新增一步运行该 Dart 测试（Swift 产出 →
   Dart 消费同一 job 内排序）；native python provenance 增加输出 hash；`sourceSHA=workflowSHA`
   双端记录。
5. 确定性负例/并发/取消/预算/重开：stale pointer、journal 出现/损坏、bootstrap 拒绝、no-op
   adoption、同 vault 合法竞争、导出序列取消（零写、fence 无残留）、same-process reopen；
   不新增预算/不弱化断言。
6. 明确未实施 gate：production composition/startup apply/revert/GC、nonempty-target reverse
   apply/idempotency、MethodChannel 命令、authority handoff；本切片结果**不得**声称双向
   handoff 完成或 whole P05。

## 4. 边界

- 四 flag false；Flutter/Dart fallback、Aether 独立、不读/改 `youtube/`、无 UI visual/
  真实账户写/auth/captcha/设备伪造；不改任何既有断言/预算/门。
- 本 docs-only 修订先经 Codex contract review；通过后才实现 §3.3 切片（新 SHA BOTH CI +
  独立复审）。318 limited PASS 与既有失败历史保持。
