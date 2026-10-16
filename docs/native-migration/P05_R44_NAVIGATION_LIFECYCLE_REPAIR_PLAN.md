# P05 R44 修复计划：navigation 生命周期可观测性与有界清理

2026-10-16（Asia/Hong_Kong）。依据 TOP handoff 与
`build/native-migration/review-d5f9d0c565d0c1963084bb44e502f71b912a1325-codex/REVIEW.md`
（CHANGES_REQUESTED / Latest disposition）。**在代码修改之前保存**。

## 实际事实（已核对，不虚构）

- release [38850795369](https://github.com/Justintunsday/Piliglass/actions/runs/38850795369)
  SUCCESS5/5：actual account **293**/runtime72/strict clean、native 109/44/40/245/292/51、
  producer 8/10/2、89 raw blob 87+2、current goldens——R43 源/运行时为正，不重做。
- preview [38850798160](https://github.com/Justintunsday/Piliglass/actions/runs/38850798160)
  FAILURE：account-pages 116811341828 FAILURE（6 tests/1 failure：
  `testGuestDoesNotShowAccountData` 在 `app.launch()`（generatedNavigationTests.swift:8）
  因 XCTest 无法终止上一 app PID 8289 而失败，**未到达 guest 断言**）；main 116811341741
  **CANCELLED**（annotation 原文 "The job has exceeded the maximum execution time of
  25m0s"；metadata 04:29:20Z→04:59:20Z 含清理，源码 workflow `timeout-minutes: 25` 未变；
  home-render step 04:37:49Z 成功后 menu/navigation step 一直 in_progress；pressure 与 3 个
  always-upload 步骤均未执行）。
- 日志恢复已穷尽：`gh api .../jobs/116811341741/logs` → BlobNotFound；
  `gh run view --job --log` → log not found；本 attempt **无 main 计数/断言/pressure 证据**，
  不臆造。job 元数据：account-pages 04:37:13Z→04:49:56Z failure；main 04:29:20Z→04:59:20Z
  cancelled。

## R44 缺口（源码可证，非根因结论）

`tool/preview_ios_navigation.py main()` 用无界 `subprocess.run(... stdout=log)`：
tail 16000 字符的 print 与 xcresult attachments export **只在子进程正常返回后**执行。
卡住的子进程会吃满外层 25 分钟 job：live phase/test 输出不进入 job log，attachments/phase
证据不上传（`if: always()` 在 job 取消后不执行）。**不知道**具体卡在哪个 app/XCTest 阶段，
不得声称。

## 修复（诊断/containment，非掩蔽；不改预算/断言/UI）

1. 新增 `tool/preview_step_runner.py`（纯 Python、无副作用、可本地测试）：
   - `run_streaming(command, log_path, phases, name, timeout=None, cancel_event=None)`：
     tee 子进程 stdout/stderr → 本地 log **与** job stdout（逐行 flush）；phase 时间戳标记
     写入 `phases.log`（flush+fsync）并打印；读取线程 + queue，支持注入 cancel event 与
     可选 timeout；
   - 失败语义**非掩蔽**：nonzero 返回码原样保留（并重打 tail 供 grep）；timeout/cancel 抛
     `StepTimeout`/`StepCancelled`；
   - 有界清理：`terminate_process_group(process, grace)` = SIGTERM → grace（默认10s）→
     SIGKILL 进程组（`start_new_session=True`）；SIGTERM handler 设 event，主循环 0.2s 内
     响应并做同一有界清理，随后 re-raise（CI 仍失败）；
   - **不安装新生产 deadline**（遵守 no arbitrary shorter test budget / no extended
     deadline）；production 以 job 级 25min 预算为准。
2. `preview_ios_navigation.py main()`：xcodebuild 改用 `run_streaming`；attachments export
   移入 `finally`（任何退出路径上有 xcresult 就尝试，`check=False` + 有界 `timeout=600`），
   使**非取消**的失败也会导出证据（可被 always-upload 上传）；nonzero 仍
   `raise SystemExit(code)`。
3. 本地负例 QA：新增 `tool/check_preview_step_runner.py`（success / nonzero /
   timeout / cancel + 进程已终止断言），用 `py` 在本机实际运行并保留输出——**本地 mock QA
   不是模拟器/XCTest 证据**，仅证明 runner 语义。
4. 不改 workflow 预算/步骤结构、不改任何测试断言/等待/手势、无 catch-success/假证据。

## 边界与验收

- 小 commit/push → 新最终代码 SHA 显式 BOTH `ios.yml` + `ios-home-preview.yml` → 读实际
  evidence（含新的 live 输出/phases.log 上传路径）→ docs-only 证据 → Codex 独立复审。
- account-pages launch/termination 失败按 review 保留现状：无盲目重试；如重复再做独立
  诊断（本组不弱化/不改 UI）。main 根因未证，仅收窄不确定性。
- 四 flag false；不改 UI/`youtube/`/authority；不重跑 unchanged `d5f9d0c`、不自我验收、
  不声称 whole Block1/P05 关闭。
