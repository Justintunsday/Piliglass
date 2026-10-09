# P05 CA3 有限组：默认 Dart response write-back admission/drain 协调器

2026-10-09（Asia/Hong_Kong）。实施前保存的计划，不是实现或验收证明。前置为
`55d6add` 已验收的 Restore Vault 修复组与 `build/native-migration/review-55d6add/`
审核。本组只覆盖**响应写回**（AccountManager `_saveCookies` 全部 Cookie/redirect/Hive
persistence await 与 Native HTTP lease `finish` 响应写回），不接 `completeRevert`、
不启动 apply、不启用 NativeActive，四能力 flag 继续 false。

## 文件边界

- 新增 `lib/services/native_accounts/account_write_back_coordinator.dart`：
  - `AccountWriteBackCoordinator`（共享协调域：freeze、admission、drain、live 计数）。
  - `AccountWriteBackOperation`（一次性 token，`release()` exactly-once）。
  - `final accountWriteBackCoordinator` 生产共享实例。
- 修改 `lib/utils/accounts/account_manager/account_mgr.dart`：
  - `AccountManager` 增加可选 `writeBackCoordinator`（默认共享实例），
    `onResponse`/`onError` 把该实例传给 `_saveCookies`。
  - `_saveCookies` 在第一次真实 mutation 前 `tryAdmit()`；null 时零写直接返回；
    成功 admission 时 `try { ...原顺序... } finally { release(); }`。
- 修改 `lib/services/native_http/native_http_request_lease_service.dart`：
  - 增加可选 `writeBackCoordinator`（默认共享实例）。
  - `finish` 在 `_owns` 复查、Cookie 解析之后、第一次 `saveResponseCookies` 前
    `tryAdmit()`；null 时返回 `revoked`（无写、沿用现有跨语言 outcome 词表）；
    admission 覆盖 Cookie save 与 persistence 两个 await，`finally` 恰好释放一次。
- 新增测试：
  - `test/utils/accounts/account_write_back_coordinator_test.dart`（纯协调器 + lease）。
  - `test/utils/accounts/account_manager_write_back_test.dart`（AccountManager 链）。
- 不改 port 默认实现、不加新旁路写、不改 UI/Aether/fallback/依赖。

## 协调域与 operation token 契约

- `tryAdmit()`：未冻结时返回新的 `AccountWriteBackOperation`（identity token），
  冻结后返回 null（零写拒绝）。token 只是生命周期凭据：
  **不是授权身份**，不替代账户 owner/generation；所有原 `_isCurrentBinding` /
  `_owns` / `ownsCredentials` 检查保持原位，token 不能授权任何写入。
- `release()`：恰好一次有效；重复调用 no-op（throw/cancel/finish/abandon/dispose
  路径都由 `finally` 释放一次）。`liveOperationCount` 归零才可能 drain。
- `freeze()`：单向；调用后拒绝新 admission；已 admitted 的链继续到自然完成/错误；
  所有链释放后 drain future 完成。多次 freeze 共享同一排空条件。
- 嵌套 admission 允许（计数递增），不会自锁；drain 等最后一个 token。
- `NativeHTTPRequestLeaseService.dispose()` 清空 `_live/_terminal` **不是** token
  释放，也不代表在途 finish 已结束；in-flight finish 仍由自己的 `finally` 释放。
- 本组没有生产 freeze caller（authority handoff 仍属 CA4），freeze/drain 只由测试驱动。

## 与账户 owner/generation 的关系

- token 不改变原响应写回的所有权语义：A→B→A、普通换号、同 MID successor、
  clear/reset、写后 Hive 错误（不推导未写、不重放、不自动切换）全部保持。
- 已 admitted 链若在 await 期间被撤销/替换，仍按原 `_isCurrentBinding`/`_owns`
  检查停止后续写；drain 只等待链返回，不要求写成功。
- freeze 只阻止**新的**写回 admission；不会取消已 admitted 链，也不清账户状态。

## 测试矩阵（Completer 精确阻塞真实 await）

纯协调器：
1. admission/释放一次有效、重复 release no-op；冻结后 `tryAdmit()` null。
2. 零 admitted 时 freeze 立即完成；有 admitted 时 drain 不提前完成。
3. 嵌套 admission；多个 freeze waiter 同时完成；throw 路径 `finally` 释放恰好一次。

Native lease `finish`（注入独立 coordinator + 现有 await seam）：
4. Cookie await 被 Completer 阻塞时 freeze，drain 不提前；阻塞释放后 finish
   返回 finished、drain 完成、live 0。
5. persistence await 同样覆盖（阻塞/释放/计数）。
6. freeze 后 finish（有 cookies）返回 revoked、jar 无写入、无 admission 泄漏。
7. persistence throw → `persistenceFailed`，token 恰好释放一次，随后 freeze 立即 drain。
8. finish 阻塞时 abandon 返回 consumed、dispose 清表但 drain 仍等；释放后 finish
   结束（closed）且 drain 完成。

AccountManager `_saveCookies`（注入独立 coordinator；真实 Hive/真实 jar，
`_GatedJar`/`_GatedAccount` 用 Completer 阻塞 save/redirect/persistence 的返回 Future）：
9. 第一次 Cookie save await 阻塞时 freeze：drain 不提前；释放后链完成写回、drain 完成。
10. persistence await 阻塞时 freeze：同上，且写入真实 Hive。
11. freeze 后新响应写回零 mutation/零 notify，响应链仍正常完成。
12. 302 redirect：同一个 admission 覆盖原响应 save、每个 Location save 与 persistence；
    中途 freeze 不影响已 admitted 链完成。
13. 阻塞期间同 MID successor 替换：链按原 owner 检查停止后续写；successor 内容不变；
    drain 完成。
14. 生产组合断言：`AccountManager()` 与 `NativeHTTPRequestLeaseService()` 默认使用
    同一个 `accountWriteBackCoordinator`。

## 停止边界与验收

- 本组不覆盖 credential reader、install/import/delete/set/refresh/reset/activation、
  延迟登录副作用、storage close/compact；局部 drain 不能当作全局冻结或 authority
  handoff 依据。
- 保留全部既有回归与断言；不放宽 fatal-infos、不删断言、不 sleep/retry 隐藏竞态。
- 分小提交：计划 → 协调器 → AccountManager → lease → 测试；组末同 SHA 显式 dispatch
  `ios.yml` 与 `ios-home-preview.yml`，读实际日志/artifacts，失败修复后重跑，直到
  release5 + preview4 全绿；九个强制 outcome 与账户/envelope 计数以实际输出为准。
