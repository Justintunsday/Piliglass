# P05 提案计划（仅计划，待 Codex CONTRACT review）：B2e-2b-3 OptionB 独立 schema-3 envelope wire + composition 拥有的 freeze/drain + 双向 durable-identity carriage

2026-10-16（Asia/Hong_Kong）。依据
`review-318bb88ee02063e67d62d5bc658e9c7d50b177e1-codex/REVIEW.md` §Required next contract
plan（OptionB 为 preferred DIRECTION ONLY）、`P05_B2E2_PERSISTENT_RECOVERY_PLAN.md` §3、
`P05_B2E2B2_BRIDGE_EXPORT_PLAN.md`（legacy fetch 已获有限 PASS；本契约与其分开）。
**本文件只保存计划：不实现、不派发 CI**；待 Codex contract review；**这不是**用户许可缺失/
设备阻塞/whole-P05 完成。

## 真实组件清单（producers/consumers/mutators；源码核对）

- Dart 产出端：`NativeAccountLiveMemoryCaptureService.capture()`
  （native_account_live_memory_capture.dart）从 live Dart 账号产出 schema-2 live-memory 线
  （四个能力 flag 恒 false）；`Accounts.requestRevision` 是 **capture-local** 计数；
  `NativeAccountSnapshotService`（legacy schema-1 staging/tracker identity）已单独有限 PASS，
  与本契约不混用。
- Swift 消费/变更端：`PiliAccountEnvelopeStagingStore`（schema-2/3 shadow、单一 immutable
  pointer + CAS + descriptor + recovery journal）；`PiliAccountEnvelopeTransactionStore`
  （`adoptMissingIdentities` 显式铸 canonical durable label 并持久 high-water；`lookupRecord`
  :417；`loadPersistentRecovery` :260；`resolveUnresolvedPublication` :503）；
  `PiliAccountEnvelopeStagingStore.loadPublishedCandidate` :402、`clearRecoveryJournal` :289；
  `PiliAccountLiveMemoryShadowCodec`（schema 2 exact / schema 3 strict）。
- Dart 反向消费端：`NativeAccountReverseImport`（schema 2/3 strict decode +
  `recordDurableIdentities` 只读 correlation labels）；`NativeAccountReverseRestoreStore`
  （persist + 自身 provenance/transaction 语义）；`NativeAccountReverseImportService.apply()`
  （empty-target-only；**不携带 labels**）。
- 命名空间纪律（强制）：tracker token（进程内 Expando）≠ durableIdentity（36-unit canonical
  持久文本）≠ authorization（receipts 两门恒 false，label 绝不授权任何写）。

## 契约目标（双向）

1. **初始 Dart→Native capture/adoption 关联**
   - composition 在其 freeze/drain 窗口内由 Dart capture（schema 2，无 labels）→ Swift
     `importShadow`；schema-2 直接 delete/import/publish 仍被拒，**显式
     `adoptMissingIdentities` 是唯一升级门**（铸 canonical labels + 持久 high-water）。
   - 关联键 = record storageKey/generation/mid（+ 冻结窗口标识）；tracker token 不参与关联。
2. **Native→Dart reverse schema-3 export**
   - Swift 在 composition 冻结/排空后，以**精确 immutable publication pointer**
     （`loadShadowSnapshot().transactionID`）为锚导出完整 schema-3 envelope wire
     （`codec.encode`）；**`envelope.revision` 不当作 durable 版本**（它只是 capture-local）。
   - Dart 以现有 schema-3 strict decoder 消费（`NativeAccountReverseImport`），只读暴露
     `recordDurableIdentities`；apply 仍 empty-target-only、labels 只作关联。
   - nonempty-target reverse apply、idempotent reapply、MethodChannel 命令命名、startup apply
     政策、revert/GC、authority 均为**独立门**（本契约不得声称覆盖）。

## Freeze/drain 生命周期（composition 拥有；非 repository/vault/bridge）

- freeze = 拒绝新写 admission + 排空 in-flight 写；drain 语义必须覆盖每一个真实 await，失败/
  取消路径必须释放 freeze（composition 责任，逐路径测试）；不得只清表假装排空。
- Dart `_capture` 只是"先捕获 `revision`、checkpoint 后**乐观复核**"（captures-then-
  revalidates），**不是** acquired freeze/drain lease；Native export 锚定的是 exact pointer，
  不依赖 Dart revision 排序做 durable 判据。

## 校验与 typed 拒绝（全部零写）

- **Export 侧（强制更正既有恢复提案）**：namespace 存在 armed persistent unknown
  journal/fence 时，只读 export **fail closed**：返回精确 recovery-required 结果并
  **保留 journal/fence**；**不得**自动调用 `resolveUnresolvedPublication`/
  `clearRecoveryJournal`，不得重放 unknown writes。显式 recovery 是**单独、经 review 的恢复
  操作**。（更正 `P05_B2E2B2_BRIDGE_EXPORT_PLAN.md` §提案中
  "`loadPersistentRecovery` →（armed 时）`resolveUnresolvedPublication` → lookup" 的排序：
  读取/导出路径不做自动 resolution。）
- Pinned pointer mismatch：export 请求可携带期望 pointer（或 none）；不符 → typed
  `staleExport`、零写。
- Import 侧 typed 拒绝：login record 缺 label / 非 canonical（长度/连字符位置/小写 hex）/
  重复 label / high-water < max(login generations) / tracker-map 或字符串冒充 /
  `durableIdentityConfigured:true` → 拒绝、零写；labels 不进入 receipt 授权语义。

## 受控测试要求（计划；实现前需 Codex 批准）

- pinned-pointer/revision mismatch：export 在 await 窗口内 pointer 被合法移动 → fail closed
  且 winner 不变；
- concurrent selection/replacement：捕获窗口内 Dart `_verify` → `snapshotChanged`；冻结后
  drain 保证无在途写（与 composition 联动测试）；
- cancellation + freeze release：每个错误/取消路径释放 freeze，journal/fence 原样；
- failure/crash ordering：沿用 B2e-2a/2c 已验 journal/candidate/descriptor/pointer/ack 矩阵；
  export 为只读，崩溃不改变任何持久状态；
- reopen proof：same-process 新实例（Keychain 同 namespace）与 logical reopen 明确区分；
  **process kill/cold app start 保持 OPEN**（不伪造）；
- cross-runtime fixture：Swift 产出 schema-3 wire → Dart 测试消费（CI job 编排需单独评审，
  不得以"增补的 Dart capture"冒充端到端 handoff）。

## 边界与下一步

- 本文件仅计划；不改生产/测试、不派发 CI；待 Codex contract review 后才考虑最小实现切片
  （新代码 SHA 需 BOTH workflows + 独立复审）。
- 四 flag false；Flutter/Dart fallback、Aether 独立、不读/改 `youtube/`、无 UI visual/
  真实账户写/auth/captcha/设备伪造；不改任何既有断言/预算/门。
- 未闭合既有行（不因本计划改变）：whole Block1/2/P05、B2e-2b 其余、B2e-3/Block3
  composition/handoff/revert/startup/GC、Block4/5、authority/device。
