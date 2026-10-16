# P05 R42 修复计划：player-controls fixture 支持值 + configured-vs-effective 断言

2026-10-16（Asia/Hong_Kong）。依据 TOP handoff 与
`build/native-migration/review-ae73dcf742b0b0a64fb4b3a2894443a73179b05a-codex/REVIEW.md`
（CURRENT DISPOSITION / R42）。**在代码修改之前保存**。

## 实际事实（保留 artifact 本 session 复核）

- `ae73dcf`：release [38840294035](https://github.com/Justintunsday/Piliglass/actions/runs/38840294035)
  SUCCESS 5/5（九 outcome、BUILD SUCCEEDED/109.1MB/FFmpeg；284 account/72/strict clean；
  109/44/40/245/292/51；producer 8/10/2；89 raw blob 87+2）；preview
  [38840297066](https://github.com/Justintunsday/Piliglass/actions/runs/38840297066)
  FAILURE：main/image/account 3 job SUCCESS，**player-controls**（job 116778602289）FAILURE。
- 实际失败时间线（`preview-player.log`，本 session 复核）：`playback-state` ~5.97s 找到；
  landscape 判定 11.29s；`720P` `isHittable` 查询 11.30–13.39s 为 false；center tap 于
  13.41s 发起，但 "Check for interrupting elements" 持续到 **20.90s 才 Synthesize event**；
  `waitForExistence(720P, 8s)` 21.34s 起每 ~1s 检查至 29.37s 均不存在；29.40s 层级快照。
- 失败时 AX 层级（attachment 5F9CBB1C…txt，本 session 复核）：仅 Window(874x402)/嵌套
  Others + **lock button** + probe `playing=true;rate=1.5;time=61;rates=[]`；AX 树中
  **观察到的**只是 chrome/720P 元素**缺失**（注意：`chromeViews` alpha=0/隐藏 chrome
  是生产代码支持的**推断**，并非直接采样的 alpha 遥测）。`testEmbeddedGestures` 通过；
  landscape 用例在 launch helper 的 720P 存在断言失败，之后的手势/lock 断言未执行。
- **R42 具体缺陷（proven fixture defect）**：`tool/check_ios_player_controls.py` FIXTURES
  写入 `UserDefaults.standard.set(60.0, forKey: PiliNativePlayerPreferences.hideDelayKey)`；
  生产 `PiliNativePlayerPreferences.hideDelay`（`ios/Runner/PiliNativePlayer.swift` 524–527）
  只接受 `[3, 5, 8]`，否则回落 3 → fixture 从未获得 60，实际生效 3。
- **假说（未证明，按 review 记录为假说）**：H1 effective-3 与 tap 合成延迟（请求 13.41s →
  实际 20.90s）叠加使 chrome 在检查窗口内不可见；H2 单 tap chrome 切换在 AX 中未被观察到；
  H3 AX 快照/合成延迟；H4 手势识别器交互。均**不**声称根因已证明；未来绿色运行也**不**构成
  因果证明。

## 修复（只改 harness；生产 UI/策略零改动）

`tool/check_ios_player_controls.py`：

1. 新增常量 `FIXTURE_HIDE_DELAY = 8.0`（生产支持的最大值）并替换 fixture 写入
   （`__FIXTURE_HIDE_DELAY__` 占位符；附注释说明只接受 3/5/8、其余静默回落 3）。
2. probe 追加生效值：`...;hideDelay=\(PiliNativePlayerPreferences.hideDelay)`（读取的是
   同文件内嵌的**真实生产偏好 slice**）。
3. `launch()` 在 `state.waitForExistence` 后新增断言
   `state.label.contains("hideDelay=__FIXTURE_HIDE_DELAY__")` —— configured-vs-effective
   确定性检查；任何 60→3 式静默回落都会在启动阶段立刻失败。
4. `__main__` 中新增生产支持值解析（从真实源文件 `hideDelay` 块提取 `[3, 5, 8]`）并
   `raise SystemExit` 拒绝不支持的 fixture 常量（跑 20 分钟前先失败）。
5. 其余全部保留：720P/landscape/手势/lock/embedded 断言、10/10/8/8 超时、tap 前置条件、
   20 分钟 job 预算、无新增 retry；workflow 继续上传 xcodebuild.log/xcresult/attachments
   作为判别性失败证据。

## 边界与验收

- 本地：`python -m py_compile` + 复制的支持值解析/替换逻辑单独验证（无 Xcode/SDK，
  xcodebuild 只能在 CI 执行）；不虚构本地 Swift 构建 pass。
- 新最终代码 SHA 显式 BOTH `ios.yml` + `ios-home-preview.yml` → 读实际 evidence →
  docs-only 证据（与代码 SHA 分离）→ Codex 独立复审。本修复**不**声称已修复/证明历史
  失败的根因；绿色重跑不是因果证明。
- 四 flag false；不改生产 UI visual/player policy、不碰 `youtube/`、不真实账户/设备伪造。

## 修复结果（limited PASS，2026-10-16）

- 代码 SHA `c6eb327`（harness-only；前置计划 `d1fb50c`）经 release
  [38843199175](https://github.com/Justintunsday/Piliglass/actions/runs/38843199175) 5/5
  与 preview [38843202056](https://github.com/Justintunsday/Piliglass/actions/runs/38843202056)
  4/4（首次尝试）实际执行：**两个 player 用例实际通过**（embedded 19.6s、landscape
  17.6s；720P 于 8.24s 找到），configured-effective/手势/lock 断言均在通过路径执行；
  Codex 独立复核 FINAL DISPOSITION = limited PASS（仅该 fixture 修复范围）。
- 精度（Codex 明确要求并已写入 `PROGRESS.md`）：ae73dcf 失败时观察到的只是 AX 树
  chrome/720P **缺失**；alpha=0/隐藏 chrome 是生产代码支持的**推断**而非直接 alpha
  遥测；本次绿色**不是**历史 tap/AX/timer 链条的因果证明，H1–H4 假说保持未证。
- `8.0` 是生产支持值内的 fixture 策略选择，**不是**超时放宽或生产策略变更；10/10/8/8
  超时、20 分钟预算与全部断言未动。
