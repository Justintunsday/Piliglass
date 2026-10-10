# P05 Block 1 盘点：reader 剩余读取、延迟副作用与维护写入

2026-10-10（Asia/Hong_Kong）。用户指定的 Block 1 全量盘点，作为 B1c/B1d 的输入。
数字来自当前分支实际 `Select-String` 统计（`lib/**`，2026-10-10），不是估算；本文件
只是盘点与批次计划，不代表任何项已收口。

## B1c：只读收口（csrf/accessKey/gRPC/header/页面）

`csrf` 读取（`\.csrf`，共 122 处，16 个文件）：

| 文件 | 处数 | 文件 | 处数 |
|---|---|---|---|
| `http/fav.dart` | 24 | `http/danmaku.dart` | 5 |
| `http/msg.dart` | 18 | `http/pgc.dart` | 5 |
| `http/dynamics.dart` | 14 | `http/validate.dart` | 2 |
| `http/video.dart` | 14 | `http/danmaku_block.dart` | 2 |
| `http/user.dart` | 12 | `http/login.dart` | 2 |
| `http/live.dart` | 8 | `http/black.dart` | 1 |
| `http/member.dart` | 7 | `http/music.dart` | 1 |
| `http/reply.dart` | 6 | `http/follow.dart` | 1 |

`accessKey` 读取：`http/live.dart` 8、`http/video.dart` 4、`http/login.dart`/`user.dart`/
`member.dart` 各 1；其余为内部实现与 snapshot/reader 自身。

页面只读：`pages/{login,mine,setting,about}` 的 controller/view 使用
`Accounts.account.values/toMap/isEmpty`；`visibleAccounts()` 已提供摘要，但页面尚未切换。

- 现状：请求路径（AccountManager/lease）已走 reader；endpoint 与页面仍是直接读取。
- 2026-10-10 第一批：引入 `Accounts.csrfOf(owner)` 只读访问器（installed owner 经
  `accountCredentialReader.csrfFor`；无当前 generation 时回退原字段，行为等价），
  `lib/http` 全部 **122 处** csrf 读取已迁移（`black/music/follow/danmaku_block/validate/
  danmaku/pgc/reply/video/user/member/live/msg/dynamics/fav/login`）；`\.csrf` 直接字段读取
  归零。测试：`account_csrf_read_test.dart`（真实值、reader 计数、未安装回退、删除后回退）。
- 2026-10-10 第二批：`Accounts.accessKeyOf(owner)` 与 reader `accessKeyFor`（additive）
  落地，`lib/http` 全部 **15 处** accessKey 读取迁移（live 8、video 4、login/user/member
  各 1）；`.accessKey` 直接读取在 `lib/http` 归零。测试：`account_access_key_read_test.dart`
  与 reader 契约新增 `accessKeyFor` bound-owner 用例。
- 剩余：页面 `Accounts.account.values/toMap/isEmpty` 摘要切换；全部迁移后再收紧无
  stamp 回退。
- 本阶段不删除 `Account.csrf`/`accessKey` 原字段。

## B1d：延迟副作用与维护写入

| 项 | 位置 | 现状/计划 |
|---|---|---|
| WK Cookie 镜像 | `LoginUtils.setWebCookie`（`login_utils.dart:22`）；`onLogoutMain` 的 `deleteAllCookies` | 由 `set(main)`/`onLoginMain`/logout 触发；B1d 包一层并纳入 admission 或明确标注延迟副作用 |
| `RequestUtils.syncHistoryStatus()` | `onLoginMain` | 存储副作用；盘点 |
| `GStorage.userInfo` 写/删 | `onLoginMain`/`onLogoutMain` | 存储副作用；盘点 |
| `LinuxCookieManager.deleteAllCookies` | `onLogoutMain` | 平台分支；盘点 |
| `Request.setCookie` | `http/init.dart:58` | `AccountManager` 装配 + `Accounts.refresh()`（B1b 已接屏障）+ WK 镜像 |
| Hive maintenance | `GStorage`/`Hive` close/compact 调用点 | 需逐点盘点（本文件下一轮补全） |
| `native_login_authority` / `ios_native_ui_bridge` 账户调用 | `native_login_authority.dart:105,117,124,166`；`ios_native_ui_bridge.dart:2279,2283` | 已走 B1a/B1b 入口；后续桥接切片复查 |

## 依赖与顺序

1. B1c：先文件小批迁移 csrf/accessKey 读取（行为等价），再页面摘要切换。
2. B1d：先把 `onLoginMain`/`onLogoutMain` 的延迟副作用包进已存在的 admission
   （set/logout 链），再做 Hive close/compact 盘点包装。
3. 全部完成后，Block 1 才可宣告“统一边界”有限达成；P05 authority 切换仍需 Block 2/3
   与 CA5/CA6。
