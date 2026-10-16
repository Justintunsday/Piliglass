# P05 a0e76ed 审查修复注记（pre-edit）：测试 helper for-loop 花括号

2026-10-16（Asia/Hong_Kong）。依据 TOP handoff 与
`build/native-migration/review-a0e76ed377b995d851494e496f85b5d3041c2d32-codex/REVIEW.md`
（CHANGES_REQUESTED，运行时门）。本注记在代码修改之前保存。

## 实际事实（Codex 独立 + 本 session 独立核对）

- `a0e76ed` 对：release [38827039427](https://github.com/Justintunsday/Piliglass/actions/runs/38827039427)
  COMPLETED FAILURE、preview [38827043610](https://github.com/Justintunsday/Piliglass/actions/runs/38827043610)
  COMPLETED SUCCESS 4/4。
- 主 job 116736790411 失败根因：两处 account strict-analysis 步骤（account generations /
  full envelopes）各报**唯一** info：
  `test/utils/accounts/native_account_reverse_import_test.dart:70:33 ...
  curly_braces_in_flow_control_structures`（"1 issue found"），其余全部步骤
  "No issues found!"；最终 aggregate 正确拒绝
  ACCOUNT_DART/ACCOUNT_NATIVE/COOKIES/ACCOUNT_ENVELOPE_OUTCOME（下游因 upstream analyze
  失败缺实际 Dart/goldens/Cookie fixture），`BUILD SUCCEEDED`/109.1MB/FFmpeg 顺序已观察但
  不构成验收。preview 20 tests/11 owned reports/`pressure[]` 不替代被阻塞的 account/native
  执行，也不关闭 R38。
- R38 生产修复（`_preflight` 同账本预投影累计 `durableIdentity` units、移除晚
  `reserveUnits(36)` 无双重计费）已被 Codex 标注 positive；缺的只是实际 Dart 运行。本注记
  是 strict-analysis 风格修复，**不**改 lint/analysis options/fatal-infos/断言/caps。

## 修复（最小）

- 仅把新 helper 第 70 行 `for (final child in node) walk(child);` 的循环体包成块
  （`{ walk(child); }`），语义/断言/结构/既有用例不变。

## 后续

- 小 commit/push → 新最终**代码** SHA 显式 dispatch BOTH `ios.yml` + `ios-home-preview.yml`
  （同一 SHA、各一次）→ 读回实际 evidence（含 269± 实际 account 计数、R38 边界实际执行、
  九 outcome、88 hashes/goldens、BUILD/FFmpeg、preview 20/11/`pressure[]`）→ docs-only
  证据 commit（不冒充 code CI SHA）→ Codex 独立复审。
- 边界不变：四 flag false、fallback/Aether 独立、无 YouTube/UI visual/真实账户；不重跑
  unchanged `a0e76ed`、不自我验收、不推进 authority/下一组/whole P05。
