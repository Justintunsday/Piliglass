# P05 Block 1 / B1d：页面只读收口、延迟副作用 admission 与 Hive maintenance gate

2026-10-11（Asia/Hong_Kong）。前置：B1a/B1b/B1c 已在 `405dd5c` 验收（release
38127371993 / preview 38127374136），B2a 已在 `de2223a` 验收（release 38130025898 /
preview 38130028273，transaction 58）。本文件是 B1d 的实施前可执行计划，不改动任何
已验收结论。四能力 flag 保持 false；不接 authority/durable identity；不做 Block 2 的
install/import/delete/buvid durable transaction、账号级队列或生产 composition。

**已实现并验收（2026-10-11）**：实现 `ee58276`、测试 `05433d5`/`3f56f01`、夹具修复
`98e6f9b`；同 SHA release 38132428469 5/5、preview 38132430663 4/4（首次
`initial-top` render 为慢 runner 超时，rerun 通过）；账户 **+239** tests；envelope
108/43/40/58/51、sourceSHA=workflowSHA=98e6f9b；九 outcome success。`close` 的测试
边界：共享测试 Hive 上不执行真实 close，`close` 与 `compact` 共用同一 `quiesce` seam。

## 0. 盘点

| 项 | 位置（现状） | 拟接入边界 | 测试方式 |
|---|---|---|---|
| 页面 `isEmpty/isNotEmpty` | `pages/login/controller.dart:640`、`pages/mine/controller.dart:42,150`、`pages/setting/view.dart:41,221` | `accountCredentialReader.visibleAccounts()` 摘要 | 摘要内容/顺序等价 + 无 activate/reconcile/revision 变化 |
| 页面 `values/toMap`（需要 live owner 做后续切换/导出） | `pages/login/controller.dart:648`、`pages/setting/view.dart:241`、`pages/about/view.dart:245` | 新增 `Accounts.installedAccountEntries()` 纯只读 seam（box 顺序、同内容、零副作用） | 与 `Accounts.account.toMap()` 逐项相同（键序/对象 identity/空/多账号） |
| WK Cookie 镜像 | `LoginUtils.setWebCookie`（`login_utils.dart:23`，调用点 onLoginMain、`Request.setCookie`、webview） | 可选 `admission/coordinator`：有外层 token 则复用；独立调用自带 token；Linux 无写入不 admit | frozen 在任何 WK 调用前拒绝；链内透传不重复 release |
| logout WK/平台删除 | `LoginUtils.onLogoutMain`（`login_utils.dart:90`） | 同上；`set`/`deleteAll` 链透传 `effective` | frozen 在 GetX/WK 前拒绝；`deleteAll` 透传同一 token |
| history 同步副作用 | `RequestUtils.syncHistoryStatus`（`request_utils.dart:48`，onLoginMain、`main.dart:151`） | 可选 `admission/coordinator`；网络与 `localCache.put` 在 token 内 | frozen 在网络前拒绝；独立调用自带 token |
| userInfo 写/删 | `onLoginMain` 的 `GStorage.userInfo.put`、`onLogoutMain` 的 `userInfo.delete` | 由上述两个已 admit 的整体链覆盖；失败分支仍指向调用起点捕获的原 owner `account` | 保持原 owner 变量的用例（结构断言，不改行为） |
| Hive close/compact | `GStorage.compact/close`（`storage.dart:111,124`；调用点 `pages/main/view.dart:144,197,198`） | coordinator 新增非冻结 `quiesce()`：compact/close 先等待在途 admitted 链排空 | 真实 Hive + Completer：在途持久化未释放时 compact 不完成；释放后完成且 box 仍可读 |
| 其余未含 | `native_account_snapshot_service` 的 `account.values`（验证过的 capture 路径）、`GStorage.clear`（经 `Accounts.clear` 已 admit） | 本组不动 | 既有回归 |

## 1. 契约

- 页面 seam：`installedAccountEntries()` 只做 `account.toMap().entries` 的读取；不
  activate、不 reconcile、不 refresh、不写 Hive、不走网络；顺序 = box 顺序；空 box
  返回 `const []`；每次调用都是新鲜读取，不缓存。
- 摘要：布尔检查统一 `visibleAccounts()`；不改变读取时机（State 字段初始化/方法内调用
  点不变）。
- 延迟副作用：外层链（`set`→`onLoginMain`、`deleteAll`/`set`→`onLogoutMain`）只保留
  一个 token；独立调用（`Request.setCookie` 的 WK、`main.dart` 的 history、webview 的
  WK）各自 `tryAdmit`，frozen 时在任何副作用（WK/网络/写盘）之前抛
  `StateError('Account write-back is frozen')`；默认顺序与行为不变。
- maintenance：`quiesce()` 只等待当前 admitted 链，不冻结新 admission；等待期间新
  admission 也会被等待（计数到 0 才完成）；无在途时立即完成。`GStorage.compact/close`
  先 quiesce 再执行原 Future.wait，返回类型/默认行为不变。
- 不削弱任何既有断言；fatal-infos 不放松。

## 2. 测试

1. `installedAccountEntries()`：空 box / 单账号 / 多账号（含 raw key 顺序 `2`、`10`）
   与 `Accounts.account.toMap()` 键序、内容、对象 identity 完全一致；删除后立即为空。
2. `visibleAccounts()`：README 既有测试 + 页面语义等价（isEmpty/isNotEmpty 与 box 一致、
   revision 不变、不激活未安装 owner）。
3. coordinator `quiesce()`：无在途立即完成；在途 gated 链未释放时不完成；等待期间新增
   admission 会延长等待；quiesce 不冻结（等待期间 tryAdmit 非 null）。
4. maintenance：真实 Hive + gated install；`GStorage.compact(coordinator: c)` 在链释放前
   不完成，释放后完成且 `Accounts.account` 仍可读；`close` 为同一 quiesce seam（不在
   共享测试存储上执行真实 close，计划注明）。
5. 延迟副作用 frozen 拒绝：`setWebCookie`/`syncHistoryStatus`/`onLoginMain`/
   `onLogoutMain` 在 frozen coordinator 下于 WK/网络/GetX 之前抛 frozen StateError。
6. 既有账户 suite（230）与屏障测试原样通过。

## 3. 验收与边界

- 小 commit + push；组末同 SHA 显式 dispatch `ios.yml` + `ios-home-preview.yml`；读实际
  artifacts：账户测试实际计数、envelope 108/43/40/35/51、九强制 outcome、BUILD
  SUCCEEDED/109.1MB/FFmpeg、preview 20 tests；失败按日志修复→提交推送→重跑。
- 通过后更新 PROGRESS/STATUS_MATRIX/INVENTORY 并交交付报告。
- 本组不接 authority、不产生 durable identity；不改 Dart authority；四 flag false；
  不动 UI 视觉/Aether/fallback；不触碰 `youtube/`。
