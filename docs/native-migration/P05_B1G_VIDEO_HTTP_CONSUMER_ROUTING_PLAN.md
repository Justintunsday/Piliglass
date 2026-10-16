# P05 下一组计划：真实视频 HTTP 消费者凭据用途路由回归（B1g）

2026-10-16（Asia/Hong_Kong）。依据 TOP handoff（`a50ea69` 有限 PASS 已随 docs-only
`803ae2e` 记录）与 review FINAL DISPOSITION 的继续授权：下一组 = **真实 Block1 生产请求
构建者的凭据消费/用途路由回归**。本文件在实现**之前**保存。

## 依据与范围

- review 明确未闭合：whole Block1 的 120 csrf/18 access 全量迁移、gRPC purpose binding、
  generic purpose CAS read-transform-publish 干扰、whole writer async closure。
- 本组只取一个**真实生产者集群**：`lib/http/video.dart` 中直接消费
  `Accounts.accessKeyOf(...)` 的 4 个真实 Builder，经真实 `Request.dio` + 真实
  `AccountManager` 拦截器 + 离线受控 adapter 驱动；不做全量调用点迁移、不加未接线
  wrapper、不重复已接受的 raw-path/预设绑定用例。

## 真实调用清单（本 session 实际核对，2026-10-16）

| Builder（实际函数） | 请求路径（实际常量） | path→purpose 解析 | 凭据消费位置 | 拦截器分支/效果 | nullable/gate |
|---|---|---|---|---|---|
| `VideoHttp.tvPlayUrl`（video.dart:1047） | `Api.tvPlayUrl` = `/x/tv/playurl` | `AccountType.video`（apiTypeSet video 条目） | builder 自身把 `accessKeyOf(get(video))` 写入 query `access_key`/`mobile_access_key` 并 `AppSign.appSign` | web 分支：注入 owner `headers`（x-bili-mid/aurora）、Cookie jar 装载；响应 Set-Cookie 经 `_saveCookies` 写回绑定 owner | video 槽匿名 → 两个 key 参数按 `?accessKey` 省略；绑定匿名单例 |
| `VideoHttp.dislikeVideo`（video.dart:454） | `Api.dislikeVideo` = `https://app.bilibili.com/x/v2/view/dislike` | 无匹配 → main 回落 | gate `accessKeyOf(Accounts.main)`；POST Map 由拦截器 app 分支注入 `access_key` + `appSign` | app 分支：headers 注入但无 Cookie、无写回 | main 匿名 → gate 直接 `Error`、fetchCount 0 |
| `VideoHttp.feedDislike`（video.dart:477） | `Api.feedDislike` = `.../x/feed/dislike` | `AccountType.recommend` | gate `accessKeyOf(get(recommend))`；GET query 由拦截器注入 `access_key` + `appSign` | app 分支：同上 | recommend 匿名 → gate `Error`、fetchCount 0 |
| `VideoHttp.feedDislikeCancel`（video.dart:506） | `Api.feedDislikeCancel` = `.../x/feed/dislike/cancel` | `AccountType.recommend` | 同上 | 同上 | 同上 |

精度注记（源码核对，不虚构）：

- `Api.feedDislike*`/`Api.dislikeVideo` 以 `HttpString.appBaseUrl` 开头 ⇒ 拦截器走 **app
  分支**：`credentials.headers` 仍注入（含 `x-bili-mid`），但 **不装载 Cookie、不写回响应
  Cookie**；`access_key` + `appkey/ts/sign` 由拦截器在发送前注入 query/body
  （read→transform→send 的真实过点）。
- `Api.tvPlayUrl` 是 web 路径 ⇒ Cookie/headers + 响应 Set-Cookie 写回绑定 owner；
  `access_key` 由 builder 自己注入（拦截器 web 分支不注入 key）。
- ~~本组探测**预期不产生生产修复**：gate 读取的 owner 与拦截器绑定的 owner 在四个 builder
  中同源（同一同步块、无 await 交错）~~ **R48 修正（2026-10-16）**：该假设不成立——Dio
  5.11.1 `fetch()` 把 interceptor 回调包装进 `Future(() async ...)` 链，
  `AccountManager.onRequest` 在后续事件循环 turn 才解析当前槽；builder 同步读 key/sign 与
  绑定之间**存在真实预绑定窗口**（详见
  [P05_R48_PREBINDING_WINDOW_REPAIR_PLAN.md](P05_R48_PREBINDING_WINDOW_REPAIR_PLAN.md)）。
  若受控执行暴露真实不一致，将同组聚焦修复并如实记录（不弱化断言、不改生产 authority）。

## 实现（只增测试）

新增 `test/utils/accounts/account_http_consumer_routing_test.dart`（`git add -f`，因为
`.gitignore` 的 `test*` 规则；历史组同样处理）。复用模式：

- `AccountTestStorage`（真实 Hive + `Accounts.init` + `Request()` 先于 adapter 替换；
  `reset` 期间仍指向 no-op adapter，避免把 clear/activate 副作用打到受控队列）；
- `_ControlledAdapter`（暂停/完成 JSON 响应 + Set-Cookie；参照
  `account_request_lifecycle_test.dart` 与 `native_wbi_key_cache_test.dart`）；
- 生产 `AccountManager()` 注入 `Request.dio.interceptors`，tearDown 移除并恢复 no-op
  adapter（保持下一个 `storage.reset()` 离线）。

本地无 Dart/Flutter SDK（实际 `where dart/flutter` 为空）⇒ 不虚构本地执行；Dart 静态
检查与运行由 CI 的 `dart analyze --fatal-infos ... test/utils/accounts/` 与
`flutter test test/utils/accounts/` 实际承担。

### 回归矩阵（9 项，全部驱动真实生产 Builder）

1. **tvPlayUrl 正向**：video 槽登录 V ⇒ `query.access_key`/`mobile_access_key` == V 的
   access key、`appkey`/`ts`/`sign` 存在、`x-bili-mid`==V、Cookie 含 V SESSDATA、
   `extra['account']`==V；响应（code!=0）写回仅 V，main/recommend 零写；Builder 返回
   `Error` 且 `errMsg`==fixture。
2. **tvPlayUrl in-flight 槽切换**：暂停中 `selectTemporarily(video, C)` ⇒ 绑定保持 V、
   写回仅 V、C 零写（已发送 query 仍为 V 的 key）。
3. **tvPlayUrl same-MID 替换（revoke）**：暂停中 `installCredentials(V2)` ⇒
   `ownsCredentials(V)` false、`isCurrentRequest(oldStamp)` false；响应正常完成但 V/V2
   均零 cookie 写。
4. **tvPlayUrl 无 video 登录（nullable）**：video 槽保持匿名 ⇒ 绑定匿名单例、
   `query` 无 `access_key`/`mobile_access_key`、无 `x-bili-mid`；响应完成；已选中的
   main/recommend owner 零写。
5. **dislikeVideo gate 负例**：main 匿名 ⇒ `Error('请退出账号后重新登录')`、
   `adapter.fetchCount == 0`（零请求、零副作用）。
6. **dislikeVideo 正向**：main 登录 M（`selectTemporarily(main, M)`）⇒ app 分支 POST
   body 注入 `access_key`==M key + `sign`，`x-bili-mid`==M，无 Cookie header；无写回
   （app 语义）。
7. **feedDislike / feedDislikeCancel gate 负例**：recommend 匿名 ⇒ 两者均 `Error`、
   `fetchCount` 保持 0。
8. **feedDislike 正向**：recommend 登录 R（`selectTemporarily(recommend, R)`）⇒ query
   注入 `access_key`==R key + `sign`、`x-bili-mid`==R；响应 `{"code":0}` ⇒ `Success`；
   无 Cookie/写回。
9. **feedDislike in-flight 槽切换**：暂停中 `selectTemporarily(recommend, R2)` ⇒ 响应仍
   `Success`、已发送 query 保持 R key、R2 与任何 owner 零写回（app 无写回语义）。

## 明确不闭合（不得声称）

120 csrf/18 access 全量 tagged 迁移；`live.dart`（8 个 accessKey 站点）/`user.dart`/
`member.dart`/`login.dart`/`video_popup_menu`/`member_profile`/`ios_native_ui_bridge`
其他消费者；gRPC purpose binding；generic purpose CAS read-transform-publish 干扰；
whole writer async closure；B2e-2b bridge/frozen revision；Block3 composition/handoff/
revert/startup/GC；Block4/Block5。行闭合仅限上表 4 个 Builder 的已测试契约。

## 边界与验收

- 只增测试（若暴露真实缺陷则同组最小修复）；不改生产 UI/Aether/`youtube/`；四 flag
  false；不真实网络/账户写/captcha/设备伪造；不弱化任何断言/预算；不重跑已接受的
  R43–R47 或重复 shadow/raw-path 用例。
- 小 commit/push → 新最终代码 SHA 显式 BOTH workflows（各一次）→ 读实际 evidence
  （account 计数只增、293 基线不降、envelope 109/44/…/245/292/51、producer、九 outcome、
  BUILD/FFmpeg、preview 20/11/压力）→ docs-only 证据（与代码 SHA 分列）→ Codex 独立
  复审；不自我验收、不推进 authority/下一组（B2e-2b bridge/Block3 仍依赖先决条件）。
