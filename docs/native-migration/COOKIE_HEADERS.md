# P05a1a：Cookie 响应表示与共享解析

2026-10-04，实施中，等待真实 CI。HTTP runtime 仍由 Dart 供应。
本阶段先完成 P05a1 的 parser/wire 切片，账户 revision/generation 单独进入 P05a1b。

## 可回滚范围

- 抽出纯 Dart `response_cookie_headers.dart`，只负责响应头表示与 SDK Cookie 解析。
  AccountManager 改为调用共享 helper；原账户绑定、正常/错误/redirect 写回与 Hive
  持久化流程保留。先解码整个 batch，错误时不返回半份 Cookie，不跳过损坏记录。
- explicit source：separatedFields 每条 wire field 不拆分；dioLegacyPossiblyFolded
  保留已有合并兼容并报告恢复；foundationCombined 只提供检查结果和严格支持门禁。
  字符串数组的形状不能证明分离字段或顺序被保留。
- 用即时 ASCII cookie-name token + 可选空白 + `=` 判断逗号边界，不跨越日期内容
  搜索后续等号。保留原始字段、source、输入顺序、segment offset 与诊断；不按名称
  去重/排序，不通过 Cookie.toString 重序列化。Cookie 语义仍由 pinned Dart SDK 决定。
- 合并表示中，任何 attribute span 内的候选边界都标记 ambiguous。原生持久化 getter
  拒绝此表示及未证明的 Dio 来源。Path/extension 的引号是字面值，不能当成 JSON 引号。
  该门禁仅判断表示，不证明登录、账户所有权或实际 transport 的完整兼容。
- fixture-only Darwin HTTP/1.1 回环观察重复 Set-Cookie、作用域/替换顺序、Expires、
  403、歧义碰撞、实际重定向拒绝，以及收到响应头后 body 未完成时的取消。
  pair-only 多字段明确要求 Native gate 开放，并验证真实 CookieJar 的 last-write。
  生产 HTTPS/TLS、Runner Info.plist 与播放器均不改。

## 阶段验证

真实 CI 在同一个完整 iOS job 中运行 Darwin wire observer，再把实际 Foundation 输出
交给共享 Dart parser 的 fixture。SDK fixtures 还覆盖作用域、同 identity 的 last-write、
实际 CookieJar、输入 snapshot、quoted/malformed fields、完整日期、Native 门禁。
共享 helper 和 fixture 通过 Dart analyze；Swift observer 采用 Swift 6 complete checking。
继续运行 P03/P04a 核心检查、完整 release、FFmpeg load order 和全部 preview。
本地 Windows 无 Dart/Swift/Xcode，不能作为通过依据。

首轮 `dc8bbbb` 的 Swift 6 编译通过，但 wire observer 在零 body 的 pending case 中
没有收到 response 回调，尚未通过。读取实际产物后将回环服务器改为头与 1024 字节
prefix 同时发送，继续保持 4096 字节 body 未完成；回调捕获头后取消并拒绝 body delivery。此次调整
只修正 fixture 的触发条件；不放宽生产取消要求，也不改变生产 Client。

## 运行时切换限制

Darwin 表示观察成功不等于 Cookie 兼容：如果两种 wire 输入产生同一个 Foundation 值，
parser 无法恢复它们的真实字段边界。报告保留这种证据，Native gate 继续关闭。
当前生产 Client 仍在 body 完成后返回元数据，尚未实现收到头后取消时的 Cookie 写回；
回环 observer 单独验证需要的生命周期，不宣称替它完成生产实现。
macOS/HTTP1 观察也不替代 iOS/HTTP2 验证。后续账户 generation 与 context lease 门禁
详见 [REQUEST_CONTEXT.md](REQUEST_CONTEXT.md)。

规则依据：[RFC 6265 §§3/4.1.1](https://www.rfc-editor.org/rfc/rfc6265.html#section-4.1.1)
和 [Dart 3.13 SDK Cookie parser](https://github.com/dart-lang/sdk/blob/3.13.0/sdk/lib/_http/http_headers.dart)。
不在此阶段改写整个 CookieJar 或清除 Flutter/Dart fallback。
