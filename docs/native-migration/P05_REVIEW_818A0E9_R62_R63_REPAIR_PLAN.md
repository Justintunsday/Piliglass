# P05 聚焦修复计划（R62/R63）：818a0e9 只读导出 —— post-await 取消优先级 + 导出专属负例/真实 store-B unknown/终态上报

2026-10-17（Asia/Hong_Kong）。依据
`build/native-migration/review-818a0e9daa059739026af28c9e7531e1db4605a5-codex/REVIEW.md`
R62/R63 与 harness QA follow-through（CHANGES_REQUESTED；SOURCE PREFLIGHT，无 CI）。
上一 CLI 在 00:39 读取 review 后异常消失；已对账：HEAD 仍 `818a0e9`、tree clean、无新提交、
最新 Actions 仍为 318 terminal pair、无 mutating tool 结果。本计划在**任何编辑前**保存。

## R62 —— 生产函数取消优先级/映射（最小修复；不改签名/预算/断言）

`exportCurrentShadow` 重排为 **capture → `Task.checkCancellation()` → interpret**：

1. journal：`let journal = try await recoveryJournal()`（结果捕获）→ 立即
   `Task.checkCancellation()` → 再判 `journal != nil → unresolvedRecovery`。
   错误映射收窄：`CancellationError` 原样重抛；**仅** `invalidRecoveryJournal` 原样重抛；
   其余（含其它 typed/unreadable）→ `unresolvedRecovery`（替代 blanket all-typed rethrow）。
2. manifest：`let snapshot = try await manifest()` → 立即 `Task.checkCancellation()` →
   `nil → shadowUnavailable`、pointer 变化 → `staleExport`（取消后不再返回这两种 typed 结果）。
3. record：`let record = try await secrets.read(key)` → 立即 `Task.checkCancellation()` →
   `nil → missingRecord`、count/digest → `verificationFailed`、decode 失败 →
   `verificationFailed`、schema 2 → `shadowUnavailable`。
4. 保留入口前/return 前检查与 `defer` fence 释放；不新增 API/参数/路由。

## R63 —— driver 回归矩阵补齐（`tool/check_native_account_envelope_export.swift`）

- **导出专属负例（fault vault）**：corrupted manifest（`invalidManifest`，字节保留）、missing
  record（`missingRecord`）、count mismatch / digest mismatch（`verificationFailed`）、
  valid-digest+valid schema-2（`shadowUnavailable`）、valid-digest+resource-limit 形状
  （257 records → `verificationFailed`）；每行断言 zero attempted writes/removes + 全字节保留。
- **全 winner oracle（非仅 ID）**：stale/historical 行在 follow-up publication 后断言
  winner snapshot 全 envelope == `codec.decode(codec.encode(base))`、winner record 原始字节 ==
  `codec.encode(base)`、journal 缺席、zero attempts；cached-journal 行补 reset + zero attempts。
- **真实 store-B unknown（替换"仅合成 journal"的 acceptance 说法）**：同 vault；store A 先
  `loadPersistentRecovery()`（缓存 clean）→ 只读导出成功（zero attempts）→ **store B**
  （同 vault 第二 transaction store）`applyTemporarySelection`，fault 令 **pointer ack 读**
  失败（`failPointerReadsAfter(2)`）→ 真实 correlated `publicationUnknown`、journal 保留、
  B in-memory fence armed（`loadPersistentRecovery() != nil`）、A 缓存仍 nil；随后只读导出
  `unresolvedRecovery` 且 vault **全字节快照前后一致**、zero attempts、绝不 resolve/clear/replay。
  合成 direct-journal 行保留但明确标注 synthetic。
- **pre-cancel zero-read**：任务已取消 → 首个 `Task.checkCancellation()` 抛精确
  `CancellationError`，vault readAttempts == 0（新增读计数）。
- **终态上报 helper（R53 概念）**：fault vault 新增 `exportTerminal`（首写优先、
  success/failure 都上报）与 phase waiter 唤醒；driver 用
  `startExportTask` + `runControlledExport`：wait-到 phase 或 terminal；early terminal 立即
  失败而非挂起；任何断言失败也 cancel/resume/await 清理；新增 early-success/early-failure
  判别回归（无 sleep/yield/预算变化）。
- **入口前/return 前取消行**保留；真实 Keychain same-process new-instance 证明保留。
- 末尾 print 改为**真实范围**（fault-vault 每个导出行 zero attempts；Keychain 行只读但
  不计尝试数），删除"EVERY row"不实措辞。

## Python mock QA 跟进（本地 mock only）

- 新增场景：consumer 进程 RuntimeError/nonzero 与"缺 pass 报告"分别失败；缺失/篡改
  consumption record；篡改 metadata；metadata 重复键；workflowSHA 不匹配。
- **main 级 mock 失败/成功**：以受控 mock 真正驱动 `main()`（darwin patch、git/driver 命令
  mock、合成 fixture goldens）→ R62/R63 场景下断言 `summary.json` status=failed、退出码 1；
  happy mock → passed/0。既是 "local mock QA only"（非 runtime 证据）。
- 清理断言改为 **AST 读取 main() 实际 unlink 列表**，不再全文任意出现。

## 文档真实性 + 边界

- B2E2B3 计划状态注记更新：R62/R63 修复已提交；计数/断言/预算/aggregate 不变；实际
  Swift/Dart/CI 证据仍待 source-preflight 之后的 dual CI。
- 不改 318、不扩 bootstrap/生产写入面；四 flag false；新 code SHA 后 **STOP BEFORE CI**
  交 Codex SOURCE PREFLIGHT。

## 实施注记（2026-10-17）

- 本计划已按上述内容实现（同批 code SHA 提交）：生产 `capture→checkCancellation→interpret`
  与收窄 journal 映射；driver 导出负例/全 winner oracle/真实 store-B unknown/pre-cancel 零 IO/
  终态上报 helper（early success/failure 判别、失败路径清理）；mock QA 含 **main() 级**
  failed-summary/exit1 与 happy 运行、AST 清理接线断言。
- 未派发 CI：等待 Codex SOURCE PREFLIGHT；实际 Swift/Dart/CI 计数以 source-positive 后的
  dual CI 观察为准（本地 mock 数字不得当作运行时证据）。
