# P05 209885f 修复注记（pre-edit）：4 个单 cascade info + R41 exact counter

2026-10-16（Asia/Hong_Kong）。依据 TOP handoff 与
`build/native-migration/review-209885fea069c030b4b1de18cfc0f11d4c3e670a-codex/REVIEW.md`
（CHANGES_REQUESTED）。本注记在代码修改**之前**保存。

## 实际事实（Codex 独立 + 本 session 核对）

- release [38837912612](https://github.com/Justintunsday/Piliglass/actions/runs/38837912612)
  COMPLETED FAILURE：account (12019573762) / native-envelope (12019693705) 的 analyze.log
  各报 4 个 `avoid_single_cascade_in_expression_statements`，位置
  `test/utils/accounts/native_account_hive_export_test.dart` 55/73/97/114，均为
  `Accounts.account.get('601')!..activated = true;`（上一轮 cascade_invocations 修复
  交换出的单 cascade info）；main aggregate 因此拒绝
  ACCOUNT_DART/ACCOUNT_NATIVE/COOKIES/ACCOUNT_ENVELOPE_OUTCOME，其余 4 job SUCCESS。
- preview [38837915493](https://github.com/Justintunsday/Piliglass/actions/runs/38837915493)
  SUCCESS 4/4（20 tests/11 reports/`pressure[]`），不替代失败门。
- R41（source-demonstrated，非运行时观测）：accessKey-only entry 测试期望
  `boundRefreshReads = 2`，但 `_stagingEntry` 在 guard 前**无条件**先读两个凭据——
  entry accessKey#3 被拒后 refresh#3 仍执行且保持 bound，随后 guard 抛错 → 精确应为
  **3/3**。
- 本地工具链：PATH 无 `dart`/`flutter`，常见安装根目录与深度扫描均未发现可用 SDK
  → **local analyzer unavailable**（不虚构本地分析 pass、不更换 SDK、不引入变通）。

## 修复（最小，无 suppression/无 gate 变更）

1. 4 处 `!..activated` 改直接单 receiver 赋值
   `Accounts.account.get('601')!.activated = true;`（既非重复 receiver、也非单 cascade）。
2. `native_account_hive_export_test.dart:109` `boundRefreshReads` 2→3，并在该测试内补精确
   注释：两个读取都先于 guard 执行、refresh #3 保持 bound、精确 3/3 同时能检测 delayed
   rejection（若 entry guard 被移除会继续 entries/verify 而超过 3）。
3. 修正 `P05_B1E_REVIEW_3658406_REPAIR_PLAN.md` §3 的 "reads=3/2" → 3/3。
4. 其余测试/断言/analysis options/fatal-infos/caps 全部不变。

## 后续

- 最小 commit/push → 新最终代码 SHA 显式 BOTH `ios.yml` + `ios-home-preview.yml`
  （各一次）→ 读实际 evidence（account 实际计数、envelope 109/44/40/245/292/51、
  producer、九 outcome、BUILD/FFmpeg、preview 20/11/压力）→ docs-only 证据（与代码 SHA
  分离）→ Codex 独立复审。四 flag false；不改 UI/`youtube/`/authority；不重跑 unchanged
  `209885f`、不自我验收、不复用旧 SHA 证据。
