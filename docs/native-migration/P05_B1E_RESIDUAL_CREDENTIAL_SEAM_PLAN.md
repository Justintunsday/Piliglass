# P05 下一组计划：B1e 残余凭据消费清单 + refresh tagged binding 与导出消费者对齐

2026-10-16（Asia/Hong_Kong）。依据 TOP handoff（`ea60931` 有限 PASS 后的下一组）与
`review-ea609317e499a200b1d1fcc55d5a9127aba9e44d-codex/REVIEW.md` FINAL DISPOSITION：
先以 docs-only 记录 limited PASS（已随 `5c4ab67` 完成，测试代码 SHA 为 `ea60931`）；
本文件在实现**之前**保存。依据既有计划：`P05_REMAINING_SCOPE_PLAN.md` Block 1、
`P05_TAGGED_BOUND_READER_PLAN.md` carry-forward、`P05_BRIEF.md`。
本组只做**只读凭据 read seam**：不接 authority、四 flag false、不改 UI/Aether、不碰
`youtube/`、真实 Hive/Keychain 写入仅限测试夹具、不降断言/预算。

## 真实消费者清单（本次实际递归 grep，2026-10-16）

| 消费面 | 实际调用点 | 现状 | 本组处理 |
|---|---|---|---|
| `csrfOf(` | **123 处 / 17 文件**：fav24、msg18、dynamics14、video14、user12、live8、member7、reply6、pgc5、danmaku5、login2、danmaku_block2、validate2、follow1、black1、music1（+`accounts.dart` 定义） | legacy wrapper：stamp 被拒 → StateError 不回退 raw；no-stamp → 历史直读（含删除后旧值兼容，文档化） | **不迁移调用点**（有限组；保持既有 fail-closed wrapper） |
| `accessKeyOf(` | **16 处**：live8、video4、login1、member1、user1、`ios_native_ui_bridge`1（+定义） | rejected → null；no-stamp 非 retired → 直读；bound(null) 合法但 legacy 类型不可区分 | 保持；新增 refresh 对称 binding |
| 直接 `.csrf`/`.accessKey` 字段读取（account 基础设施之外） | **0 处** | — | — |
| `grpcHeaders`（gRPC metadata） | 定义 `account.dart`（LoginAccount `GrpcHeaders.newHeaders(accessKey)`、anonymous 一份）；唯一请求消费 `account_mgr.dart:89`（app+bytes） | 经 `credentialReader.captureRequest`（`captureRequest` stamp + `_isCurrentBinding`）绑定上下文，rejected 请求直接 reject | **已收口**，不改 |
| REST `headers` | 定义 `account.dart`；消费 `account_mgr.dart:94` | 同上绑定上下文 | 已收口，不改 |
| app-sign `access_key` | `account_mgr.dart:104-107` 用 `credentials.accessKey`（captured context） | 绑定上下文 | 已收口，不改 |
| native lease 头 | `native_http_request_lease_service.dart:187/254`：`Accounts.captureRequest` + 可注入 `credentialReader.captureRequest` | 绑定上下文，已有 DENY 回归 | 已收口，不改 |
| `refresh`（refreshToken） | `account_live_memory_shadow.dart:137`、`native_account_snapshot_service.dart:59/163`、`account_adapter.dart:33`（Hive 持久化，非消费）、`account.dart` `toJson`（持久化） | 前两者在各自 capture/stamp/revision 守卫下**直读字段**，不经 reader seam；无 `boundRefresh` 类型 | **本组对齐**（导出消费者经 tagged reader；持久化不变） |
| snapshot service 其他调用者 | `native_account_snapshot_bridge.dart`（loadNativeAccountSelection/exportNativeAccountStaging）、`native_login_authority.dart`（currentOwnerWire/resolveOwner）、多测试 | `_capture()` 已用 `Accounts.captureRequest`（ownsCredentials 门） | 本组只加可选 `credentialReader` 注入口并让 accessKey/refresh 读取走 bound 断言 |
| shadow capture 调用者 | `native_account_live_memory_capture.dart`、多测试 fixture | 已有 busy/owner/stored 一致性守卫；accessKey/refresh 直读 | 本组把两处读取对齐 reader seam + 增加注入 seam 供 fail-closed 回归 |

**残余未闭合（不得声称）**：123 `csrfOf`/16 `accessKeyOf` 调用点的 tagged 类型迁移、
其余 Block1 writer 边界（install/import/delete/set/select/refresh/clear/activation、WK 镜像、
LoginUtils 延迟副作用、Hive maintenance）、B2e-2b bridge export/frozen-revision、Block3
composition/handoff/revert/startup/GC、Block4/Block5 全部未闭合。

### R39 清单修正（2026-10-16，取代上表对应数字）

上表数字来自非递归 glob，遗漏 pages/widgets 调用点；经递归复核（`lib/` 递归、排除
`youtube/`、文本匹配非 AST、分类定义/注释/live）修正为：

- `csrfOf`：raw 124 匹配/18 文件 = 定义 1（`accounts.dart:103`）+ 注释 3
  （`video.dart:368`、`msg.dart:379`、`dynamics.dart:137`）+ **live 调用 120/17 文件**。
- `accessKeyOf`：raw 19/9 文件 = 定义 1（`accounts.dart:120`）+ **live 调用 18/8 文件**。
- 补记实际消费者：`pages/member_profile/view.dart:348` accessKeyOf、`:523` csrfOf、
  `common/widgets/video_popup_menu.dart:104` accessKeyOf（均走既有 wrapper；本组不改 UI、
  不批量迁移）。
- 文本匹配数不是 AST live-call 计数，不证明 coverage；详见
  [P05_B1E_REVIEW_3658406_REPAIR_PLAN.md](P05_B1E_REVIEW_3658406_REPAIR_PLAN.md) §2。

## 切片契约（B1e：refresh tagged binding + 导出消费者对齐）

1. `account_credential_reader.dart`：
   - 接口新增 `boundRefreshFor`（tagged）与 `refreshFor`（legacy nullable wrapper，
     映射既有 `accessKeyFor` 语义）；`DartAccountCredentialReader` 实现：`_isBound` 失败
     → `rejected`，否则 `bound(owner.refresh)`（合法 null 属 bound 数据）。
   - 既有 `csrf`/`accessKey` 成员与语义**不变**。
2. `accounts.dart`：
   - 新增 `boundRefresh(owner, {reader})`（tagged）与 `refreshOf(owner, {reader})`：
     stamp!=null → `reader.refreshFor`（rejected/合法 null → null，绝不回退 raw）；
     no-stamp 且非 retired → 历史直读 `owner.refresh`；retired no-stamp → null。
     与 `accessKeyOf` 完全同型；沿用 `_requestState.capture`，不新增/放宽身份检查。
3. `native_account_snapshot_service.dart`（加法式）：
   - 构造器新增可选 `AccountCredentialReader credentialReader = accountCredentialReader`；
   - `stagingExport`：`accessKey`/`refreshToken` 值改经 `boundAccessKeyFor/boundRefreshFor
     (account, capture.stamps[account]!)`；任一 `!isBound` → 抛既有
     `NativeAccountSnapshotException('snapshotChanged')`（fail closed，绝不含 raw 值）；
     `_descriptor` 的 `hasAccessKey/hasRefreshToken` 同源读取；
   - 默认 reader + 合法 capture 下输出与现状**逐值等价**（`native_account_hive_export_test`
     的 accessKey/refreshToken 断言不变）。
4. `account_live_memory_shadow.dart`（part of accounts.dart）：
   - `accessKeyUnits`/`refreshTokenUnits` 读取改经 `boundAccessKeyFor/boundRefreshFor
     (account, stamps[i])`；`!isBound` → `AccountLiveMemoryShadowException('unavailable')`；
   - `Accounts.captureLiveMemoryShadow({AccountCredentialReader reader = accountCredentialReader})`
     增加可选 reader 参数（加法式，多调用点默认不变），作为 fail-closed 判定的窄测试 seam；
   - busy/容量/stored 一致性守卫与所有既有语义不变（restore/recovery 窗口原本已 'busy'）。
5. 测试 fixture：`CountingCredentialReader`/`DeniedCredentialReader` 增加
   `boundRefreshFor`/`refreshFor`（只增成员；`Denied` 返回 rejected/null）。

## 回归矩阵（只增不减）

1. 新 `test/utils/accounts/account_refresh_read_test.dart`（新文件，`git add -f`）：
   - 安装 owner → `boundRefresh` bound 真值、`refreshOf` 真值、计数 reader 路由命中；
   - `LoginAccount(refresh: null)` 安装 → bound(null) 是数据、`refreshOf` null；
   - `DeniedCredentialReader` → `boundRefresh` rejected、`refreshOf` null、**不进 raw 字段**；
   - no-stamp（未安装/删除后）→ `refreshOf` 历史直读；retired no-stamp → null；
   - stale-owner-after-await：旧 stamp → rejected；`requestRevision` 零效应。
2. `native_account_hive_export_test.dart`：保持既有逐值断言（等价性由它承担）；新增
   `NativeAccountSnapshotService(credentialReader: DeniedCredentialReader())` →
   `stagingExport` 抛 `snapshotChanged` 且不产生任何条目（fail closed、无 raw 泄漏）。
3. `native_account_snapshot_test.dart`：合法 capture 下 descriptor/entries 值与 raw 字段
   一致；`selectionSnapshot` 不回归。
4. `native_account_live_memory_capture_test.dart`/`native_account_reverse_import_test.dart`：
   既有 fixture 输出不变（等价性）；新增 `Accounts.captureLiveMemoryShadow(reader:
   DeniedCredentialReader())` → 抛 `unavailable`（stamped-but-denied 绝不产出凭据 wire）。
5. 既有 269 account tests、`account_access_key_read_test`/`account_csrf_read_test`/
   `account_manager_write_back_test` 等全部保留，不弱化。

## 验收与边界

- 小 commit：本计划 → reader/Accounts → 消费者对齐（snapshot/shadow）→ fixtures/回归 →
  docs 证据；同一最终代码 SHA 显式 dispatch BOTH `ios.yml`(release5) +
  `ios-home-preview.yml`(preview4)（各一次）；读实际 logs/artifacts（account 计数只增、
  envelope 109/44/40/**245**/**292**/51、九 outcome、BUILD/FFmpeg、preview 20/11/压力）；
  交 Codex 独立复审后再进入下一组；docs-only 证据与代码 SHA 分离。
- 不降 269 account/245 transaction/292 queue 基线、180/90 预算、任何断言/门禁；不自我验收、
  不推进 authority/下一组（B2e-2b 剩余 bridge/Block3 仍依赖先决条件）、不伪造设备证据。
