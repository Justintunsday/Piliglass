# P05 修复计划：R45 runner 生命周期修正（每次循环检查 / EOF 非完成 / 进程组清理 / 收尾精度）

2026-10-16（Asia/Hong_Kong）。依据 TOP handoff 与
`build/native-migration/review-ea4c60955eb3309dcd46d4bc090cbe7f726157df-codex/REVIEW.md`
（CHANGES_REQUESTED / R45）。**在代码修改之前保存**。

## 实际事实

- `ea4c609` 双绿（release 38854592091 5/5、preview 38854594993 4/4，均首次）且正常路径被证实：
  navigation phases 实际上传（xcodebuild launch 05:19:47Z/exit 0/export 05:26:15Z），9 个
  navigation tests 293.430s **逐行流入 job log**。这只证明 normal-success 可观测性，**不**
  证明 timeout/cancel 语义或历史 hang 根因。
- R45 reviewer 以 actual-imported `preview_step_runner` 跑负例 QA（`runner_review_qa.py`），
  实际失败：busy-output timeout=0.05s → 返回 0/1.391s（应 StepTimeout）；busy-output
  cancel 0.05s → 返回 0/1.359s（应 StepCancelled）；stdout-EOF-live-child timeout=0.1s →
  返回 0/0.844s（应 StepTimeout）。根因（源码可证）：cancel/deadline 只在
  `except queue.Empty` 检查；EOF sentinel 立即 break → 阻塞 `process.wait()`。
- 另一源码缺口：`terminate_process_group` 只看 leader `poll()`，leader 退出后同组
  忽略 TERM 的 descendant 可存活；无 SIGKILL 升级。

## 修复（`tool/preview_step_runner.py`，不含生产 UI/预算变更）

1. 循环重构：**每次迭代开头**检查 `cancel_event`/deadline（与输出可用性无关）；EOF
   sentinel 视为 **stream 状态而非子进程完成**——继续有界 0.2s poll，直到
   `process.poll() is not None` 且队列排空才 break；EOF/exit 与 cancel/deadline 竞争时
   不得返回 success。
2. 进程组：Popen 后立即 `_capture_process_group()` 记录自有 PGID；`terminate_process_group`
   改为组感知——leader 存活 **或** 组仍存活都发 SIGTERM，等待（leader 已退出且组消失）的
   有界循环，超时后对**同一 PGID** SIGKILL 升级（仅自有组，绝不触碰无关 PID/组）；
   non-POSIX fallback 仅 terminate/kill 直接子进程。`run_streaming` 的 finally 在**所有**
   退出路径调用有界组清理（正常完成后也清理遗留 descendant）。
3. 新增 `run_bounded_cleanup(command, phases, name, timeout=600)`：best-effort、**绝不
   抛异常掩盖主失败**（TimeoutExpired/任何 Exception → 记录 phase 并返回 None）。
4. `preview_ios_navigation.py` 的 attachments export 改用该 helper；注释收窄：
   "non-cancelled 退出路径保留证据；硬性 job cancel 仍可能跳过 upload"；主
   timeout/cancel/nonzero 失败在 export 失败时**原样保留**。

## 回归（actual-imported，均在本机 `py` 实际执行；POSIX 用例按平台标注）

1. busy/backlogged 输出：timeout=0.05 且子进程输出 1s+ → StepTimeout；同 busy + 0.05s
   cancel → StepCancelled。
2. 早 EOF 存活子进程：关闭 stdout 后仍存活 0.8s、timeout=0.1 → StepTimeout；无 timeout
   时返回真实 exit code（非 0 前不得 success）；EOF 后 0.05s cancel → StepCancelled。
3. returncode 保留（既有 7 语义）与既有 15 项全部保留。
4. `run_bounded_cleanup`：exit 0 / exit 5 / 可执行缺失（抛异常 → None 且不抛出）。
5. POSIX-only（`os.name == 'posix'`，Windows 明确打印 SKIP）grandchild：子进程 spawn 忽略
   SIGTERM 的孙进程并立即退出；清理后孙进程在 3s 内不得写存活 marker。为让该用例在
   **真实 POSIX** 执行，workflow 在 navigation 前新增一步运行本地 QA（秒级、不改预算）。

## 边界与验收

- 不改 25min 预算/断言/等待/手势/UI；不加生产 deadline；无 catch-success/假证据；
  本地 QA 仍非模拟器证据（POSIX 用例在 macOS CI 执行才是真 POSIX 证据）。
- 新最终代码 SHA 显式 BOTH workflows → 读实际 evidence → docs-only 证据 → Codex 独立
  复审；不重做 R43/R44 已接受部分、不自我验收、不推进 authority/下一组。
