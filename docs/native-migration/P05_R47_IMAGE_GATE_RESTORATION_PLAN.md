# P05 最小修复计划：R47 恢复原始 image XCTest gate + navigation 8s 精度

2026-10-16（Asia/Hong_Kong）。依据 TOP handoff 与
`build/native-migration/review-cb71a5226c7f6e86153853fdeba99dab4c66bda3-codex/REVIEW.md`
（TERMINAL DISPOSITION + R47，CHANGES_REQUESTED）。**在代码修改之前保存**。

## 实际事实（不虚构）

- `cb71a52`：release 38860065278 SUCCESS5/5、preview 38860068776 SUCCESS4/4（均 first
  attempt）；九 outcome / BUILD 109.1MB / executed FFmpeg、293 account / runtime72 /
  strict clean、native 109/44/40/245/292/51、producer 8/10/2、89 raw 87 match + 2
  declared pubspec、current goldens、Mac QA 45/45（含 readiness SIG_IGN / no-alive /
  elapsed 1.34s）、preview 20 tests / 11 owned reports / 22 streams / `pressure[]` 均已由
  reviewer 读实际证据确认。
- 但 R47 仍为 CHANGES_REQUESTED：**green CI 不等于接受被改动的 gate**。
- R47-1（image）：R46 诊断改动以 `Date` deadline + `RunLoop` 0.1s 轮询 + 循环后
  **无条件 fresh predicate** `XCTAssertTrue` 取代了原始
  `expectation(for:..., evaluatedWith:image); waitForExpectations(timeout:5)`。4.99s 时
  predicate 为 false、clock 在轮询中过期后，fresh predicate 一旦为 true 仍可通过；或
  while 条件先求值 predicate 再比较 clock 而提前退出后同样由 fresh predicate 接受 ⇒
  "within 5 seconds" 的失败信息并不约束实际接受时点。这是 source 反例，**非**已执行的
  Swift/模拟器负例。
- R47-2（image comment）：comment 声称 value/hittable/frame 能区分 "missed gesture" 与
  "unchanged zoom" 属因果推断过度；这些只观测 preconditions/outcome，root cause 未知。
- R47-3（navigation）：`openMine()` 先有界 8s 等 My 按钮存在，tap 之后**再单独**有界 8s
  等 `isSelected == true`；R46 计划中"沿用既有 8s 等待预算"（共享同一 8s、零新增等待）
  的表述不准确。既有各 8s 取值与 25min job 预算本身未变。

## 最小修复（不做其他改动）

1. `tool/check_ios_image_preview.py`：恢复原始 XCTest predicate gate 的严格等义实现——
   同一 `XCTNSPredicateExpectation`（`expectation(for:evaluatedWith:)` 内部的同一
   waiter expectation 类型）+ `XCTWaiter().wait(for:timeout:5)`；**接受时点由 deadline
   处的 waiter 结果唯一决定**，不在循环/过期之后重新求值 predicate 作为接受条件；waiter
   非 `.completed` 时一次 `XCTFail`，携带 observed value/hittable/frame 诊断信息。保留：
   16s fitted 1.0 等待、hittability 前置断言、gesture 前 print、单次 doubleTap、reset
   doubleTap + `assertValue(1.0)`、pager swipe / close / reopen 断言。无 retry、
   tolerance、延长等待。
2. 改写/删除过度因果 comment：诊断只报告观测到的 preconditions/outcome；手势未触发 zoom
   与 zoom 未改变的因果均未证（cause unknown）。
3. `tool/preview_ios_navigation.py`：仅修正 comment 精度——存在性 8s 之后**另加**一次
   有界 8s 选中后置条件（两次顺序 8s 上界），单次 tap、无重试、无更长 deadline；其余
   断言与既有各 8s 取值、25min job 预算不变。
4. `P05_R46_RUNNER_RACE_AND_PREVIEW_DIAGNOSIS_PLAN.md`：对第 4 条加 R47 精度修正注记
   （不改其他历史内容）。

## 边界与验收

- 无 runner 重设计、不重做 R46、无无关生产修复、无 weaker assertions/budgets、无
  retry/tolerance、不改生产 UI visual。
- 本地可做：`py -m py_compile` 与 `tool/check_preview_step_runner.py`（Windows 上 POSIX
  用例明确 SKIP、不当作 PASS）；Swift/模拟器证据只能在 Mac CI 产生（本地无 Xcode，
  不虚构本地 Swift 通过）。
- 小 commit/push → 新最终代码 SHA 显式 BOTH workflows → 读实际 evidence（release 5/5、
  九 outcome/BUILD/FFmpeg；preview 20 tests、QA step、image 两个 gallery case 在恢复后的
  gate 下、navigation、`pressure[]` 若可执行）→ docs-only 证据（与代码 SHA 分列）→
  Codex 独立复审；不自我验收、不推进 authority/下一组。
- 四 flag false、Flutter/Dart fallback、Aether 独立、不读/改 `youtube/`、无 UI visual/
  真实账户写/auth/captcha/设备伪造；保留 `f84314a` 的 image/navigation 失败史与
  pressure SKIPPED 记录。
- 验收记录（docs-only，不改变代码 SHA）：本计划恢复后的链（B1f/R43 + harness R44–R47）在
  代码 SHA `a50ea693c2d4b7d410fff9e29c40ad437af941ac` 获 Codex 有限 PASS（review
  `review-a50ea693c2d4b7d410fff9e29c40ad437af941ac-codex/REVIEW.md`）；release 38864047457
  5/5 + preview 38864051135 4/4 首次尝试，两个 gallery 用例在恢复后的 gate 下实际执行。
  该 comment 中的 "exactly 5 seconds" 应读作**最多 5s 的 waiter 上界**（满足即提前完成，
  非固定 5s 睡眠）；边界与未闭合行见 PROGRESS/STATUS_MATRIX，不追溯改判前驱失败。
