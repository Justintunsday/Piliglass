# P05 下一有限组：tagged-bound credential reader（no-stamp / rejected / bound-nullable 区分）

2026-10-15（Asia/Hong_Kong）。Codex 对 `b7f6692` 的 FINAL DISPOSITION 有限 PASS 只覆盖
B2e-1 in-process queue/receipt/unknown-resolution 组件，并明确授权下一步：**先闭合
53aed63 保留项①**——`boundCsrf`/`boundAccessKey` 的 tagged 区分与真实消费者盘点，
再进入 B2e-2（持久恢复面）/B2e-3（生产 composition）。依据：
`build/native-migration/review-b7f66928cbe9a02cb78d0be83bdc40b7319c4b20-codex/REVIEW.md`、
`build/native-migration/codex-review-53aed63/REVIEW.md` 的 "Remaining acceptance notes"、
`docs/native-migration/P05_DURABLE_IDENTITY_QUEUE_PLAN.md` 第 1 节保留项①。
本组只做**只读凭据边界**，不接 authority、不改 UI/Aether、四 flag 保持 false、
不删 Dart fallback、不真实账户写、不碰 `youtube/`、不降断言/预算。

## 现状与缺口（精确源码）

- `lib/utils/accounts.dart`：
  - `boundCsrf`（62–69 行）=`_requestState.capture(owner)` 非空时调用
    `reader.csrfFor`；返回 `String?`，把"未安装（无 stamp）"与"有 stamp 但 reader 拒绝"
    都压成 null。
  - `boundAccessKey`（74–81 行）同型 `String?`：把"未安装"、"reader 拒绝"与
    "合法无 accessKey"三者压成 null。
  - `csrfOf`（86–89 行）=`boundCsrf(...) ?? owner.csrf`：**有 stamp 但被 reader 拒绝
    （revoked/retired/恢复窗口/Hive close/存储对象替换）时回退到旧直接字段**，即保留项
    所指的 fail-open 缺口。
  - `accessKeyOf`（94–102 行）已对 retired owner fail closed（null），有 stamp 时直接
    用 reader 值（拒绝→null），仅无 stamp 且非 retired 时保留旧兼容直读；缺口只是
    "拒绝 vs 合法 null"在类型上不可区分。
- `lib/services/native_accounts/account_credential_reader.dart`：
  - 接口 `csrfFor`/`accessKeyFor` 返回 `String?`；`DartAccountCredentialReader._isBound`
    = `identical(stamp.account, owner) && Accounts.isCurrentRequest(stamp)`。
  - `Accounts.isCurrentRequest` = `_requestState.isCurrent && ownsCredentials`；
    `ownsCredentials`（accounts.dart 112–127 行）会在 restore/recovery 捕获窗口、
    `_anonymousReset`、retired、`_owners` 身份不符、Hive 关闭/存储对象不符时返回 false
    ——而这些状态下 `_requestState.capture` 仍可能有 stamp，正是"rejected stamped
    context"窗口。
- 真实消费者（本次盘点的结论，不声称"全部 reader 已收口"）：
  | 消费者 | 位置 | 状态 |
  |---|---|---|
  | 请求头 assembly（app/REST + gRPC headers/accessKey） | `account_mgr.dart onRequest` 经 `captureRequest`，null→既有 revoked 拒绝 | 已 fail closed |
  | Native lease 头 assembly | `native_http_request_lease_service.dart _captureInput` 经 `captureRequest` | 已 fail closed |
  | `csrfOf` | `lib/http/{video,live,user,msg,fav,dynamics,pgc,music,member,login,validate,reply,follow,…}` 100+ 调用点 | 本组改为 rejected 不得回退 |
  | `accessKeyOf` | `lib/http/video.dart`(4)、`live.dart`(8)、`user.dart`、`member.dart`、`login.dart`、`ios_native_ui_bridge.dart`、`video_popup_menu.dart`、`member_profile/view.dart` | 现行为已 fail closed；补 tagged 区分 |
  | `visibleAccounts` | 页面 login/mine/setting/about + `native_account_snapshot_service` | 只读摘要；不改 |
  | 已验证快照 | `native_account_snapshot_service.stagingExport`（自身 `isCurrentRequest` + checkpoint 后直读 accessKey/refresh） | 已有 owner/generation 校验，列盘点不改 |
  | 残余直读（后续组） | 其余 `grpcHeaders`/`refresh`/endpoint 直读点 | 文档保留，不在本组扩大 |

## 契约（tagged 三态）

- 新 `AccountCredentialBinding { notInstalled, rejected, bound }` +
  `AccountBoundCredential<T>`（`binding`、`value`、`isBound/isRejected/isNotInstalled`）：
  - `notInstalled`：`_requestState.capture(owner)` 为 null（从未安装/已卸载）——**显式
    无 stamp 旧兼容路径**，由调用方决定是否直读旧字段。
  - `rejected`：capture 非空但 reader 判定非当前（revoked/retired/恢复窗口/Hive
    close/存储对象不符/foreign stamp）——**fail closed，绝不回退直接凭据**。
  - `bound`：reader 接受；`value` 为真实值，**nullable credential 的合法 null 属于
    bound 而不是 rejected**（例如缺失的 accessKey）。
- 接口新增 `boundCsrfFor`/`boundAccessKeyFor`（tagged 主契约）；
  `csrfFor`/`accessKeyFor` 保留为 legacy nullable wrapper（实现归约到 tagged）。
- `Accounts.boundCsrf`/`boundAccessKey` 改为返回 tagged 结果（无生产消费者，仅测试，
  签名变化安全）；`Accounts.csrfOf`：no-stamp → 历史直接读（保持既有 throw/null 语义，
  含 `LoginAccount.csrf` 缺 `bili_jct` 时的原抛错），rejected → **StateError**
  （类型仍是 String，fail closed），bound → 真实值；`Accounts.accessKeyOf`：no-stamp →
  非 retired 才直读，rejected → null，bound → 值（nullable）。owner/stamp/generation
  检查沿用 `_requestState.capture` + `isCurrentRequest`，不新增/放宽身份检查。
- 纯读/零副作用：不 activate 未安装对象、不改 revision、不写 jar/Hive/网络。

## 回归矩阵（只增不减）

1. tagged reader：安装 owner → `boundCsrfFor` bound(真值)、`boundAccessKeyFor`
   bound(值)；删除/替换/foreign stamp → rejected；`requestRevision` 不变。
2. 合法 nullable：安装 `accessKey == null` 的 LoginAccount → `boundAccessKeyFor`
   bound(null)（不是 rejected）；legacy `accessKeyFor` 与 `accessKeyOf` 仍 null。
3. reader 拒绝：安装 owner + `DeniedCredentialReader` → `boundCsrf`/`boundAccessKey`
   rejected；`csrfOf(reader: denied)` 抛 StateError（不回退 `owner.csrf`）；
   `accessKeyOf(reader: denied)` null。
4. 真实状态拒绝：安装 owner 后把同 key 的存储对象替换（`Accounts.account.put`）→
   `_ownsStoredObject` false 而 stamp 仍在 → tagged rejected、`csrfOf` 抛
   StateError、`accessKeyOf` null、revision/指针零效应；`restoreEmptyCaptured` 捕获窗口
   对 anonymous stamp 的 rejected 语义（不占用真实写路径）。
5. stale-owner-after-await：capture stamp → `await` → 删除/替换 → 用旧 stamp 调
   `boundCsrfFor/boundAccessKeyFor` → rejected；Accounts 层 `accessKeyOf` retired → null；
   `csrfOf` 走 no-stamp legacy（历史值）——分别断言，明确不是 rejected 回退。
6. no-stamp legacy 保持：未安装 owner 的 `csrfOf`/`accessKeyOf` 历史行为不变
   （含 `csrfOf` 删除后旧值兼容测试保留并改标题注明 no-stamp 语义）。
7. 既有 258 账户测试不降；`csrfOf` 路由计数测试保留（仍经 legacy `csrfFor` 计数）。

## 验收与边界

- 小 commit：计划 → reader/tagged 类型 → Accounts 包装/消费者语义 → fixtures/回归 →
  文档；同一最终代码 SHA 显式 dispatch `ios.yml`(release5) +
  `ios-home-preview.yml`(preview4)；读实际 logs/artifacts（账户计数只增、envelope
  109/44/40/245/148/51、九 outcome、BUILD/FFmpeg、preview 20/压力）；交 Codex 独立复审。
- 明确未做：B2e-2 持久恢复、B2e-3/Block3 生产 composition、endpoint 100+ csrf 调用点
  的 tagged 消费迁移（本组只保证 legacy wrapper 不再 fail open）、snapshot/refresh/
  grpcHeaders 残余直读、CA5/CA6 真机与 authority。四 flag false，P05 未完成。
