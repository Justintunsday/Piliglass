# P05 修复计划：R46 runner 完成竞态 + POSIX/集成负例 + 两处 preview 断言诊断

2026-10-16（Asia/Hong_Kong）。依据 TOP handoff 与
`build/native-migration/review-f84314a6743c75cffcc1fdfd0dfb2f37902b404c-codex/REVIEW.md`
（CHANGES_REQUESTED / R46）。**在代码修改之前保存**。

## 实际事实（不虚构）

- `f84314a`：release 38857143502 SUCCESS5/5（九 outcome、293 account、native/producer/
  hashes/goldens 正）；preview 38857146364 FAILURE（account6/player2 PASS；image 3 中
  comment-zoom FAIL、navigation 9 中 `testCurrentSettingsAndPersistentGestures` FAIL；
  main 本次为**真实失败**非 hang：phases launch 05:59:04Z/exit 65/export 0 证明 runner
  非掩蔽失败保留；pressure step 被跳过、**无** `pressure[]` 证据）。
- R46 reviewer 以 actual-imported 模块复现：早 EOF（关闭 stdout/stderr 后仍存活 0.15s，
  短于 0.2s poll 窗口）timeout=0.08 → **返回 0/0.234s**（应 StepTimeout）；cancel 0.08 →
  **返回 0/0.406s**（应 StepCancelled）。根因：`except queue.Empty: if poll()!=None: break`
  在阻塞等待之后不再重查 cancel/deadline；完成路径 wait/drain 之后也无最终重查。
- POSIX 用例缺 readiness handshake：孙进程可能尚未装好 SIG_IGN 就被清理，marker 缺失不能
  证明 escalation 分支；需 Mac 实际执行（QA step 已在 workflow）。
- navigation 失败证据（保留 AX attachments）：My 按钮存在 36.41s、tap 39.28s/合成 39.67s，
  41.38s 立即 tap 设置失败；失败层级 HOME selected/My unselected、无设置。`openMine()`
  仅等按钮存在 8s 后 tap，**无选中页后置条件**；settings/persistence 断言未执行。
- image 失败证据：fitted 1.0 值 16s 断言通过；doubleTap 后 5s 内 value 仍 "1.0 倍"；
  AX frame {{162,106},{78.3,695.7}}、nested scroll 402x695.7；非 pinch/非 launch 基础设施；
  **手势为何未触发 zoom 未证**。

## 修复

1. **runner（`tool/preview_step_runner.py`）**：每次阻塞等待之后、提交正常完成之前
   重查 cancel/deadline：`queue.Empty` 分支先查 cancel/deadline 再判 `poll()`；完成路径在
   `wait()+drain()` 之后再最终重查一次（已观察到的 cancel/expiry 一律不得返回 success，
   按 cancel>deadline>exit 优先级处理）；无 cancel/expiry 时保留精确 returncode。
   不缩短 poll、不加生产 deadline、不改 25min 预算。
2. **QA（`tool/check_preview_step_runner.py`）**：
   - 早 EOF 短命子进程（0.15s < poll 窗口）：timeout=0.08 → StepTimeout；cancel 0.08 →
     StepCancelled；无 cancel/expiry → 精确返回 0/4；
   - POSIX readiness handshake：孙进程先装 SIG_IGN 再写 `ready`，父进程等 `ready` 后才退出；
     测试断言 `ready` 存在、`alive`（3s 后）不存在且清理耗时受限 ⇒ SIGKILL escalation 实际
     发生（Windows 明确 SKIP 不算 PASS；Mac CI 执行）；
   - 保留既有 busy/长 EOF/慢 sink 正例。
3. **navigation 集成负例**：在 `preview_ios_navigation.py` 提取实际
   `run_navigation(run, result, phases, export_command=None, export_timeout=600)`（main 的
   finally 契约本体），QA 以注入 run（返回 0/2、抛 StepTimeout/StepCancelled）× export
   （正常/非零/缺失可执行/超时）驱动**实际函数**，断言 primary outcome 原样保留、export
   失败不掩盖、成功路径正常返回（不再只测 helper）。
4. **navigation harness precondition（证据驱动）**：`openMine()` 在单次 tap 之后增加
   **选中页后置条件**：有界 8s 等待 `isSelected == true`（无新增 tap/无重试/无更长
   deadline），使"真实切换成功"成为后续 tap 的前置；不动其余断言。
   > R47 精度修正（2026-10-16）：该后置条件是存在性 8s **之后另加**的一次有界 8s 等待
   > （两次顺序 8s 上界），**不是**共享同一 8s 窗口、也不是零新增等待；单次 tap、既有
   > 各 8s 取值与 25min job 预算均不变。
5. **image harness 诊断（证据驱动、保留语义）**：fitted 1.0 的 16s 等待不变；在
   doubleTap 前增加 hittability 前置断言；5s zoom 断言改为等义的有界观测（同一 5s 上界、
   同一谓词、失败信息携带实际 observed value/hittable），不重试 tap、不放宽/跳过断言；
   明确记录"手势未触发 zoom 的原因未证"。

## 边界与验收

- 不改 5s/16s/8s/25min 预算语义、不改生产 UI visual、无 catch-success/假证据/盲重试；
  本地 mock QA 非模拟器证据（POSIX/集成 case 在 Mac CI 执行）。
- 小 commit/push → 新最终代码 SHA 显式 BOTH workflows → 读实际 evidence（QA 输出/acount/
  image/nav/主 preview/pressure 若可执行）→ docs-only 证据 → Codex 独立复审。
- 四 flag false；不重做 R43/R44/R45 已接受部分、不自我验收、不推进 authority/下一组。
