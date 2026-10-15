# P05 退修计划：085d883 R36（preview last-row 缺失报告的判别性诊断）

2026-10-16（Asia/Hong_Kong）。Codex 在 `085d883e8a924d4053b23bc5e383d1b71dc188b5`
的复审（CURRENT DISPOSITION/R36）给出 CHANGES_REQUESTED：新的 readiness-retry harness
**已实际执行**（main-preview job 116703630704 于 22:31:18UTC FATAL
`No layout report for last-row`），light/dark/large-text 报告仍存在，artifact 12010604817
仅 3 JSON+3 PNG、无进程/阶段/写入证据；readiness 假设不足，根因未证。native artifact
12011756780（同 085d883）通过 transaction245/queue292，已接受的 75d829c recovery 代码
不受影响、不重开。依据：
`build/native-migration/review-085d883e8a924d4053b23bc5e383d1b71dc188b5-codex/REVIEW.md`。

## 必须区分的失败机制（当前 artifact 无法区分）

1. app 未启动 / 被终止 / 崩溃（launch 失败、被杀、异常退出）；
2. 启动成功但检查到错误/缺失的层级（scroll/tab bar 未就绪或未匹配）；
3. 阻塞在 scroll/layout/main actor（`setContentOffset(bottom)` 大偏移卡死）；
4. task 未调度或已取消；
5. 报告 JSON 构造/文件写入失败（`try?` 静默）；
6. 外层读到错误 container/代际（容器路径变化/旧实例残留）；
7. terminate→launch 竞态（旧实例仍在运行，launch 只前台化旧进程，新检查从未发生）。

## 诊断设计（有界；不改 30×1s 外层轮询/25min job 预算/断言/报告字段/UI）

### Python harneess（`tool/preview_ios_home.py`）

- 每个 mode：
  - 启动前记录容器路径、删除 `layout.json` 与诊断文件（避免陈旧/错配报告），
    并记录 pre-launch `launchctl list` 中 HomePreview 相关行（旧实例证据）；
  - **捕获 `simctl launch` 输出并解析 PID**（当前被丢弃），与 mode/appearance/args
    关联写入 `build/home-preview/launch-trace.json`（每 mode 追加：pid、容器、
    preLaunchInstances、reportDelaySeconds、diagnosticsPresent）。
- 外层轮询保持 30×1s；成功路径不变。
- 缺失报告时（仅失败路径）以有界方式收集证据并写入 `<mode>-failure.json`（JSON 会被
  现有 artifact glob `build/home-preview/*.json` 上传；不新增 txt 依赖）：
  - 完整 trace 条目 + `missingReport`；
  - 应用诊断 `layout-diagnostics.jsonl` 尾部（≤400 行，内联文本）；
  - post-failure `launchctl list` HomePreview 行（liveness/exit 证据）；
  - `simctl spawn log show --last 2m --style compact --predicate 'process == "HomePreview"'`
    尾部（≤200 行，subprocess timeout 90s，stderr 丢弃）；
  - 宿主 `~/Library/Logs/DiagnosticReports/HomePreview*` 最近 1 个文件尾部（≤100 行）
    与文件名列表；
  - 然后抛出与既有完全相同的 `RuntimeError(f"No layout report for {name}")`。

### 生成的预览 app（APP 注入串）

- 新增只写独立诊断文件 `layout-diagnostics.jsonl`（append；失败回退创建）的有界
  `diagnosticsTrace`：`timestamp pid=... event`。
- 打点：`app-init`（含参数与 pid）、`task-start`、每次
  `inspect-attempt n` / `inspect-success n` / `inspect-exhausted`、
  `window-missing`、`hierarchy scrolls=...` / `hierarchy-missing`、
  `scrolling offset=...`、`write-ok bytes=...` / `write-fail <error>`、
  settings 分支同理。
- 报告写入改为真实 do/catch：写失败记 trace 并返回 false（触发既有 8 次有界重试），
  **不新增重试次数**、不改 `layout.json` 内容/字段/断言。
- `layout.json` 仍是唯一验收 artifact：诊断文件与成功报告分离，partial/stale/mismatched
  诊断永不作为成功；失败仍由外层既有 30×1s 门禁报错。

### 约束

- 不增加 retry、不加宽 timeout/poll/job 预算、不删/弱化断言、不伪造报告、不改真实
  UI 视觉、不动 production 源（仅 `tool/preview_ios_home.py` 的 harness 注入代码与
  driver 逻辑）。
- 诊断仅是证据收集；**诊断本身不是 gate 通过**。纠正后的 FINAL SHA 必须 BOTH
  workflows 全绿（preview 4/4，11 reports，20 tests，pressure[]）才谈验收。

## 序列

1. 保存本计划 → 实现诊断（driver + app 注入）→ py_compile/静态检查 → 小 commit/push；
2. reconcile 在途 085d883 runs（preview 其余 jobs/release 仍活跃，preserve/read，
   不取消不重播）→ 完成后读取其全部结果；
3. 新最终代码 SHA 显式 dispatch BOTH workflows → 读实际 artifacts：若 last-row 再现，
   `<mode>-failure.json` + launch-trace 将给出可判别证据 → 选择 evidence-backed remedy +
   定向回归 → 再一个 FINAL SHA BOTH workflows；若全绿则按证据文档流程交付 Codex。
4. 交 Codex 独立复审；不自审 PASS、不升级 authority、不声称 B2e-2b/3/whole P05 完成。
