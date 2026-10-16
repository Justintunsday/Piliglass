# P05 修复计划：R49 通知宿主 fixture + 播放器 landscape 720P 前置条件修复

2026-10-16（Asia/Hong_Kong）。依据 TOP handoff 与
`build/native-migration/review-8d86327bcfab43735186615795f63bf722b95c74-codex/REVIEW.md`
（TERMINAL DISPOSITION / R49）。**在实现之前保存**。

## 实际事实（已核对，不虚构）

### 账户侧（release 38878930059 main 失败）

- 实际 suite **315 = 314 PASS + 1 FAIL**；strict analyze No issues、runtime72；
  native 109/44/40/245/292/51、producer 8/10/2、90 raw 88+2、current goldens 均正；
  这些不构成 R48/R49 组验收。
- 唯一失败：`tvPlayUrl cancels instead of sending after a pre-binding same-MID replacement`
  （即 N3），实际先发生正确的取消（`Account credentials are no longer current`），随后
  `LateInitializationError: Field 'contextToast' has not been initialized.`
  栈（release-main.log 实际读取）：`DialogProxy.contextToast → CustomToast → SmartDialog.showToast
  → AccountManager.toast.<fn> account_mgr.dart:215 → AccountManager.onError:177 → realDio →
  Request.get → VideoHttp.tvPlayUrl:1086 → 测试 455/459`。
- 根因事实：生产 `AccountManager.onError` 对非 POST 错误调用 `toast()`，其 `.then` 里执行
  `SmartDialog.showToast(…)`；`DialogProxy.contextToast` 只在真实 `FlutterSmartDialog` widget
  build 时赋值（本 session 亲自拉取 resolved fork 5a1be84 主源码
  `init_dialog.dart`/`dialog_proxy.dart`/`toast_tool.dart`/`smart_dialog.dart` 复核）。
  fixture 没有任何 widget/通知宿主 → `contextToast` 未初始化 → 异步 UI 错误。这不是
  production UI 缺陷（main.dart 用 `FlutterSmartDialog.init(...)` + `SmartDialog.config.toast`
  正常接线）。
- 精度：该 run 中只有 N3 被报告失败；后续两个同样走取消/通知路径的替换用例
  （feedDislike/feedDislikeCancel）在该次运行中通过（其未处理错误的上报时点/归属机制仅凭这
  一次观察未完全确定）。修复对**三个**取消路径都安装宿主，使任何归属时点都不可能再出现未处理
  UI 错误。禁止：吞 Flutter error / allowlist LateInitializationError / 把 URL 改成
  github skipShow 假 fixture / 绕过 error interceptor / 全局禁用通知 / 删除用例 /
  为通过而改生产 toast 行为。
- fork 自带受支持测试宿主模式（同源码复核）：`pumpSmartDialogApp(tester)`
  = `tester.pumpWidget(MaterialApp(builder: FlutterSmartDialog.init(), home: …))` + `pump()`；
  `dismissAndPump`/`disposeSmartDialogApp` 用有界 pump 关闭并清理（`_close` 会 cancel
  `displayTime` timer，`overlayEntry.remove()`）。

### 播放器侧（preview 38878934786 player116900670094 失败）

- 实际 2 tests：embedded PASS 110.951s；landscape FAIL 157.322s，失败点
  `NavigationTests.swift:24` = `XCTAssertTrue(app.buttons["720P"].waitForExistence(timeout: 8))`。
  xcodebuild-test exit65、attachments-export exit0、final exit65；不是编译错误/硬取消。
- 实际时序（preview-player.log 实际读取，t 为用例内秒数）：0.11 设 landscapeLeft；
  2.27 interfaceLandscapeRight；7.54 等 `playback-state` 10s（8.73 找到）；9.81/9.84
  Find app；**9.87 `Find the "720P" Button`（= `isHittable` 前置查询）→ 下一操作
  23.44 `Waiting 8.0s for "720P" Button to exist`：13.57s 内没有任何其他操作/合成 tap**
  （相邻日志行）；23.44–31.45 反复 `Checking existence` 缺失；31.47 断言失败。
- 失败层级（ABCC9CA6，实际读取）：window 874x402，只有 **锁定播放器 Button + playback-state**
  （`playing=true;rate=1.5;time=61;rates=[];hideDelay=8.0`）——控制条已隐藏，质量/seek 控件
  不在层级。后续 screenshot/exerciseGestures/lock 断言未执行（未证明通过）。
- 精度：attachment `D29B89CF…png`（2.79MB）经 manifest 核对是 **embedded 用例**
  的 `embedded-player-controls` 截图（rates=[2.0,1.5]/time=162），**不是** landscape 失败现场；
  landscape 失败证据是日志时序 + 层级 + UI Snapshot/录屏时间戳（recording 起 1792142502，
  失败 1792142534 ≈ +32s）。`isHittable` 在 ~10s 时生成了两张 UI Snapshot（1792142512），
  与该 hit-test 的 13.57s 阻塞一致。
- 候选（证据支持，未证明为唯一根因/flake）：hit-test 型前置查询（`isHittable`）可长时间阻塞，
  消耗掉生产 `hideDelay` 8s 的自动隐藏窗口，且其返回不触发 reveal，导致随后 8s existence
  等待开始时控制条已隐藏。既有 production `toggleControls`/auto-hide 行为正常。

## 修复 A（账户 fixture：真实通知宿主）

1. `test/utils/accounts/account_http_consumer_routing_test.dart`：
   - `setUpAll` 中按 main.dart 接线：`SmartDialog.config.toast =
     SmartConfigToast(displayType: SmartToastType.onlyRefresh);`
   - 新增 `_pumpNotificationHost(WidgetTester)`：
     `tester.pumpWidget(MaterialApp(navigatorObservers: [FlutterSmartDialog.observer],
     builder: FlutterSmartDialog.init(toastBuilder: CustomToast.new),
     home: const SizedBox.shrink()))` + `pump()`（真实 `CustomToast`/observer/Overlay 宿主）。
   - 新增 `_disposeNotificationHost(WidgetTester)`：有界 pump 完成入场动画 →
     `SmartDialog.dismiss(status: SmartStatus.allToast)` → 2~3 次有界 pump（~250ms/3s）→
     unmount（`pumpWidget(SizedBox.shrink())`）→ `pump()`；并断言
     `SmartDialog.checkExist(dialogTypes: {SmartAllDialogType.toast}) == false`
     （通知工作/计时器不得跨测试泄漏）。形状对齐 fork 官方 `dismissAndPump`/`disposeSmartDialogApp`。
   - 把三个走取消/通知路径的用例改为 `testWidgets`：N3
     `tvPlayUrl cancels instead of sending after a pre-binding same-MID replacement`、
     A3 `feedDislike cancels instead of sending after a pre-binding recommend replacement`、
     C2 `feedDislikeCancel cancels instead of sending after a pre-binding recommend replacement`：
     每个先 `_pumpNotificationHost(tester)`，再用 `tester.runAsync(() async { …现有真实
     run/取消/零 fetch/Error 断言原样… })`，最后 `_disposeNotificationHost(tester)`。
   - 其余用例（plain `test`）与全部既有断言/计数不变；`setUp`（真实 zone）与现有 adapter/
     interceptor 装配不变。
2. 该回归即“取消在已初始化宿主下结算为 Error/零 fetch 且无未处理 UI 错误”的实际证明；
   不弱化/删除任何断言；不 mock SmartDialog；不改生产通知代码。

## 修复 B（播放器 harness 前置条件）

`tool/check_ios_player_controls.py` 的 landscape launch() 中，把唯一的前置 reveal 判据
`if !app.buttons["720P"].isHittable` 改为廉价层级查询 `if !app.buttons["720P"].exists`
（注释引用实际 13.57s hit-test 阻塞与隐藏控制条层级）；隐藏时仍只做**一次** center tap
reveal，随后 `XCTAssertTrue(app.buttons["720P"].waitForExistence(timeout: 8))` 原样保留。
不改 orientation10/720P8/hideDelay8/25min/其他断言/真实手势；不改生产 UI/策略；
不提高 hideDelay；不延长预算；不盲重试。候选未被证明为唯一根因，本修复是证据支持的最小
harness 前置条件修复；实际 CI 执行结果决定是否收敛。

## 边界（不闭合）

- R48 六项红→修复后 314+1 的实际结果保留；本次修复后仍需 BOTH workflows + Codex 独立
  复审才可能有限接受；不重跑 unchanged 8d86327、不自我验收、不推进 authority/下一组。
- 仅四个 VideoHttp builder 的 R48 范围与这两个 harness/fixture 面；120 csrf/18 access、
  gRPC、generic purpose CAS、writer async closure、B2e-2b bridge/frozen revision、
  Block3 composition/handoff/revert/startup/GC、Block4/Block5 均未闭合。
- 本地无 Dart/Flutter SDK（无本地运行声明）；Swift/simulator 证据只在 Mac CI 产生；
  fixture 是离线受控 adapter，非真实网络/账户写入/设备证据。
- 四 flag false、Flutter/Dart fallback、Aether 独立、不读/改 `youtube/`、无 UI visual/
  真实账户写/auth/captcha/设备伪造；保留 a50 limited PASS 与全部历史失败记录。

## 验收

小 commit/push → 新最终代码 SHA 显式 BOTH workflows（各一次）→ 读实际 evidence
（account 315 全过/strict analyze、native/hash/goldens、九 outcome、BUILD/FFmpeg、preview
20 UI/11 owned reports/pressure）→ docs-only 证据（与代码 SHA 分列）→ Codex 独立复审。
