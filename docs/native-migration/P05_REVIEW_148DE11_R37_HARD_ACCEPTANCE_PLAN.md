# P05 退修计划：148de11 R37（launch 硬失败/报告所有权绑定/有界探针）

2026-10-16（Asia/Hong_Kong）。Codex 对 `148de119e1026455e5db84e736382d67ed0f3ef1`
（R36 诊断增量）复审 CHANGES_REQUESTED：R37（swallow launch 失败后仍接受无关报告）+
诊断承诺未完成（launchctl 探针无 timeout、stdout/stderr 未捕获、缺 before-scroll/
cancellation 阶段证据）。保留 R36 已被认可的 phase/error 仪器化。依据：
`build/native-migration/review-148de119e1026455e5db84e736382d67ed0f3ef1-codex/REVIEW.md`。

## R37 精确问题（源码级反例）

- R36 把 `simctl launch` 的 CalledProcessError 转成 `launchOutput="launch-failed: ..."`
  后**继续**轮询/接受报告。允许交错：前一个 `simctl terminate` 本就忽略返回码、旧实例仍
  存活 → driver unlink layout.json → 新 launch 失败被吞 → 旧实例稍后写出 layout.json →
  轮询见到文件、JSON 解析成功、既有断言可通过——该 mode 实际从未启动。R36 之前的代码会
  硬失败。
- 另：`best_effort_run` 的 launchctl 探针无 timeout（可阻塞、阻碍失败证据上传）；
  stdout/stderr 未捕获（unified log 不等价）；trace 只有 hierarchy 计数与 setContentOffset
  之后的 "scrolled"，无 before-scroll/取消阶段；`scrolled` 记录的仍是**意图** offset。

## 修复设计（保留 30×1s / 25min / 全部 layout 断言与字段语义 / 截图 / UI）

### A. launch 硬失败 + 报告所有权/新鲜度绑定

1. `simctl launch` 以 `subprocess.run(capture_output=True, check=True)` 执行：
   - 失败 → 先写有界 `<mode>-failure.json`（含 stderr/stdout 尾部、trace、探针），
     然后 **原样 re-raise** CalledProcessError（硬失败；绝不进入接受路径）。
2. 每个 mode 生成 `uuid4().hex` **token** 并通过 `--token <token>` 传给 app；
   launch 输出解析 **PID**（`bundle: pid` 形式的数字部分，缺失即视为无所有权）。
3. 接受谓词 `accept_report(report, token, pid, mtime, launch_start)`：必须是 dict、
   `report["modeToken"] == token`、`str(report["launchPID"]) == pid`、`mtime >= launch_start`；
   任何缺失/不匹配 → 不通过（**不以文件存在或诊断作为成功回退**）。
4. 轮询保持 30×1s，但只在**谓词通过**时接受；循环后未通过 → 收集有界证据 + 既有
   RuntimeError（恢复 R36 前的硬失败语义）。
5. app 侧 `layout.json` 增加 correlation 元数据 `modeToken`、`launchPID`
   （视觉/layout 字段与断言不变；settings 报告同样携带）。
6. **确定性负回归**（main() 启动即跑，纯本地、无模拟器）：
   - `selftest_report_acceptance()`：owned-current 通过；stale（mtime 早于 launch）/
     错 token/错 pid/缺 token/缺 pid/非 dict 全部拒绝。
   - `selftest_report_files()`：临时文件 stale-mtime 拒绝、owned-current 通过、
     错 token 拒绝（真实文件路径的负例）。

### B. 有界有区别的探针

- `bounded_probe(args, timeout=20)` → `{"status": "ok"|"timeout"|"failed: ...", "output"}`；
  pre/post launchctl 探针使用它并在 trace/证据中记录 **distinct status**（不把空输出当
  "无进程"）。失败/超时不阻塞证据写入。
- `log show` 失败证据保持 90s timeout + 有界尾部。

### C. 真实 stdout/stderr 捕获与上传

- 运行时探测 `xcrun simctl help launch` 是否含 `--stdout`/`--stderr`（"consult actual
  simctl help"，不臆造 flag）：支持则 launch 带
  `--stdout=<OUTPUT>/<mode>-stdout.txt --stderr=<OUTPUT>/<mode>-stderr.txt`；
  不支持则在 trace 显式记录 `streamsSupported=false`（不静默）。
- 失败时 stdout/stderr 尾部（≤200 行）内联进 `<mode>-failure.json`；workflow 的
  `ios-home-preview` artifact path 增加 `build/home-preview/*.txt`（仅上传管线，
  不动预算/断言/UI）。

### D. before/after-scroll 与取消/编码阶段证据（app）

- `pre-scroll offset/contentSize/insets`（在**任何 setContentOffset 之前**）；
- `post-scroll actual=<真实 contentOffset.y> intended=<offset>`（不把意图当成功滚动）；
- `cancelled-before-inspect` / `cancelled-after-scroll` / `task-cancelled`
  （`Task.isCancelled` 检查）；
- `encode-attempt` → `write-ok/write-fail`（保留 R36 的真实 do/catch）。

## 序列

1. 保存本计划 → 实现（driver + app + workflow 上传 glob）→ py_compile/静态检查 →
   小 commit/push；
2. reconcile：085d883 pair 已完成（release SUCCESS5/5、preview FAILURE 已保留读取，
   不重跑）；
3. 新最终代码 SHA 显式 dispatch BOTH workflows → 读实际 artifacts：若 last-row 仍失败，
   `<mode>-failure.json`（token/pid/streams/phases/探针状态）给出可判别证据 → 选择
   evidence-backed remedy（不再拍脑袋重试）→ 再一个 FINAL SHA BOTH workflows；
   若全绿则按 evidence 文档流程交 Codex。
4. 不自审 PASS、不升级 authority、不声称 B2e-2b/3/whole P05 完成。
