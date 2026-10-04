# P05a：请求上下文与 Cookie 切换前置计划

2026-10-04，基于 P04a 的并行只读审查；尚未实施、尚未验证。
本文件记录下一阶段的可执行边界，不代表 Native HTTP 已接入运行时。

## 分阶段实施

1. P05a1：抽出共享 Cookie response parser，验证分离与合并 Set-Cookie、Expires、
   同名/domain/path 与歧义输入；建立账户选择 revision 和凭据 generation 的窄接口。
   不切换 HTTP，不扁平化 CookieJar；需要真实 Dart fixture、Darwin wire fixture 和 CI。
   拆为 P05a1a parser/wire（实施中，详见 COOKIE_HEADERS.md）与 P05a1b revision/generation
   （未实施）；前者 CI 成功后再修改账户生命周期。
2. P05a2：独立 Dart lease service、Swift Domain context protocol 与 Bridge adapter。
   验证 prepare/finish/abandon、原账户写回、刷新/删除/重置、取消/重复完成与释放。
   每个代码阶段分别 commit/push，完整 release+preview CI 成功后才能继续。
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

## Set-Cookie 实测门禁

现有 `account_mgr.dart:20` 的 `(?<=)(,)(?=[^;]+?=)` 会将下面的日期逗号也当作边界：

```text
a=1; Expires=Wed, 09 Jun 2027 10:18:14 GMT, b=2; Path=/
```

分割会产生 `a=1; Expires=Wed`、裸日期片段、`b=2; Path=/`。先抽出共享 parser 与
Dart 回归 fixture，不能简单把 Foundation 合并值包成 List<String> 就宣称兼容。
保留 raw 值和 provenance，不通过 Foundation Cookie 重序列化。仅改为 token= lookahead
也不足以消除所有 Path/extension 中逗号的歧义。
[RFC 6265 §3](https://www.rfc-editor.org/rfc/rfc6265.html#section-3) 说明折叠 Set-Cookie
可能改变语义。Darwin wire fixture 必须验证多条头、顺序、同名/path、Expires，以及取消
时已收到头的处理。对无法恢复的表示需要保留分离响应头的 transport 或明确支持门禁。
在解决之前，现有 Dart HTTP 保持运行时数据供应。

## 有效 transport policy

从 Request 暴露有效配置，而不是只读当前 Pref：`_enableHttp2` 在 `init.dart:31` 固定，
代理/证书策略在 `:136` 建立，重试 interceptor 在 `:229` 配置。还需处理 URLSession 的
系统代理、压缩协商、超时差异。只对已验证的模式启用 native，其他模式保持 Dart。
禁止复用导出的根域 Cookie 字典替代 loadForRequest，或另造匿名 buvid。
