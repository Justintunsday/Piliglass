# P05a：请求上下文与 Cookie 切换前置计划

2026-10-04，P05a1a parser/wire、P05a1b 账户 generation 与 P05a2a Dart lease 已通过真实 CI（最终 c0fbdbf）。
本文件记录下一阶段的可执行边界，不代表 Native HTTP 已接入运行时。

## 分阶段实施

1. P05a1：抽出共享 Cookie response parser，验证分离与合并 Set-Cookie、Expires、
   同名/domain/path 与歧义输入；建立账户选择 revision 和凭据 generation 的窄接口。
   不切换 HTTP，不扁平化 CookieJar；需要真实 Dart fixture、Darwin wire fixture 和 CI。
   拆为 P05a1a parser/wire（已验证 834c3b9，详见 COOKIE_HEADERS.md）与 P05a1b revision/generation
   （已验证 15a7f9d，详见 ACCOUNT_REQUEST_STATE.md）；前者 CI 成功后再修改账户生命周期。
2. P05a2：独立 Dart lease service、Swift Domain context protocol 与 Bridge adapter。
   验证 prepare/finish/abandon、原账户写回、刷新/删除/重置、取消/重复完成与释放。
   每个代码阶段分别 commit/push，完整 release+preview CI 成功后才能继续。
   P05a2a 的实现与保留限制见 [REQUEST_LEASE.md](REQUEST_LEASE.md)，已通过 c0fbdbf 同 SHA CI。
3. P04b：完成有效 transport policy 与响应头/取消语义验证后接入 hybrid discovery。
   移除重复 Dart trending 调用；其余网络与 Hive 仍走 Dart。未支持的模式先判断再使用
   Dart，不将取消当作需要 fallback 的错误。

## 最小 lease 契约

- prepare：只允许 trending endpoint 和已支持 limit。绑定准备时实际 recommend Account，
  使用当前有效 Dio base/account headers、referer、CookieJar.loadForRequest(uri)、
  AccountManager.getCookies 的 path 排序与重复名称语义。Cookie load 前后校验 revision。
  返回不可变请求快照、revision 与不透明 lease ID；Account 对象只保留在 Dart 服务内。
- finish：与 abandon 共用一次性 terminal 门禁，响应 origin/path/query 必须匹配 lease。
  HTTP/API 校验之前，将响应 Cookie 写回有效的原账户，包含非 2xx；释放在 finally 中。
  普通换号 A→B 应继续写回有效 A。凭据替换、删除或匿名 reset 必须拒绝旧 generation
  持久化，不能借 LoginAccount.==（只比较 MID）判断对象身份。使用 identity-based registry。
- abandon：消费 lease，不保存 Cookie。prepare 后取消/异常也必须释放；设置有限生命周期
  作为意外断连的补充，不能用它替代正常 finish/abandon。重复完成不重复写入。
- response/cancel：已经收到的响应头需要完成 Cookie 处理后再丢弃业务结果。P04a 的
  data(for:) Client 在 body 完成后返回元数据，await 后取消会丢弃 response；不足以证明
  “收到头后取消”语义。P05 必须扩展响应头生命周期并测试在 body 未完成时取消的情况。

## 必须覆盖的变更点

| 代码位置（审查时） | 必须观测的变化 |
|---|---|
| `lib/utils/accounts.dart:36` refresh | Hive 替换对象，包括同 MID 的新凭据 |
| `accounts.dart:49` clear、`:58` deleteAll | 在异步清理前撤销旧 generation；匿名 singleton 重置 |
| `accounts.dart:71` set | mode/type 变化与 A→B→A |
| `lib/pages/login/controller.dart:627` | 持久化新凭据、匿名 reset、`:630` 直接替换 mode |
| `login/controller.dart:172`、`lib/pages/about/view.dart:250` | Cookie 登录与导入替换存储 |
| `lib/pages/mine/controller.dart:229` | 绕过 set 的 heartbeat slot 写入；全局 revision 不能漏掉 |
| `lib/utils/accounts/account.dart:83`、`:158` | LoginAccount.delete 与匿名 delete/reset |
| `account.dart:198` | 缺失 buvid 时的 jar mutation |
| `account_manager/account_mgr.dart:201` | 正常/错误/redirect 响应 Cookie 更新 |
| `lib/services/ios_native_ui_bridge.dart:2257` | Native QR 登录的匿名 reset |

选择 revision 与凭据 generation 分开：普通 Cookie 更新使准备中的快照失效，不能因此
压掉其他有效在途响应。`LoginAccount.onChange()` 按 MID 写回自身，同 MID 刷新后旧对象
可能覆盖新凭据；`_hasDelete` 只保护显式 delete。匿名 reset 复用 singleton，仅检查对象
identity 也不够。凭据替换必须显式撤销 generation 并检查存储所有权。
这些保护必须同时覆盖现有 Dart `_saveCookies`/`LoginAccount.onChange`，不能只用于
Native finish，否则旧的在途 Dio 响应仍能绕过 lease 恢复过期凭据。

## P05a1b 已审查的实施边界（已验证 15a7f9d）

建立不导入 Flutter/Account 的泛型 identity tracker，再由账户层提供显式安装凭据、
导入、持久选择、临时选择、capture/isCurrent/revoke 的窄接口。generation 和 revision
仅在内存维护，不改 Hive schema；stamp 必须绑定原对象与凭据代次，不能按 MID 相等
判断。普通换号、用途变化和有效 Cookie 更新仅提高 snapshot revision；凭据替换、
删除、clear 与匿名 reset 才撤销 generation。响应完成只检查 generation 与存储所有权，
不能用全局 revision 压掉其他有效在途响应。

补充入口与回归点：

- init/refresh 注册全部 Hive 账户，包括未选中的对象；refresh 按 identity 对账并重建
  mode，不能让新对象的空 type 使旧 slot 一直留存。重复扫描同一有效对象不撤销代次。
- 同 MID 的旧对象 `onChange` 不得覆盖新对象，旧 `delete` 也不得按 MID 删除新对象。
  更新需要是当前 Hive owner；新凭据通过显式 install，不能借 onChange 复活陈旧对象。
- `deleteAll` 不用 `Set.contains` 的 MID equality 匹配 slots；延迟 userInfo 失败清理
  可能持有旧对象。clear 在第一次 await 前撤销全部已注册账户与匿名代次。
- 普通重新登录先继承旧账户的持久化 type，再安装新凭据并替换当前 identity slots，
  保留 Mine 的临时无痕覆盖；导入则使用输入 type，校验 key/MID 对应关系。
- Native QR 登录先显式安装新凭据，再设置各用途；Mine 临时无痕通过不落库的选择接口
  提高 revision，不能改成持久化 set 而改变原功能语义。
- 匿名 singleton reset 期间保持 generation 无效；jar、buvid、gRPC session header
  更新完成后才启用新代次，处理重复 reset 与 activated 标志。只比较 identity 不够。
- Dio 首次 onRequest 同步绑定 account 和 stamp；retry/redirect 复用 RequestOptions
  时保留首次 stamp，不为已撤销请求重新捕获新代次。正常/403/redirect 写回在每次实际
  jar 调用之前、每个 await 之后及持久化之前均检查，缺少 stamp 不推断有效凭据。

锁定依赖是 CookieJar 4.0.9、Hive CE 2.20.0、Dio 5.11.1。只读审查发现当前
DefaultCookieJar save/delete 的 async body 内无 await；Hive put 先同步更新内存事务
再等待 backend。检查需紧挨实际 mutation，不能依赖“Future 会推迟 mutation”的假设。
匿名补 buvid 的 whenComplete 仍有异步间隙，须保持新代次未启用。

验证计划：纯 Dart tracker fixture 覆盖同 MID 不同 identity、A→B→A、并发正常响应、
撤销/重装和匿名同对象代次轮换；Flutter 测试使用真实 Hive adapters 与可控 Dio adapter，
验证原账户写回、正常/403/redirect、替换/未选中账户 clear/删除/reset、陈旧 onChange/delete
及用途持久化。首次创建匿名对象/AccountManager 前初始化 setting/localCache，避免导入链
访问未初始化 Pref；recommend slot 与预置 activated 避免不相关 UI 登录副作用。
修正 deleted_account_test 中 saveFromResponse 未 await 的路径。

CI 在 Flutter setup 与 iOS patch 完成后运行纯 Dart fixture，以及
`flutter test --no-pub --reporter expanded test/utils/accounts/` 和定向 analyze；增加测试
触发路径。继续以完整 release、FFmpeg load order 与全部 preview 同 SHA 成功作为阶段门禁。
实现、实际 CI 与限制见 ACCOUNT_REQUEST_STATE.md。

## P05a2 的执行切片（修改前保存）

P05a2a 先实现独立 Dart lease service、严格 command codec，以及 bridge 的三条薄路由：
prepareNativeHTTPRequest / finishNativeHTTPRequest / abandonNativeHTTPRequest。
不修改 Search runtime、URLSession、Hive schema 或网络设置，executionAllowed 固定 false。
新代码落在 `lib/services/native_http/`，不把请求/Cookie 业务继续堆进 UI bridge。

prepare 只允许 searchTrending、整数 limit 1...30；客户端发送前生成单次使用 requestID。
第一次 await 前同步登记 pending，绑定实际 recommend account；先 capture stamp 再读取
revision，复制实际 Dio base/account headers 与 referer，按真实 URI loadForRequest。
await 后同时验证 registry record identity、推荐选择、revision、generation 与 owner；
使用现有 getCookies 的 path/重复名称语义，返回不可变描述与 opaque leaseID。

finish/abandon 在第一次 await 前共用一次性 terminal claim。响应 URL 的 origin/path/query
须匹配；有效原账户 A 的响应不受普通 A→B 选择影响，同 MID 替换/delete/clear/reset 则
拒绝旧 generation。完整解析 Cookie batch，Foundation 歧义零写入；非 2xx 也先处理 Cookie。
每次实际 jar mutation 前、await 后和 Hive 更新前检查 owner，finally 释放，不恢复 lease。
abandon 可取消 preparing/prepared，晚 load completion 不得重新安装；unknown ID 留下
有限、无账户引用的 tombstone。单调 TTL 与数量上限只清理未消费 lease，不能重开已开始
finish 的 gate；dispose 同步关闭并释放。有限 tombstone 不提供无限期重放防护。

真实 Hive/Dio fixtures 覆盖推荐/主账户隔离、Cookie path/重复名/headers、prepare await 中
变化、pending 取消、终结竞争/重复、TTL/容量/dispose、原账户写回、撤销与整批坏 Cookie。
定向 analyze 与整个 accounts test 进入现有 pipefail CI；完整 release+全部 preview 同 SHA
成功后才能进入 P05a2b。P05a2b 再实现 Swift Sendable context/adapter 与独立取消 cleanup，
避免现有 invoker 丢弃 late prepare 回调导致 lease 泄漏。P05a2c 单独处理实际响应头生命周期
和有效 transport policy；Foundation 字段边界与取消写回仍是 P04b runtime 切换门禁。

P05a2b 只读设计已收敛，须等待 P05a2a 最终 SHA 全绿后实施：
Domain/Accounts 的 Sendable context/provenance/receipt/protocol；Data/Accounts 的
MainActor Flutter adapter 与 strict BridgeValue codec；Bridge 的独立 terminal finalizer。
四个文件注册 Runner，单独 Swift 6 complete concurrency fixture job 验证生产类型。
prepare 复用现有 cancellable invoker，以本地 requestID 处理错误、缺损/迟到 callback，
不改 Search invoker 语义。cleanup 使用独立未取消 Task；finish/abandon 在 await 前 claim，
即使调用方已取消也须实际发送终结。ack timeout 只结束 Swift 等待，不撤销 Dart mutation；
未知 ack 不重发 HTTP、不再次 finish。codec 严格校验整数/布尔、UUID、固定 URL/headers
和 false gate，不使用 UI/Search 的宽松 coercion。fixture 覆盖取消竞争/late callback/
重复终结/timeout；仍不创建 URLRequest、不接 production runtime，Aether/UI 不依赖此协议。

P05a2b 的持有范围与错误语义：registry/终结器只保留 token、operation 与 transport，不重复保留
Cookie/headers 快照；Domain context 为值类型，调用方持有的副本不等于账户对象。
严格 codec 不接受 double/bool/string 代替整数，也不把非 bool 的 gate 强制转换；固定
endpoint/query/GET、UUID、header token/CRLF 及完整字段 shape 必须验证。错误响应与
正常 receipt 分开，persistenceFailed 不提供「未写入」保证。prepare 的全部失败路径
以本地 requestID 发独立 abandon；单次 finish 已发出后未知 ack 不能触发第二次 finish、
HTTP 重发或自动 fallback。terminal 先同步 claim 再启动未取消任务，ack timeout 只
结束等待并释放 Swift continuation，不声明 Dart 已停止。Swift fixture 实际证明这些
竞争与发送次数；Windows skip 不能当完成证据。

已有 `PiliBridgeValue(codecValue:)` 对原始 NSDictionary 的非 String key 采用兼容忽略，
P05a2b 不改变 Search 的 copier。新 strict codec 验证的是复制后的 String-key snapshot，
不能把这一层的严格字段验证描述为原始 wire 全 key 验证。若需要改变原始捕获策略，
须另有 opt-in 边界与独立兼容测试。

实施 API 收敛：Data provider 注入现有 `PiliBridgeMethodTransport`，prepare 内部使用原
Invoker 和可取消的独立 operation；terminal finalizer 直接使用同一 transport 的 callback，
用 MainActor one-shot acknowledgement box + 独立 timeout task，不用 TaskGroup 等待一个
可能不合作的 injected invoker。Bridge 层只收发 method/BridgeValue，不依赖 Data codec。
provider 最多 32 个 pending/prepared/ending records，只保留 token/operation/finalizer，
不保存 headers 副本；显式 dispose 取消 prepare 并释放未终结 context。调用方从不终结
会占用有界容量，Dart TTL 不会自动清 Swift registry；运行时接入前须满足生命周期门禁。
本地 preflight 失败只 abandon。有效 finish 一旦发送，即使服务器回 invalidArguments /
leaseMismatch / notPrepared，也保持本地门禁关闭，不自动发送第二次终结；该已知
preclaim 拒绝的 Dart lease 可能依靠有限 TTL 释放，这与正常立即释放明确区分。

2026-10-04 用户确认先继续 PLAN.md 原生化主线，UI 重写最后实施。上述 P05a2b 计划
保持下一阶段；UI 的原生玻璃风格与独立方案保存但暂不编码。四个 Swift 文件与专属
Swift 6 fixture 已实现、尚待真实 CI，范围与限制见 [REQUEST_CONTEXT_SWIFT.md](REQUEST_CONTEXT_SWIFT.md)。

## Set-Cookie 实测门禁

P05a1a 之前 `account_mgr.dart:20` 的 `(?<=)(,)(?=[^;]+?=)` 会将下面的日期逗号也当作边界：

```text
a=1; Expires=Wed, 09 Jun 2027 10:18:14 GMT, b=2; Path=/
```

分割会产生 `a=1; Expires=Wed`、裸日期片段、`b=2; Path=/`。P05a1a 已用共享 parser 与
Dart 回归 fixture 修复，但不能简单把 Foundation 合并值包成 List<String> 就宣称兼容。
保留 raw 值和 provenance，不通过 Foundation Cookie 重序列化。仅改为 token= lookahead
也不足以消除所有 Path/extension 中逗号的歧义。
[RFC 6265 §3](https://www.rfc-editor.org/rfc/rfc6265.html#section-3) 说明折叠 Set-Cookie
可能改变语义。Darwin wire fixture 必须验证多条头、顺序、同名/path、Expires，以及取消
时已收到头的处理。对无法恢复的表示需要保留分离响应头的 transport 或明确支持门禁。
在解决之前，现有 Dart HTTP 保持运行时数据供应。

## 有效 transport policy

响应头生命周期的后续实施仍须单独通过门禁。Apple 的
[URLSessionDataDelegate 响应回调](https://developer.apple.com/documentation/foundation/urlsessiondatadelegate/urlsession(_:datatask:didreceive:completionhandler:))
提供响应头到达时的处理点；当前生产 Client 使用 data(for:) 只交付最终 body/response，
不能用最终返回的 response 替代这个时序验证。响应头可提前捕获也不恢复已被 Foundation
丢失的 Set-Cookie 字段边界；两项限制分别验证。实际 wire evidence 仍以 COOKIE_HEADERS.md
为准，类型容器的 ordered list 能力不等于 transport 已保留 wire 顺序。

从 Request 暴露有效配置，而不是只读当前 Pref：`_enableHttp2` 在 `init.dart:31` 固定，
代理/证书策略在 `:136` 建立，重试 interceptor 在 `:229` 配置。还需处理 URLSession 的
系统代理、压缩协商、超时差异。只对已验证的模式启用 native，其他模式保持 Dart。
禁止复用导出的根域 Cookie 字典替代 loadForRequest，或另造匿名 buvid。
