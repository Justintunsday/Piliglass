# P04a：原生 HTTP 与热榜切片

2026-10-04；运行时仍使用 P03 Dart-backed SearchRepository。此阶段不移除 fallback。

P04a 已验证代码 `b0c098abb4ec5d20dcd2edb2a65fee11506f7bbf`：
[完整 release 与 Swift 6 核心检查成功](https://github.com/Justintunsday/Piliglass/actions/runs/37163367936)、
[全部 preview 成功](https://github.com/Justintunsday/Piliglass/actions/runs/37163367691)。
74 项 HTTP fixture 与原有 63 项搜索 fixture 通过。此结论不包括账户/API 实测切换。

## 实施与边界

1. `Networking/HTTP/PiliHTTPClient` 接收 URLRequest，返回不可变 Sendable URL/status/
   headers/body；非 2xx 也返回，账户层应在 API 校验之前处理响应 Cookie。
2. `PiliURLSessionHTTPClient` 使用隔离配置，不读写共享 Cookie、凭据或缓存；调用方
   提供 Cookie/header。仅发送无 URL 内嵌凭据的 HTTPS 请求。取消传递到 URLSession，
   并在 await 前后检查；不提供应用层自动重试。
3. 每个请求的无状态 delegate 拒绝自动重定向。依据 Apple 的
   [redirect delegate](https://developer.apple.com/documentation/foundation/urlsessiontaskdelegate/urlsession(_:task:willperformhttpredirection:newrequest:completionhandler:))
   API，nil 拒绝重定向并返回原响应。此阶段 fixture 直接验证 delegate 决定，未验证
   真实 CFNetwork 重定向；切换前继续保留这项集成验证。
4. Data/Search 的 `PiliNativeSearchTrendingService` 构建固定 HTTPS endpoint
   `/x/v2/search/trending/ranking?limit=10`，注入 Client，不让 View 接触协议。
   此切片支持 limit 1...30，超过范围继续旧实现；不会截断服务端实际结果。
5. 独立 decoder 校验 HTTP 和 API envelope，映射为 Domain `PiliSearchKeyword`。
   保留空词过滤、第一处 `·` 替换、icon 规范化、顺序/重复项；校验 Dart 当前解析但
   UI 未展示的 show_name/show_live_icon。忽略 needsTop=false 的 top_list 和成功的 message。
6. 将实际生产文件注册到 Runner，并新增 Swift 6 strict-concurrency 的 URLProtocol
   fixture job。完整 Runner 与已有 preview 保持阶段门禁。

## 验证与完成限制

Fixture 覆盖请求与 header、数字 code、字段缺失/null/错误类型、HTTP/API/传输错误、
错误响应 Set-Cookie 元数据、共享 Cookie 隔离、并发显式上下文和前置/在途取消。
生产 URLSession Client、Service、Decoder、Domain 直接参与 Swift 6 编译。
本地 Windows 没有 Swift/Xcode，脚本只报告 skip；必须等待真实 Actions 成功。

HTTPURLResponse 的 Foundation header 值原样保留；多条 Set-Cookie 的合并表示尚未
与 Dart Cookie 解析作实测对照。此阶段不宣称 Cookie 完整兼容。10 秒原生超时也不是
Dio 独立 connect/read timeout 的完全替代。代理、HTTP/2 与其他用户 transport 设置
需在 P05 context 的支持判断中处理，未支持时使用现有 Dart。

P05a 完成 recommend-account lease、revision、原账户响应 Cookie 写回/释放，并验证
取消、换号、重复/path Cookie、错误响应与 unsupported-mode fallback 后，才允许 P04b
接入 hybrid discovery。Native trending 成功时不能同时发送 Dart trending。
详见 [SEARCH.md](SEARCH.md) 和审查后的 [REQUEST_CONTEXT.md](REQUEST_CONTEXT.md)。
