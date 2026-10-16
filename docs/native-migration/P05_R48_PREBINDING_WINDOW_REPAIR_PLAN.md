# P05 修复计划：R48 预绑定窗口（真实 Dio/VideoHttp 异步绑定边界）

2026-10-16（Asia/Hong_Kong）。依据 TOP handoff 与
`review-08e50b9907e2756846d65be74bbc2830ab14fdcf-codex/REVIEW.md`（R48）及其中引用的
`review-fa8bd8107109e041d5d62edc8c4e2decdf15c5a8-codex/REVIEW.md`（完整来源分析）。
**在实现之前保存**；并修正 `P05_B1G_VIDEO_HTTP_CONSUMER_ROUTING_PLAN.md` 中
"同一同步块 ⇒ 无生产修复预期" 的错误假设。

## 实际事实（已核对，不虚构）

- `08e50b9` 双方首次绿：release 38869373595 SUCCESS5/5、preview 38869376807 SUCCESS4/4；
  实际 302 account（含 9 个已提交 B1g case）/runtime 72/strict clean；native
  109/44/40/245/292/51、producer 8/10/2、90 raw 88+2、current goldens、MacQA45、20 UI、
  11 owned reports、22 streams、`pressure[]`。这些均为**既有 case**的实际证据，
  **不构成**预绑定窗口（R48）的证明或否定；lastaccepteda50 limited PASS/predecessor 均保留。
- R48 来源事实（本 session 亲自拉取 declarative Dio 5.11.1 主源码
  `dio/lib/src/dio_mixin.dart` 复核）：`fetch()` 以
  `Future<dynamic> future = Future<dynamic>(() => InterceptorState(requestOptions));`
  开始链；每个 request interceptor 回调被包装为
  `Future(() async { final handler = RequestInterceptorHandler(); final result = cb(...); ... })`。
  ⇒ `AccountManager.onRequest`（含 `_bindRequestAccount` 的 path→purpose 解析与 stamp）
  在调用方**后续事件循环 turn** 才运行，而非 builder 调用内同步运行。
- `VideoHttp.tvPlayUrl` 在调用内同步读取 video 槽 owner A 的 access key、写入
  `access_key`/`mobile_access_key` 并 `AppSign.appSign(params)`，随后才调用
  `Request().get`。调用方在绑定前窗口内切换 video 槽到 B（或替换/注销 A）时：
  - 现状（未修复）可产生 **A 的 query key/sign + B 的 header/Cookie/stamp** 混合请求，
    或旧 key + replacement 新 owner；`Accounts._installOwner` 会在同 MID 替换时同步把槽
    更新为 replacement（`lib/utils/accounts.dart:299-304`），因此预绑定替换也可落到新
    owner 上发出。
  - B1g 计划的"同一同步块/无 await 交错 ⇒ 无生产修复预期"假设**不成立**，本文件为修正。
- 上述为源码级风险；实际运行判定见下节——settlement run 已完成，候选**条件确认**。

## Settlement run 实际诊断结果（`12738bc`，已执行；条件确认）

2026-10-16。TOP handoff + `review-12738bca2fee38633dea38005f37db7a22ca28ba-codex/REVIEW.md`
（TERMINAL DISPOSITION）实际复核：

- release [38874938999](https://github.com/Justintunsday/Piliglass/actions/runs/38874938999)
  FAILURE（SIGNING/BODY_CODEC/ACCOUNT_NATIVE/COOKIES/ORDERED_COOKIES/COOKIE_MUTATIONS/
  LOGIN/ACCOUNT_ENVELOPE_OUTCOME 8 组 success；ACCOUNT_DART=failure → main 正确 exit1，
  continue-on-error 步骤元数据 success 不代表 pass）；preview
  [38874943713](https://github.com/Justintunsday/Piliglass/actions/runs/38874943713)
  SUCCESS4/4（20 UI 全过；不关闭 account 缺陷）。
- 实际 strict analyze No issues；runtime72 passed；Flutter account suite **实际执行 311 =
  305 passed / 6 FAILED**，六个失败**恰好**为本轮新预绑定 case（非编译错误、非推断）：
  1. TV 无屏障·立即切换：已发送请求的 owner identity ≠ A（helper line130）；
  2. TV barrier·预绑定切换：同样 owner identity 不符（line130）；
  3. TV 预绑定同 MID 替换：要求零 fetch 实际 **fetched=true**（line467）；
  4. feedDislike 预绑定切换：发送 owner ≠ gate owner（line171）；
  5. dislikeVideo 预绑定切换：同上（line171）；
  6. feedDislike 预绑定替换：要求零 fetch 实际 **fetched=true**（line583）。
- 精度：owner 断言位于 query/header/Cookie 断言之前，原始日志只显示泛化 LoginAccount 实例，
  **未观察到**后续全部混合字段（不得宣称 A-query/B-cookie 全字段实测）；两个替换 case 证明
  的是**未授权的 fetch 进入**，不是之后的服务端成功写入。既有 positive、新上下文 B、
  installed-null-key web 与 recommend gate 等 case 通过。
- 该结果为**离线真实 Dio/VideoHttp 生产代码路径**在 CI 的实际执行证据（无真实网络/账户写入），
  条件确认：执行预绑定窗口修复（第 2 段）。历史失败日志/计数保留，不追溯改判。

## 第 1 段：真实 Dart/VideoHttp 预绑定回归（settlement run，诊断轮）

在 `test/utils/accounts/account_http_consumer_routing_test.dart` 增补/强化（保留既有 9 例
及其断言，不弱化、不 relabel）：

1. **N1 无屏障·真实时序**：`final f = VideoHttp.tvPlayUrl(...);` 后**不 await**、同步
   `Accounts.selectTemporarily(video, B)`；契约 = 一致 A（query A key/sign + header/
   Cookie/`extra['account']` 均为 A）**或**取消/零 fetch；出现 A query + B 凭据即失败。
2. **N2 屏障·确定性**：在 AccountManager **之前**插入受控 barrier interceptor
   （`onRequest` 暂停 `handler.next` 直到 release；`entered` 完成即已运行到绑定前）。
   `await barrier.entered` → 切换 video A→B → `release()`；同一契约。
3. **N3 屏障·预绑定替换/注销**：`await barrier.entered` → `await Accounts.installCredentials(
   same-MID replacement)`（revoke A 且槽同步指向 replacement）→ release；契约 = 零 fetch +
   Builder `Error`（绝不允许用 replacement/新 owner 发出旧 key 的请求）。
4. **A1/A2 屏障·app 端**：`feedDislike`（gate 读 recommend A）与 `dislikeVideo`
   （gate 读 main A）→ barrier → 切换对应槽到 B → release；契约 = query/body `access_key`、
   `x-bili-mid`、`extra['account']` 一致 A，或零 fetch；绝不允许 gate A + send B key。
5. **A3 屏障·app 端预绑定替换**：feedDislike gate 通过后同 MID 替换 recommend A →
   契约零 fetch。
6. **P1 新上下文正例**：A→B 切换完成后**新发起**的 `tvPlayUrl` 必须一致使用 B
   （query/header/Cookie/`extra` 全 B，响应写 B、A 零写），证明修复不会冻结旧 owner。
7. **V1 bound-nullable 登录对比（web）**：video 槽 = 已安装登录且 `accessKey == null`
   （其余槽为有效登录）→ query 省略 access_key/mobile_access_key，但仍有一致 login 的
   `x-bili-mid`/Cookie/`extra['account']`，响应只写该 owner；与匿名 case 相对照
   （匿名 ≠ bound(null) 登录）。
8. **V2/V3 判别性 gate 负例（强化既有 5/7）**：`dislikeVideo` 在 main 匿名但 video/
   recommend 均为有效登录时拒绝且零 fetch；feed 两个 builder 在 recommend 匿名但
   main/video 均为有效登录时拒绝且零 fetch（错误 owner 回落无法假通过）。
9. **V4 app bound-null 登录 gate**：recommend = 已安装但 `accessKey == null` 的登录 →
   feed gate 拒绝且零 fetch（bound(null) 不是 gate 通过条件）。

settlement run 只含测试、不含生产修改；预期（源码级候选）新 case 在未修复时失败并给出
实际混合观察；若实际运行全部通过，则保留该实际证据、收窄说明、不做生产修改。

## 第 2 段（条件已确认，执行中）：聚焦生产修复（仅 `lib/http/video.dart` 四个 builder）

一次捕获与凭据读取同源的 owner，并把该 owner 作为当次请求的显式绑定传给既有公开机制
`Options(extra: {'account': owner})`（不 reread 槽、不碰 AccountManager 私有绑定）：

- `tvPlayUrl`：`owner = Accounts.get(AccountType.video)`；`accessKeyOf(owner)`/sign 与
  `Request().get(..., options: Options(extra: {'account': owner}))` 同源；
- `dislikeVideo`：`owner = Accounts.main`；gate 与 `Request().post(..., options:
  Options(contentType: ..., extra: {'account': owner}))` 同源；
- `feedDislike`/`feedDislikeCancel`：`owner = Accounts.get(AccountType.recommend)`；gate 与
  `Request().get(..., options: Options(extra: {'account': owner}))` 同源。

预绑定期间 owner 被 revoke/替换 ⇒ 既有 `captureRequest` 返回 null ⇒ cancel/零 fetch
（N3/A3 契约）；绑定后的合法 A 响应写回、`Request` 错误归一化、fallback、AppSign/Cookie
wire 语义全部保留；既有 9 例与 B1f/R43/R44–R47 已接受组不重开、不改断言。

修复同 commit 的直接回归（不得以共享 interceptor 推断四 builder 全部闭合）：

- `feedDislikeCancel` 直接预绑定切换 + 预绑定替换两行（settlement 中该 builder 只有
  AFTER-binding case）；
- `feedDislikeCancel` 与 `dislikeVideo` 各补一条 installed-null-key login gate 直接对比
  （null-key app 覆盖不再仅限 recommend/feedDislike）；已有 tvPlayUrl web null-key 与
  feedDislike null-key 保留；
- 全部既有断言（含六个诊断失败 case 原样）保留；不弱化、不 relabel。

## 边界（不闭合）

仅 4 个 builder 的预绑定一致性问题；120 csrf/18 access 全量迁移、gRPC purpose binding、
generic purpose CAS、whole writer async closure、B2e-2b bridge/frozen revision、Block3
composition/handoff/revert/startup/GC、Block4/Block5 均未闭合；四 flag false、Flutter/
Dart fallback、Aether 独立、不读/改 `youtube/`、无 UI visual/真实账户写/auth/captcha/
设备伪造。本地无 Dart/Flutter SDK（`where dart/flutter` 为空，不虚构本地运行）；实际运行
证据只来自 CI，标注为实际执行时。

## 验收

- 诊断轮 `12738bc` 已执行（红：六个 case 实际失败，事实与精度见上节）；修复轮新代码 SHA
  显式 BOTH workflows（各一次），读实际 evidence（account 计数与命名 case、strict
  analyze、native/hash/goldens、九 outcome、BUILD/FFmpeg、preview 20/11/压力）→ 最终修复
  后的新代码 SHA 交 Codex 独立复审（含诊断轮实际红证据）；不自我验收、不重跑 unchanged
  `12738bc`/`08e50b9`、不推进 authority/下一组。
