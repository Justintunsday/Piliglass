# P05 下一组计划：B2e-2b bridge export 语义 + frozen-revision/durable-identity carriage（先计划后实施）

2026-10-16（Asia/Hong_Kong）。依据 `review-3818948…-codex` FINAL DISPOSITION 的 next-step
（"SAVE coherent substantive next remaining B2e-2b bridge export/frozen-revision/durable-label
carriage plan based on REAL current Dart/Swift callers"）、`P05_B2E2_PERSISTENT_RECOVERY_PLAN.md`
§3 契约、`P05_B2E2B_IDENTITY_CARRIAGE_PLAN.md` 状态注记。**本文件在实现前保存**。

## 现状（真实 callers/fields/namespaces；源码核对）

- Dart 产出端：`NativeAccountSnapshotService.stagingExport()`（native_account_snapshot_service.dart:56-71）
  → `{schemaVersion:1, authority:'dartHive', nativeWritesAllowed:false, snapshot, entries}`；
  `_capture()`（:97-141）先捕获 `revision = Accounts.requestRevision`，`_verify()`（:143-159）
  在 checkpoint 后**乐观复核** revision/stamps/selection 与复制值（captures-then-revalidates；
  **非**获取型 freeze/drain lease，写者无需等待；capture-local revision，非 durable
  identity）；credentials 经 tagged/bound reader（:73-95；未持有 → `snapshotChanged`，绝不回退
  raw）；`identity` 是进程内 tracker token（Expando `_tokens`，:171-174），**与信封
  `durableIdentity`（36-unit canonical 文本）命名空间分离**。
- Dart 路由：`ios_native_ui_bridge.dart:171-175` → `NativeAccountSnapshotBridge`
  （`loadNativeAccountSelection`/`exportNativeAccountStaging`；:7-22）。
- Dart fixture 产出：`native_account_snapshot_test.dart:138-140` 写
  `build/native-account-contracts/live.json`；`native_account_hive_export_test.dart:49-51` 写
  `hive-reopened.json`（由 `ios.yml` 的 `flutter test test/utils/accounts/` 生成）。
- Swift 消费端：`PiliAccountFlutterRepository.selectionSnapshot()`（唯一 bridge fetch）；
  `PiliAccountStagingBridgeCodec.decode`（严格 key set/identity/cookie/flag）；`PiliAccountStagingStore`
  （atomic pointer、epoch/revision 单调、exact load、discard、失败清理）；`tool/check_native_accounts.py`
  以两个真实 Dart export 驱动全部上述路径。**缺 `exportNativeAccountStaging` 的 Swift consumer**
  ——这是本组要补的 bridge export 缺口。
- Swift 信封面：schema-3 `durableIdentity`（staging/transaction store）；只读对齐面
  `loadShadowSnapshot`/`lookupRecord(durableIdentity:)`/`loadPublishedCandidate`；未解决发布
  fence。Dart reverse import 已可严格解码 schema 2/3 并只读暴露 `recordDurableIdentities`
  （B2e-2b-1，`ea60931`）；`apply()` 不携带 labels（属 Block3 政策）。

## 本组实施（B2e-2b-2，read-only、零 authority、不改命令/旗标）

1. `PiliAccountFlutterRepository.stagingExport()`：invoke `exportNativeAccountStaging`（无参数）、
   与 `selectionSnapshot()` 相同的 error-state 处理（`{state:error, code, nativeWritesAllowed}`
   → `invalidSnapshot` 或 `serviceFailure(code)`）、再交 `PiliAccountStagingBridgeCodec.decode`；
   不做 Domain protocol 改动（composition consumer 出现时再提升，避免无消费者的抽象面变更）。
2. `tool/check_native_accounts.swift` 回归（只增）：
   - 真实 Dart export round-trip：`stagingExport()` 结果 == codec 期望，方法路由
     `exportNativeAccountStaging`、恰一次调用；
   - error-state：精确 `serviceFailure("snapshotChanged")`；畸形 error dict（多余 key /
     `nativeWritesAllowed:true`）→ `invalidSnapshot`；
   - 变更 fixture 负例：`schemaVersion:2` / `nativeWritesAllowed:true` / 空 `entries` →
     直连 codec 与 `repository.stagingExport()` 双路径 `invalidSnapshot`（R55）；
   - 取消回归（R55）：预取消 → 零 invoke；受控挂起后 cancel+release → `CancellationError`、
     恰一次 invoke、不 decode 结果。
3. 明确 NOT（不得声称）：本切片是 **legacy staging bridge**（tracker identity），不携带/校验
   durable identity；不新增 bridge 命令；不接 authority、不改 flag、不碰 UI/`youtube/`。

## 精确提案（交 Codex 复核；本组不实施 frozen-revision/durable-identity 契约）

契约文本（B2E2 §3）：导入/导出必须在**同一 frozen revision** 下携带并校验每个 record 的
durable identity（缺失/不匹配 → 拒绝、零写）；identity 只作关联/对账、绝不授权；tracker token
与 durable identity 不得混用；崩溃/重启后用 `lookupRecord` + `loadPublishedCandidate` 对齐。
未定型选项（两者都需要 Block3 freeze→drain→export 次序决策，超出本组可安全实施范围）：

- **选项 A**：扩展 legacy staging export，按 entry/record 增加可选 `durableIdentity` 字段
  （双端 schema 升级 + 严格 reject 规则）。风险：把两个命名空间压进同一 legacy wire，
  需同时改 Dart 生产者、Swift codec、staging store 与全部现有 fixtures。
- **选项 B（提案偏好）**：新增 envelope-wire 命令：Swift 在冻结指针快照（transactionID）下以
  `codec.encode(shadow)` 导出 schema-3 线，Dart 以**现有** schema-3 严格 decoder 消费
  （B2e-2b-1 已完成）；identity 字段天然只在信封命名空间内。需要在 Block3 定义 freeze/drain
  次序、命令命名、拒绝码与 cross-runtime fixture（Swift 产出 → Dart 测试消费）的 CI 编排。
- 崩溃/重启对齐路径（两选项共用）：`loadPersistentRecovery` →（armed 时）
  `resolveUnresolvedPublication` → `lookupRecord(durableIdentity:)`/`loadPublishedCandidate`；
  旧指针/不匹配 identity → typed 拒绝、零写。
- 需 Codex 决策的开放点：选型 A/B、冻结点所有权（composition vs repository）、命令/错误码命名、
  导出失败时的 drain 释放语义、GC 引用策略。

## 边界与验收

- 不改 authority/flag、不真实账户、不碰 UI/`youtube/`/Aether；不降任何既有断言/预算
  （account 计数只增、109/44/40/**285**/292/51 基线不降、180/90 不变）。
- 小 commit/push；新最终 code SHA 显式 BOTH `ios.yml`+`ios-home-preview.yml`（各一次），读实际
  artifacts；docs 证据与代码 SHA 分离；交 Codex 独立复审后再进下一组（本提案批准前不实施
  契约部分；Block3 composition 仍为独立门）。
