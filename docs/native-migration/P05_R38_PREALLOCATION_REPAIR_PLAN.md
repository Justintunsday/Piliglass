# P05 R38 修复计划：schema-3 durableIdentity 单元并入同一预投影累计账本

2026-10-16（Asia/Hong_Kong）。依据 TOP handoff 与精确 SHA
`build/native-migration/review-ed89e9fef44bcbd10f8371d583e3c378741cd6cf-codex/REVIEW.md`
（CHANGES_REQUESTED，R38）。Codex 独立确认 `ed89e9f` 的 release38824131940 SUCCESS 5/5 +
preview38824134718 SUCCESS 4/4（九 outcome、BUILD 109.1MB/FFmpeg、account 268/72、strict
analysis clean、109/44/40/245/292/51、producer 8/10/2、88 raw blob 86 match+2 declared
pubspec、preview 20 tests/11 owned reports/22 streams/`pressure[]`）；该绿色只证明旧路径实际
运行，**不关闭 R38**。本计划在代码修改之前保存（session 写入），随后才编辑生产代码。

## R38 事实（精确源码）

- `lib/services/native_accounts/native_account_reverse_import.dart`：
  - `_preflight`（205–223 行）只对 key 以 `Units` 结尾且值为 List 的字段调用
    `budget.reserveUnits(length)`；`durableIdentity` 不在其中 → schema-3 identity 的
    36 UTF-16 units **不进入**预投影累计账本（节点仍计，units 漏计）。
  - record 循环（163–167 行）里 `_canonicalDurableIdentity(identity)` 先构造
    `String.fromCharCodes`、再 `identities.add`（Set 插入），**之后**才
    `budget.reserveUnits(36)` → 晚计费。
  - 后果：其他字段恰好用满 unit 预算的 schema-3 信封能通过 `_preflight`，随后才在 record
    key/credential/identity 的 String/Set 投影阶段开始分配并最终 `resourceLimit`；违反既有
    “所有资源记账先于 Strings/Cookies/owned 副本”的显式契约，且与 Swift codec preflight
    不一致（`PiliAccountLiveMemoryShadowCodec.swift` 155–169 行对每条 record 先
    `countUnits(record["durableIdentity"], maximum: 36, nullable: true)`）。
  - 边界：总 ceiling 仍最终生效、identities 逐条 36 units/最多 255 login records、四 flag
    恒 false，**不是**无界内存或已部署 authority 回归；这是新增 schema-3 路径上的
    晚拒绝/预投影契约回归。现有 resource 回归是 schema2 33×65536 Cookie 值（旧 preflight
    即失败），测不到本边界。

## 修复（最小、无双重计费、不改 caps）

1. `_preflight` 记账条件扩为 `key.endsWith('Units') || key == 'durableIdentity'`：identity
   数组长度与其他 `*Units` 数组一样在 String/Set/record 投影之前进入**同一**累计
   `budget.reserveUnits` 账本。
2. 删除 record 循环中的 `budget.reserveUnits(36)`（避免双重计费）。36 units 精确形状、
   canonical（小写 hex、hyphen 8/13/18/23）、跨 record 唯一检查全部保留在
   `_canonicalDurableIdentity` 与 `identities.add`，不动其错误码与语义。
3. 不动 `maxUTF16Units`/node/bucket/cookie caps、不动 wire 校验、不动任何 shape/隐藏语义、
   不动 `apply()`/flags/authority；decode 仍是纯函数、零写。

## 回归测试（只增不减；actual Dart decode）

新增顶层测试（真实 capture + `_schemaThreeEnvelope` 构造，测试内 `_chargedUnits` 镜像
“base 2048 + 512×records + 所有 `*Units`/`durableIdentity` 列表长度”并用显式 key/name/
domain/path 的 padding cookies 精确落到目标总量，decode 前自检总量相等）：

1. **exact-budget**：含 1 条 login canonical identity（36 units）的信封总 units 恰
   `NativeOrderedCookieJarExporter.maxUTF16Units`（测试同时断言该常量 == 2×1024×1024，防 caps
   漂移）→ decode 成功、identities 按序暴露 → 证明 identity **只计一次**（双重计费会
   `resourceLimit`）。
2. **one-unit-over**：同构信封恰 +1 unit → `resourceLimit` → 证明 identity 确在账本内（若实现
   漏计 identity，该信封内部仅 cap−35，会错误成功）。
3. **preprojection rejection**：非 identity 字段恰用满 cap，identity 为 37-unit 非 canonical
   数组 → 必须 `resourceLimit`（预投影账本先抛），而旧行为会在 canonical 检查先抛
   `invalidEnvelope`。该断言即“resourceLimit 发生在 record/String 投影之前”的可判定证据，
   无需测试 seam。

扩展既有 schema-3 测试：

4. 37-unit 非 canonical identity（普通预算下）→ typed 拒绝（计划 §4 承诺，当前仅覆盖 35）。
5. `generationHighWater: null` 显式值 → 接受（与“整个 key 省略”并列的合法 schema-3 形态）。
6. anonymous record **省略** `durableIdentity`（legacy 10-key 形状）→ 接受，位置仍 null。
7. 既有 schema2 混入拒绝、nullable anonymous、no-high-water、duplicate/大写/hyphen 位移等用例
   与断言全部保留，不重写。

## 边界与验收

- 不改 authority/flag/UI/`youtube/`/真实账户；不降 account 基线（268 → 只增）、245
  transaction/292 queue、180/90 预算或任何断言/门禁；Dart 测试只增。
- 小 commit/push；新最终**代码** SHA 显式 dispatch BOTH `ios.yml` + `ios-home-preview.yml`
  （同一 SHA、各一次）；读回实际 evidence（九 outcome、counts、88 hashes/goldens、strict
  analysis、BUILD/FFmpeg、preview 20/11 reports/`pressure[]`）后做**分离的 docs-only 证据
  commit**（不得冒充 code CI SHA）；交 Codex 独立复审，接受前不得自称 PASS、不得推进 authority
  或下一组。
- 明确未做（不得声称）：bridge export 携带 durable identity、frozen-revision
  handoff/startup apply、revert 幂等映射、GC、Block3 production composition、真机/真实账号；
  已接受 R23–R37 不重做。

## 修复结果（2026-10-16，Codex 有限 PASS）

- 修复/回归/证据见 `PROGRESS.md`、`P05_STATUS_MATRIX.md`、`P05_COMPLETION_REPORT.md`
  §16：代码 SHA `ea60931`（源 `2b07b85`、测试 `a0e76ed`、strict-info 修复 `ea60931`；
  计划 `232355e`/`3664662`）经 release38829392361 5/5 + preview38829396589 4/4（首次
  尝试）实际执行，R38 边界测试实际运行；Codex 独立复核 FINAL DISPOSITION = limited
  PASS（仅该 decode/carriage 范围）。
- 前驱失败如实保留：`ed89e9f` 绿色但 R38 open；`a0e76ed` strict-info fatal +
  aggregate 失败（preview 4/4 不替代）。本文件不改写任何既有条目。
- 仍开放：`apply()` 携带 durable labels、Swift→Dart 端到端 handoff、bridge export/
  frozen-revision/startup/revert/GC/Block3 composition。
