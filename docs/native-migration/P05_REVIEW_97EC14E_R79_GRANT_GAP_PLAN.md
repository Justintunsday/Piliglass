# P05 focused repair plan（R79；依据 97ec14e terminal review）：S1 C1 grant-boundary 修复 + inter-token admission-gap 回归

2026-10-17（Asia/Hong_Kong）。依据
`build/native-migration/review-97ec14e7a34fe404fece2d2550756ec727034a5e-codex/REVIEW.md`
TOPLATTERMINALDISPOSITION（CHANGES_REQUESTED，R79）。本文件在编辑前保存；仅 test-only；不改
生产/Swift/MethodChannel/UI/workflow/Python；无本地 Dart SDK（仅静态审阅；计数只以未来实际 CI 为准）。

## 0. 实际终端证据（Codex 已独立核实；不重跑 97）

- release `38972337315` attempt1 FAILURE（four companion success；main `117213458429` failure）+
  preview `38972341563` attempt1 SUCCESS 4/4，均 exact 97。
- 实际 main 九 outcome：仅 ACCOUNT_DART failure；BUILD SUCCEEDED/Runner.app 109.1MB/executed FFmpeg
  不覆盖失败 gate。
- 实际 account：strict analyze No issues（R78 已实际通过）、runtime 72、S1 **14 个用例全部执行**，
  13 PASS，唯一失败 C1 line 340 `expected true actual false`；四个 R77 受控负例 PASS。
- R79 诊断：C1 在 `await` FIRST `withSession` 之后、`await second` 之前断言 “ownership transferred
  without reopening”。实际 `_endMaintenance` 同步置 `_maintenance=false` 并完成排队 waiter；SECOND 的
  `beginMaintenance` 在**异步续体**里才重新 `_maintenance=true` 并 drain 其间 admitted chain。已 settled
  的 FIRST future 不等于 SECOND grant；现有 coordinator 未承诺 atomic baton/no-gap。这是 harness
  overclaim（观察时机错误），不是 held-token exclusion 失败；也不修改生产。

## 1. 修复（仅测试文件）

- **C1**：先 `final secondLease = await second!;`（实际 SECOND terminal grant），**随后**保留 held-state
  断言：`isMaintenanceActive == true`、`tryAdmit() == null`、`secondLease.isEnded == false`、
  `tryAdmit() == null`；end 后 `isEnded == true`。所有断言/清理保留；把 “without reopening” 注释改为
  准确描述（同步 release + 异步 claim，允许的 inter-token gap 由下方回归显式覆盖，atomic
  handoff/continuous fence 为 FUTURE OPEN）。
- **新增回归（public coordinator inter-token admission gap）**：保留 FIRST 实际 token 与 SECOND future；
  同步 `firstToken.end(permanent: false)` 后立即断言 `isMaintenanceActive == false` 并 `tryAdmit()` 到
  一个真实 operation（在 waiter 续体运行前）；仅用受控微任务边界 `await Future<void>.value();` 后断言
  SECOND 已 claim（`isMaintenanceActive == true`、`tryAdmit() == null`、`secondGranted == false`）；
  release operation → `await second` → SECOND grant、held exclusion、end、idle/`admittedCount == 0`、
  `isClosed == false`、后续 admission 正常。所有 token/future/operation 在 `finally` drain/end
  （含失败断言路径）；无 timer/sleep/timeout、无私写字段、无丢失 handle。
- 现有 14 个场景、R77 清理与精确错误全部保留；新增用例计数只以未来实际 CI 为准。

## 2. 明确禁止

- 不改 production coordinator scheduling、不添加 terminal freeze 掩盖 gap、不删断言/负例、不弱化
  gate；atomic handoff/continuous fence 保持 FUTURE OPEN（不由 test-local helper 或现有 coordinator 提供）。

## 3. 验收顺序

- 修复 → 静态审阅（无本地 Dart SDK）→ commit/push NEW code SHA → **STOP BEFORE ANY CI** → Codex
  source check → 通过后同一 NEW SHA 双 workflow 各一次 → 实际证据独立复审。不重跑 97、不借用 9de/297
  artifacts；四 flag false/fallback/Aether/safety 不变。
