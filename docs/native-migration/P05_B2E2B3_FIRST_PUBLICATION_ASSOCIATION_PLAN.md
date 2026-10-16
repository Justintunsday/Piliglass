# P05 下一组计划（契约评审版）：guarded FIRST 发布/bootstrap（create-only expected-absent）+ captured Dart→adopted Native 关联 + composition 会话/recovery 依赖

2026-10-17（Asia/Hong_Kong）。依据
`build/native-migration/review-6b39ac14ef49d871621a3f40f40fb90edb24c594-codex/REVIEW.md`
FINAL DISPOSITION 的 "Next authorized substantive work" 与
`review-053aed63…`/`review-818a0e9…`/`review-3e7a21f…` 既有结论。**本文件只保存下一组的
具体契约计划（docs-only，不实现、不派发 CI）**；通过 Codex CONTRACT review 后才实施。
6b limited PASS 仅覆盖只读导出 + 跨运行时 fixture（见 `PROGRESS.md` 记录）；本计划**不把
未来 §2/3.1–2 视为整体获批**，只选定一个有界的安全下一组。

## 0. 现状与确定性事实（源码核对）

- 已验收（6b）：`exportCurrentShadow(expectedTransactionID:)` 只读导出（单 shared-vault
  fence、fresh journal、精确已存字节、严格 schema3、zero writes、显式 post-await 取消）。
- **缺口**：不存在 create-only 的“首次发布”原语。`importShadow(_ input:)`（raw，:135-140）
  是 out-of-contract 覆写原语；correlated 版
  `importShadow(_:expectedTransactionID:candidateTransactionID:recoveryKind:)`（:149-159）
  要求**非可选** `expectedTransactionID: UUID`（无法表达“期望缺席”），而内部
  `publishShadow` 的 `nil` 只属于 raw 路径的“无期望/跳过 CAS”；两者都不是 expected-absent
  语义，必须新增 create-only 原语。`bootstrapShadow` 目前不存在（R59 曾明确将其排除出
  只读切片并要求单独协议）。
- `publishShadow`（:161-266）已给出可复用的 crash/unknown 次序：candidate 校验/编码 →
  journal 写+读回验证 → record 写+读回 → descriptor 写+读回 → pointer 写 → pointer ack
  读；candidate 阶段失败经 `clearJournalAfterFailedAttempt`（验证清除）；ack 未知 →
  `publicationUnknown` 且 **journal 保留**；确定未提交 → 清理候选/descriptor + 验证清
  journal 后抛原始错误；验证提交 → 验证清 journal + receipt。本组复用这些 helper，
  **不改其语义**。
- adoption：`PiliAccountEnvelopeTransactionStore.adoptMissingIdentities()`（:783-820）要求
  schema-2，经 reviewed `publishCandidate`（correlated attemptID + journal + 未知 fence）
  发布 schema-3、mint 每 login record 的 canonical `durableIdentity` 与 high-water；
  schema-3 已 adopted → no-op receipt `transactionID: nil, adopted: 0, adoptedIdentities: []`
  （:792-795），**不得据此伪造 pointer**。
- Dart capture：`NativeAccountSnapshotService._capture/_verify` = optimistic revision 复核
  （capture-local revision、**非** freeze/lease）；tracker token（Expando）≠ 信封
  `durableIdentity` 命名空间 ≠ authorization。composition 会话 =
  `AccountWriteBackCoordinator.beginMaintenance()`（returns `AccountWriteBackMaintenance?`）/
  `end({required bool permanent})`；`freeze()` 无 unfreeze（终态）；`end(false)` 只恢复
  admission，**不是** single-writer handoff 证明。

## 1. 下一实施切片（bounded；先经 CONTRACT review）

改动文件（拟定）：
- 修改 `ios/Runner/Native/Persistence/Accounts/PiliAccountEnvelopeStagingStore.swift`：
  原 enum 新增 `case bootstrapRefused`；新增 `bootstrapShadow`。
- 新增 `tool/check_native_account_envelope_bootstrap.swift`（矩阵 + 首次发布跨运行时
  recipe）。
- 修改 `tool/check_native_account_envelopes.py`：新 BOOTSTRAP 阶段（并入同一 mandatory
  envelope outcome）、cleanup/ledger/summary 扩展。
- 修改 `.github/workflows/ios.yml`：仅新增 trigger path
  `tool/check_native_account_envelope_bootstrap*`（artifact glob 已覆盖 `*.json`/`*.log`/
  `*.bin`；**不改 step/aggregate**）。
- **不改** Dart consumer 测试文件（同一测试以 define 指向 bootstrap 元数据复跑；见 §5）。
- **不**新增 MethodChannel/命令；**不**接 composition/authority。

### 1.1 `bootstrapShadow` 契约（create-only、expected-absent、correlated）

```swift
func bootstrapShadow(_ input: Data, candidateTransactionID: UUID,
                     recoveryKind: String) async throws -> PiliAccountEnvelopeStagingReceipt
```

单次 `beginOperation` fence（defer 释放）内次序：

1. `Task.checkCancellation()`（first IO 之前）。
2. `codec.decode(input)` + `codec.encode(candidate)`（先在内存拥有 canonical 候选；失败
   零持久副作用）。
3. **fresh journal 读**（原始读 + canonical decode，不经缓存）：有效存在 →
   `unresolvedRecovery`；损坏 → `invalidRecoveryJournal`；不可读 → `unresolvedRecovery`
   （映射与导出契约一致；取消错误原样）。
4. `manifest()` **必须缺席**（nil）：present → 新 `bootstrapRefused`（零写；绝不覆写既有
   pointer）。这是 create-only 的线性化前置条件。
5. `Task.checkCancellation()`。
6. `secrets.read(key(candidateTransactionID))` 必须 nil（碰撞 → `verificationFailed`，零写）。
7. 写 journal（attemptedID=入参 ID、expected=nil、digest、kind 由调用方；验证读回）。
8. record 写 + 读回 == 候选（且 codec decode == candidate）→ descriptor 写 + 读回。
9. `Task.checkCancellation()`；写 pointer；其余（candidate 阶段失败清理、ack 未知
   `publicationUnknown` 保留 journal+fence、确定未提交清理并抛原错、验证提交验证清
   journal + receipt）**完全复用既有 publishShadow 语义**，不新增恢复路径、不 replay、
   不自动 resolve/clear 未知。
10. receipt = `PiliAccountEnvelopeStagingReceipt(transactionID: candidateTransactionID,
    recoveredWriteAcknowledgment: …)`。

边界：`candidateTransactionID`/`recoveryKind` 必填（匿名 bootstrap 不允许）；raw
`importShadow` 保持 out-of-contract（仅 driver fixture 用途）；本原语**不是** adoption、
不写 durable label、不接触 authority/账号。enum 修改照旧只加在**原声明**（staging
store :4-7）。

## 2. P0/P1 与关联绑定（association）

- 未来序列（本组以 driver 证明；production composition 仍 OPEN）：
  真实 reviewed session 下 capture Dart owned schema-2 → **`bootstrapShadow`**（receipt
  **P0** = 真实新 pointer）→ **`adoptMissingIdentities()`**（receipt **P1**）→
  `exportCurrentShadow(expected: P1)` 得权威 bytes+digest → binding。
- P1 规则：`receipt.transactionID` 非 nil → P1 = 该 pointer；no-op 分支（已 adopted，
  receipt.transactionID == nil）→ P1 = **经 pinned 读（`loadShadowSnapshot` 全校验）确认的
  当前 pointer**，绝不伪造/复用 nil receipt。
- binding（未来 Dart composition 对象；本组由 driver 构造并断言语义，不是生产 Dart API）：
  `bindingID`、`expectedPointer`(P1)、`envelopeSHA256`（权威导出 digest）、
  `captureRevision`（capture-local，仅乐观复核证据）、`records:[{storageKey(UTF16), mid,
  generation(capture-local), durableIdentity?}]`。
- 规则：labels 只作关联、绝不授权；tracker token 不进入 binding；generation 是 capture-local，
  非跨重启 credential；同 key/MID ≠ 同 incarnation。
- typed 拒绝（零写、零 fence 变更）：digest/pointer 不符 → `verificationFailed`/
  `staleExport`；schema-3 login record 缺 label/非 canonical/重复 → typed association
  mismatch；capture 与导出 record 的 key/mid/generation 不匹配 → typed mismatch。
- **production caller/wire：无**（本组不接任何命令/UI/仓库调用；未来 composition 消费者
  出现时另立 gate）。

## 3. composition 会话与 recovery 依赖（契约文本；Dart 侧实现仍属后续 gate）

- session ownership（Dart，Block3 实现）：composition 打开 `beginMaintenance()` token；
  success/precommit-cancel → `end(permanent:false)`；close → `end(permanent:true)`；
  pending acquisition 禁止 abandon（await 到 grant 后立即 end）。
- drain 覆盖（已接 admission 的 writer）：`Accounts.set/selectTemporarily/refresh`、
  install/import/delete ports、`LoginUtils.setWebCookie`/`onLoginMain`/`onLogoutMain`、
  `RequestUtils.syncHistoryStatus`、`Accounts.clear`/匿名 reset、`GStorage.compact/close`、
  Native HTTP lease finish。
- 明确 **OPEN/未覆盖**：coordinator 之外的裸 Hive 写入、页面只读、snapshot capture
  （只读）、未经 port 的第三方写入；"已命名 coordinator" ≠ all-writer freeze。
- success/precommit-cancel：token 结束、无未决；**postcommit unknown（Native）**：token 按
  规则 end，但 **persistent journal + in-memory fence 保留**；`end(false)` 不解除未知、
  **不构成 handoff/全局 retain fence**。未来 unknown/admission 表（哪些 writer 可在
  handoff 期间运行）保持 **OPEN**，直到显式 global retain fence 设计获批。
- Dart capture 仅 optimistic revalidation（无 acquired lease）；本组不在 Dart 侧新增会话
  实现。

## 4. 受控证明矩阵（bootstrap driver；独立 oracle + provenance）

1. 空 vault → bootstrap：receipt == 入参 ID；pointer/record/descriptor 齐备；journal 缺席。
2. pointer 已存在 → `bootstrapRefused`；全字节快照不变、零 attempted writes/removes。
3. journal 有效存在 / 损坏 / 不可读 / 无关 typed 读错：`unresolvedRecovery` /
   `invalidRecoveryJournal` / `unresolvedRecovery` / `unresolvedRecovery`；字节保留。
4. attemptID 记录碰撞 → 拒绝零写。
5. pre-cancel（自取消任务）→ 精确 `CancellationError`、zero IO（read/write/remove 计数 0）。
6. 受控暂停于 journal 写后 / record 写前 cancel + 显式 resume → `CancellationError`、
   candidate 阶段失败路径验证清 journal、无 record/pointer、fence 释放。
7. pointer ack 不可读 → 真实 `publicationUnknown`；journal+fence 保留；全字节快照保留；
   导出/bootstrap 均拒绝为 `unresolvedRecovery`；**绝不** resolve/clear/replay。
8. 确定未提交（ack == previous nil）→ 候选清理 + 原错误；journal 验证清除。
9. 合法并发：暂停 bootstrap 时同 vault 第二 bootstrap / 既有 import → `operationInProgress`、
   winner 不变；release 后合法路径可继续（第二次 bootstrap → `bootstrapRefused`）。
10. same-process reopen：同 namespace 真实 Keychain 新实例读 P0 一致（同进程、非 kill）。
11. adoption：P1 != P0、真实非 nil、schema-3 labels canonical/unique、high-water 正确；
    再次 adopt → nil receipt no-op，pinned P1 读一致（不伪造 pointer）。
12. 关联绑定：digest 相等；独立 oracle = 真实 Dart capture（`live-memory.json` 的
    `stored-10-2-owner-2-10`）逐 record key/mid/generation 对齐；typed 负例（缺 label /
    非 canonical / 重复 / key-mid-generation 不符 / digest 不符）零写拒绝。
13. 跨运行时：bootstrap→adoption→P1 导出写 `schema3-bootstrap-export.json` +
    `schema3-bootstrap-wire.bin`（精确字节；sourceSHA=workflowSHA=最终 code SHA）；
    同一已验证 Dart consumer 测试以
    `--dart-define=NATIVE_ACCOUNT_SCHEMA3_EXPORT=<bootstrap 元数据>` 复跑：byte/hash/
    consumed（固定名依次复写，各阶段即时校验）/labels/projection 全通过，且 Python
    在消费后复核产物哈希。consumer 文件本身**不改**。
14. provenance：ledger 含新 driver/producers/相关 Swift 源；goldens 前后一致；HEAD 前后
    一致；新阶段命令沿用既有 180/90 per-command 上界（新命令、既有值不变），consumer 第二次
    运行使用新的显式 240 上界；**所有既有计数/预算/aggregate 不变**；新的 driver 计数以
    实际 CI 观察为准（计划不预写数字）。

## 5. 明确不在本组（保持 OPEN）

- Block3 production composition/startup apply/revert、nonempty-target reverse apply、
  MethodChannel/命令接线、authority activation/handoff、GC、process-kill/设备验收、
  remaining Block1/4、Block5 真机清单。
- 全局 in-memory retain fence / handoff admission 表；`end(false)` 不当 thaw/handoff。
- 不新增真实账户 auth/写、captcha、设备伪造；四 flag false；Flutter/Dart fallback 与
  Aether 独立不变；不读/改 `youtube/`；不改 UI visual。

## 6. 验收顺序

1. 本 docs-only 计划先经 Codex CONTRACT review（返回本文 SHA；未获批前不实现）。
2. 获批后：实现 → 本地 Python mock QA（如实标注 mock）→ commit/push 新 code SHA → **STOP
   BEFORE CI** 交 Codex SOURCE PREFLIGHT → 通过后同一 SHA 各派发 ios.yml /
   ios-home-preview.yml 一次 → Codex 独立实际证据复审 → 有限验收后再进依赖组。
