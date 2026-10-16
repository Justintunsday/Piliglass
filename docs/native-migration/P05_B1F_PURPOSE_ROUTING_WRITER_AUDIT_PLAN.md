# P05 下一组计划：B1f 真实用途路由回归 + writer 边界审计（Block1 前置）

2026-10-16（Asia/Hong_Kong）。依据 TOP handoff（`c6eb327` 有限 PASS 已随 docs-only
`20c2723` 记录）与 review FINAL DISPOSITION：下一实质性组 = **剩余 Block1 的真实用途路由
与 writer 边界审计**（Block3 前置）；不重复已接受 seam、不用未接线 wrapper 冒充 closure。
本文件在实现**之前**保存。

## 真实调用清单（本 session 递归核对）

- **用途路由**（`lib/utils/accounts/account_manager/account_mgr.dart`）：
  - `_findAccount(path)`（278–285）：`ApiType.loginApi` → `AnonymousAccount()`；否则
    `Accounts.get(AccountType.values.firstWhere(ApiType.apiTypeSet[i]?.contains(path)))`，
    无匹配回落 main（`lib/utils/accounts/api_type.dart` 是 path→purpose 常量表）。
  - `options.extra['account'] ??= _findAccount(path)`（294）：调用方可显式 preset 绑定；
  - `_bindRequestAccount`（287–298）：stamp = `Accounts.captureRequest(account)`，绑定存
    `options.extra[_bindingKey]`，retry/redirect 复用首个绑定（不重捕获）；
  - `_isCurrentBinding`（313–322）：`stamp != null && identical(extra['account'], account)
    && identical(stamp.account, account) && Accounts.isCurrentRequest(stamp)`；
  - 消费：`onRequest`（60–143，绑定/拒绝/context 头/`appBaseUrl` gRPC bytes 分支/其余
    Cookie 装载）、`_saveCookies`（219–270，每 await 后重验 + `tryAdmit` 全程覆盖）、
    `_boundRequestAccount`（300–311，NoAccount/app/skip 分支）。
- **writer 边界**（`lib/utils/accounts.dart` + `lib/utils/accounts/account.dart`）：
  | writer | admission | owner/generation 重验 | after-await 重验 | 现有测试 |
  |---|---|---|---|---|
  | installCredentials | `tryAdmit` | `_beginInstall`/`_completeInstall`/`_failInstall` 身份+box 复核 | write 后 `_completeInstall` | overlapping installs / same-MID |
  | importCredentials | `tryAdmit` | 全量 key 校验 + 每 install | write 后 complete + refresh | import 用例 |
  | clear | `tryAdmit` | revokeAll + 匿名 reset 门 | clear/delete 后 `_capturedRestoreFailed` | clear revokes |
  | deleteAll | `tryAdmit` | owned-only 目标 + revoke 先于 await | 完成后 slot 清空 | deleteAll old identity |
  | set | `tryAdmit` | `_resolveSelection` + stamp | onChange/buvid/LoginUtils 前 ×2 重验 slot+stamp | replacement keeps types |
  | selectTemporarily | `tryAdmit` | `_resolveSelection` | 同步路径 | selection 用例（**frozen 零效应待核**） |
  | refresh | `tryAdmit` | `_requireNoCapturedRestore` + reconcile | buvid 仅 owned+未激活 | refresh replacement |
  | LoginAccount.delete / AnonymousAccount.delete | 透传 admission | revoke/`beginAnonymousReset` 先于 await | token/reset 复核 | delete revokes / anonymous reset |
  | restoreEmptyCaptured | 独立 staging 门（`requireEmptyCapturedRestoreTarget` + operation epoch + 写后全量复核） | ✓ | ✓ | reverse-import 组 |
  - 构造期副作用（admission 之外、置于各自门）：`LoginAccount` ctor `cookieJar.setBuvid3()`；
    anonymous 单例懒建 jar；`AnonymousAccount.restoreCapturedState` 需 restore gate；
    `LoginUtils.onLoginMain/onLogoutMain/syncHistoryStatus` 带 admission + R10 时代
    after-await 检查；Hive maintenance/close/compact 走 B1d quiesce（已验收）。
- **现有请求 lifecycle 测试**（`account_request_lifecycle_test.dart` 17 例 +
  `account_manager_write_back_test.dart` 9 例）：全部经 **`extra: {'account': …}` preset**
  绑定（`send()` 固定传 preset）；purpose 槽切换（recommend A→B）在 await 中已有覆盖且
  旧 stamp 保持 current（设计：选择切换不 revoke 旧 owner；响应仍写 A）。
- **实际缺口（本组闭合）**：
  1. 无任何测试走 `_findAccount` 的 **path→purpose 解析**（video/heartbeat/recommend
     各取一个真实 `ApiType.apiTypeSet` 条目），也无 `loginApi → AnonymousAccount`、
     无匹配→main 的覆盖；
  2. 无测试证明"显式 preset 优先于 path 解析"（preset 命中时 `_findAccount` 不应生效）；
  3. path 解析出的绑定在响应 await 中遇到同用途槽切换时，必须保持**原绑定**（不重解析），
     现有测试只覆盖 preset 绑定版本；
  4. ~~frozen 零效应待核~~ **audit resolved（2026-10-16）**：`account_write_barrier_test.dart`
   :325 frozen `set`、:339 frozen `selectTemporarily`、:356 frozen `refresh` 均已断言零效应
   （selection/type/revision/`admittedCount=0`），属**已验收 284 套件**；**不重复不重开**。
   admission token 是 drain 记账而非独占所有权锁；quiesce 有意**不冻结** admission，不得写
   以 quiesce 拒绝写者的测试；writer 表是源码清单，不代表全部 async/Hive/WK/LoginUtils/
   构造期并发效应已闭合。

## 本组切片（B1f，可独立执行）

1. 在 `account_request_lifecycle_test.dart` 增补（复用既有 `_PendingRequest`/storage/`send`
   基础设施；只增不改既有断言）：
   a. **video-path 解析**：用真实 `ApiType` 中 video 条目路径（无 preset）→ 绑定
      `Accounts.get(video)`（video 槽已安装登录 A、main=B 时断言 header/写入落 A），
      请求成功且响应 cookie 写 A、B 零写；
   b. **heartbeat-path 解析 + 匿名**：heartbeat 槽为 anonymous 时绑定匿名单例；主
      `Api.heartBeat` 且非登录 → 既有 reject 语义（复用既有断言模式）；
   c. **loginApi → AnonymousAccount**：即使各槽都是登录，绑定仍为匿名；
   d. **无匹配路径 → main 回落**；
   e. **preset 优先**：传入 explicit account 且路径映射到其他用途 → 绑定 preset、不解析；
   f. **path 绑定 + await 中同用途槽切换**：绑定保持 A（stamp current），响应写 A、新槽 B
      零写（与既有 preset 版对偶）；
   g. 用注入 `CountingCredentialReader`（`AccountManager(credentialReader: …)`）证明绑定后
      请求头经 reader context 消费（计数一次、csrf/accessKey 读取计数精确）。
2. writer 边界审计：上表已固化；frozen `set`/`selectTemporarily`/`refresh` 零效应由
   `account_write_barrier_test.dart`:325/339/356 既有覆盖（见 §实际缺口 4，audit resolved）；
   本组只补**经证明**的剩余缺口（当前无新增目标）；不因补齐通用矩阵而改已验收 writer。
3. 明确不闭合（不得声称）：120/17 live `csrfOf`、18/8 live `accessKeyOf` 的 tagged 类型
   迁移；WK Cookie 镜像广度；LoginUtils 全部延迟副作用；Hive maintenance 细节；网络
   writer（proxy/retry/TLS/timeout）；B2e-2b durable bridge/frozen revision；Block3
   composition/handoff/revert/startup/GC；Block4/5。

## 边界与验收

- 测试只增；若真实缺陷被发现 → 聚焦修复（同组范围内，不改 authority）；不弱化任何断言/
  预算；四 flag false；不改 UI/`youtube/`；不真实账户/设备伪造。
- 小 commit/push；新最终**代码** SHA 显式 BOTH `ios.yml` + `ios-home-preview.yml` →
  读实际 evidence → docs-only 证据（与代码 SHA 分离）→ Codex 独立复审。
