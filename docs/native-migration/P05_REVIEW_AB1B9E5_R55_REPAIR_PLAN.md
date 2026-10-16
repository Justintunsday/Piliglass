# P05 修复计划：ab1b9e5 R55 driver 方法名不一致 + new-fetch 取消回归 + native-account provenance（依据 review-ab1b9e5…-codex）

2026-10-16（Asia/Hong_Kong）。依据
`build/native-migration/review-ab1b9e5705febbff51118f1a7b9717a19e4a62ef-codex/REVIEW.md`
TOP TERMINAL DISPOSITION + R55/§33-41。**本计划在修复 edits 之前保存**；仅修 driver/测试
与 native-account 证据脚本，无生产语义变更。**本轮 commit/push 后 STOP，不派发 CI**——等待
Codex SOURCE PREFLIGHT；通过后再由同一 session 各一次 dispatch BOTH workflows。

## 实际证据（保留，不回退/不弱化）

- ab release [38912490252](https://github.com/Justintunsday/Piliglass/actions/runs/38912490252)
  FAILURE（main failure + 4 success；aggregate ACCOUNT_NATIVE failure，其余八项 success，正确
  exit1）；preview
  [38912503290](https://github.com/Justintunsday/Piliglass/actions/runs/38912503290)
  SUCCESS4/4（均首次尝试）。actual account 322/runtime72/strict fatal-infos No issues；BUILD
  109.1MB/executed FFmpeg；preview 20（320.532/89.242/197.711/46.216s）/11 owned/22 streams/
  pressure[]/MacQA45；同轮 envelope 109/44/1/40/**285**/292/51 与 91 raw 89+2 为**另一组件**，
  不替代本组件。
- actual R55 Swift6 strict 编译错误：driver `70/191/206` — `PiliAccountFlutterRepository` 无
  member `exportStaging`；新 fetch 回归未执行、无 native-account 计数借用。91 envelope 账本
  不直接覆盖新 legacy repository/driver。

## R55 修复（无 alias、无跳过、无 Domain/authority 变更）

1. **统一真实方法名**：仓库方法 `PiliAccountFlutterRepository.stagingExport()`（与 Dart
   service 同名；命令仍为 `exportNativeAccountStaging`、nil 参数、严格 codec/错误处理、只读）。
   driver 三处调用从 `exportStaging()` 改为 `stagingExport()`；`P05_B2E2B2_BRIDGE_EXPORT_PLAN.md`
   同步改名。**不新增别名/假方法掩盖漂移**；逐项复核 producer/consumer 签名（参数/返回类型）。
2. **new-fetch 取消回归**（替换对既有 import 取消测试的依赖）：
   - 预取消：先 `cancel()` 再 await → 精确 `CancellationError`、invoker **零调用**、无结果；
   - 受控挂起后取消：gated invoker 挂起 invoke，`cancel()` + 显式 release → await 后守卫抛
     `CancellationError`、**恰一次** invoke、不 decode 结果（`.null` 若被 decode 会成
     `invalidSnapshot`，用例可判别）；所有 task/continuation 确定性结算。
3. **严格 malformed payload 同时经 repository**：schemaVersion 2 / nativeWritesAllowed true /
   空 entries 三种变更 payload → 直连 codec 与 `repository.stagingExport()` 均
   `invalidSnapshot`（保留既有直连 codec 负例/导入检查）。
4. **native-account 自身 provenance（小改）**：`tool/check_native_accounts.py` 记录
   `sourceSHA == workflowSHA`（`git rev-parse HEAD` vs `GITHUB_SHA`）与 raw-byte SHA256：
   actual SOURCES + driver + 两个 producer（`native_account_snapshot_test.dart`/
   `native_account_hive_export_test.dart`）+ 相关 Dart bridge/service
   （`native_account_snapshot_service.dart`/`native_account_snapshot_bridge.dart`）+ 脚本自身；
   compile/run 前后分别复核（源文件与 live.json/hive-reopened.json 输入不变），保留
   120 compile/60 runtime 预算与全部断言。证据全部来自实际 CI，不伪造 SDK/Mac 结果。
5. **措辞修正**：Dart `_capture` 是"先捕获 `revision`、checkpoint 后**乐观复核**"（captures-then-
   revalidates），**不是**获取型 freeze/drain lease；本 fetch 不建立 Block3 freeze，也不等于
   schema-3 durable-identity handoff。（计划文件同步修正。）

## 顺序与边界

- commit/push 修正后的精确 code SHA → **STOP（不派发 CI）**，返回 SHA 供 Codex SOURCE
  PREFLIGHT 复核 diff/签名/测试/Python 证据；通过后同一 session `ios.yml`+`ios-home-preview.yml`
  各一次，最终实际证据与独立复审仍必需。SOURCE PREFLIGHT 是 reviewer 门，不是用户许可缺失/
  全 P05 暂停。
- 保留 ab 编译失败与 381 limited PASS；不重跑 ab；不自我验收/不升 authority；四 flag false；
  Option B（独立 schema-3 envelope wire）仅为后续方向（composition 拥有 freeze/drain 与
  pinned pointer/revision、双向 label 契约、unknown journal fail-closed 不静默 resolve），
  未获批实施。

## 结果（2026-10-16）

- `318bb88`：命名统一（`stagingExport`）+ 新 fetch 取消/严格 malformed 经 repository 回归 +
  14 输入 provenance 落地；actual CI 双 5/5+4/4、native-account 88 checks、14 Git blobs 全
  match、legacy goldens 匹配；**LIMITED PASS**（`review-318bb88…-codex`，仅 legacy schema-1
  fetch/R55 范围）。`ab1b9e5` 编译失败历史保留；OptionB 契约计划另存待 Codex review。
