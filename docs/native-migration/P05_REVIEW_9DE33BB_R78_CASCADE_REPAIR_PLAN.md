# P05 focused repair plan（R78；依据 9de33bb terminal review）：S1 harness 单条 `cascade_invocations` lint 修复

2026-10-17（Asia/Hong_Kong）。依据
`build/native-migration/review-9de33bb0d51793f28e13152fc2ddda4c3ad2a405-codex/REVIEW.md`
TOPLATTERMINALDISPOSITION（CHANGES_REQUESTED，R78）。本文件在编辑前保存；只做 test-only 机械修复；
不改生产/Swift/MethodChannel/UI/workflow/Python；不重开 297/R70–R77；无本地 Dart SDK（仅静态审阅，
不声称实际运行或 14 用例实际通过）。

## 0. 实际终端证据（Codex 已独立核实；不重跑 9de）

- release `38967338930` FAILURE：four companion success + main `117196982733` failure；9 个实际 outcome
  中 ACCOUNT_DART/ACCOUNT_NATIVE/COOKIES/ACCOUNT_ENVELOPE_OUTCOME 四项 failure，最终 gate 显式 exit 1；
  BUILD SUCCEEDED/Runner.app 109.1MB/executed FFmpeg 不覆盖失败 gate。
- preview `38967342688` SUCCESS 4/4；绿色 preview 不构成 missing account execution/Native evidence 的替代。
- 实际 account artifact `12074693731` analyze.log：**唯一一条 fatal-info** ——
  `account_composition_session_contract_test.dart:265:5: cascade_invocations (Unnecessary duplication of
  receiver)`；`--fatal-infos` 使该命令失败（artifact 中无 runtime/flutter-test 日志，14 个用例未实际执行）。
- envelope `12075502205` summary FAILED（reason analyze.log exit 1；同一上游 fatal-info；无 goldens/consumed
  记录）；ACCOUNT_NATIVE/COOKIES 的失败是该上游扫描未执行的下游后果，不是四个独立产品回归。
- 记录精度：Codex source preflight 为 static-only，未捕获该 analyzer diagnostic；不构成 runtime acceptance。

## 1. 修复（机械、语法级；行为不变）

- 位置：`test/utils/accounts/account_composition_session_contract_test.dart` 264–265（A2 用例的
  pre-fired abort fixture）：

  ```dart
  final signal = _SessionAbortSignal();
  signal.abort();
  ```

  → 同一对象、同一时序的单一 cascade：

  ```dart
  final signal = _SessionAbortSignal()..abort();
  ```

- 变量初始化器中的单一 cascade 是允许的（`avoid_single_cascade_in_expression_statements` 只约束
  表达式语句）；`abort()` 仍在构造后立即调用（与原来完全相同），断言、负例、14 个用例与
  R77 ownership/error oracles 全部保留。

## 2. 明确禁止（不扩大改动）

- 不 suppress `cascade_invocations`/`--fatal-infos`、不改 lint/analyzer 设置、不删负例、不改
  workflow/预算/断言；不做超范围收尾、generic plan 重写或 count 声明。

## 3. 验收顺序（获批后的既定流程）

- 机械修复 → 静态审阅（无本地 Dart SDK）→ commit/push NEW code SHA → **STOP BEFORE ANY CI**
  → Codex SOURCE check → 通过后同一 NEW SHA 双 workflow（`ios.yml`/`ios-home-preview.yml`）各一次
  → 实际证据独立复审。
- **不重跑 9de**、不借用 297 preview/artifacts；四 flag false/fallback/Aether/no YouTube（含读取）/
  no UI visual/auth/captcha/真实账户写/no unknown replay/fake device/不弱化断言-预算-门 保持。
