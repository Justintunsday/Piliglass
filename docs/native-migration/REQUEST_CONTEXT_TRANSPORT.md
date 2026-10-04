# P05a2c：响应头生命周期与后续运行时门禁

2026-10-05；实施前计划已随 6cf96e9 保存。P05a2b 最终代码 4148caf 已完整 CI 验证；
c1 最终代码 d80c92b 已在 release 与全部 preview 同 SHA 验证，实际证据见 PROGRESS.md。
继续 PLAN.md 原生化主线，UI 重写最后执行；不提前移除 Flutter fallback。

## c1：传输生命周期和薄终结协调器

同一可回滚阶段交付实际 transfer 与 lease 协调，避免只增加未验证接口：

| 文件 / 层 | 责任 | 验证 |
|---|---|---|
| `Networking/HTTP/PiliHTTPClient.swift` | Sendable response head/result；保留有 head 的成功、取消与失败 | 类型/元数据/错误 fixtures |
| 新 `Networking/HTTP/PiliURLSessionHTTPTransfer.swift` | 共享 Session 上每次传输独立 delegate/task、body buffer、一次性 continuation | 生产 primitive 的真实回环和 URLProtocol |
| `Networking/HTTP/PiliURLSessionHTTPClient.swift` | 调用 delegate-based dataTask，保留 HTTPS/隔离/redirect 拒绝 | 现有 74 项 HTTP 检查及新增时序检查 |
| 新 `Data/Accounts/PiliHTTPRequestHeaderFinalizer.swift` | 只根据最终 head/result 调用现有 provider 的一次 finish 或 abandon | 实际 Swift adapter/codec + FakeTransport |

预计约 300–450 行生产代码；不把账户对象、网络请求或全局状态放入协调器。
Search composition、Root、Dart lease 和 Aether 不改，`executionAllowed=false`。
普通调用仍通过 Client/Service；async API 外观与底层 delegate 生命周期分开。

取消只请求 URLSessionTask.cancel()，不能立即选 abandon。响应头捕获和完成判定须
通过同一受保护状态排序，不依赖不同 actor-hop Task 的调度顺序。完成时没有 head
才 abandon；已有有效 head 则 finish，即使正文随后取消/断连/超时。先处理 Cookie，
再判断 HTTP/API/JSON 结果。终结回包超时或未知错误不重发、不二次 abandon。
本地 URL/元数据 preflight 不成立时只 abandon，并明确报告错误。

302 redirect callback 已有原响应头，应先保留再拒绝转发；后续 response callback
不得重复终结。保持 Client 的共享 Session/连接池；plain dataTask(with:) 在 resume 前
设置 per-task DataDelegate，以 stateless session delegate 作为 fallback。结束时清除
transfer→task/continuation/buffer 持有关系；Client 销毁时 invalidate shared Session。
不得在单次完成时取消其他并发传输，也不依赖 resume 后重设 task.delegate。
[Apple response callback](https://developer.apple.com/documentation/foundation/urlsessiondatadelegate/urlsession(_:datatask:didreceive:completionhandler:))
提供响应头时点；[session initializer](https://developer.apple.com/documentation/foundation/urlsession/init(configuration:delegate:delegatequeue:))
说明串行 delegate queue 与 session 持有 delegate。
[task.delegate](https://developer.apple.com/documentation/foundation/urlsessiontask/delegate)
可设置 task-specific delegate，但文档未逐一保证 response/data selector routing，先用
真实 Darwin wire 检查此方案；若失败须修实现并重跑，不能用协议继承关系替代证据。

head 保留实际 URL/status/headers，以及 Set-Cookie 的原值和来源，始终标记
foundationCombined；数组不能升级为 separatedFields。未知 Set-Cookie 类型明确失败。
本阶段不声称恢复 Foundation 已丢失的字段边界。
实际 CI 发现 URLSession 会复制/正规化测试用 HTTPURLResponse subclass；未知类型、
数组和大小写重复键改为直接验证同一生产 head factory，报告明确标记该 synthetic
来源。12 个 loopback 场景和正常 HTTPS URLProtocol 仍使用真实 transfer/delegate，
不能把 factory probe 当成这些类型真实经过 URLSession 的证据。

API 已锁定为 response head、Cookie representation、typed body result；transfer 返回
Outcome，即使取消也不抛掉已捕获 head。transportErrorCode 仅从实际 completion 的
NSURLErrorDomain 读取，不能从取消标记推导 -999。旧 send API 薄包装该结果，保持
body-only 调用方的 throws/cancellation 契约。Data HeaderFinalizer 仅在无 head 或
unsupported Cookie 表示时 abandon；有有效 head 就 finish，不在错误 ack 后重试。

## c1 可证伪检查与提交门禁

- 用生产 transfer primitive 跑 IPv4 loopback：headers+1024/4096 body prefix，头后取消，
  要求 head 保留、实际 -999、单次完成和未完成 body；不添加生产 HTTP 放行开关/ATS 例外。
- redirect callback 中取消：保留原 302 元数据、服务端没有 redirect-target 请求。
- HTTPS URLProtocol + 真实 Swift provider：头后取消只有一次 finish，头前取消只有
  abandon；等待 ack 中取消仍完成，迟到/重复 callback 不恢复门禁。
- 单 Cookie 支持例与 Path/Expires 歧义例；把真实 wire 值交给 Hive/Dart lease fixture，
  验证原账户写回、一次性消费与 Foundation 歧义零写入。
- 使用真实 suspended dataTask 的可控创建窗口，分别取消 primitive/调用 Task，验证
  安装前零发送、Session tasks 清空与 delegate 释放。安装后的 resume/cancel 竞争只承诺
  最终取消，不能声称物理零发送；makeTask 保持默认真实 Foundation factory。
- 检查 diff、commit、push；新 Swift 6 complete fixtures、已有 HTTP/Search/context/
  Cookie/account、完整 Runner release 和全部 preview 同 SHA 成功后进入下一阶段。

新 transfer Swift 6/loopback 工具在完整 Runner job 的 accounts test 前执行，上传独立
artifact；Hive test 直接消费同 job 的真实 wire report，缺报告须失败。不通过跨 job
自行拼造预期字段，不删除或放宽旧 HTTP/Cookie/account/preview 检查。
新增 Hive fixture 将真实原始字段映射到 lease 已授权的 API URL；实际 loopback URL/status
由 Swift 单独验证。这证明 parser/原 Hive owner 写回，不声称 loopback URL 获得 API
权限，也不声称旧 Hive adapter 丢失的 domain/path 属性已经具备重启持久化能力。

## 后续：有效 policy 与字段保存 transport

有效 policy 的具体执行与对照矩阵已保存为
[P05_EFFECTIVE_HTTP_POLICY_PLAN.md](P05_EFFECTIVE_HTTP_POLICY_PLAN.md)。

有效 policy 单独迁移。`init.dart` 的 HTTP2 值在启动时固定，proxy/证书在 pool 建立时
确定且可能随 connectivity 重建，retry 在 interceptor 创建时固定；只读当前 Pref 不够。
原实现默认 retry=2、br/gzip 和手动解压；Dio receive-idle 与 Native resource 总超时
不能视为等价。[Apple request timeout](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/timeoutintervalforrequest)
用于区分后续配置验证，未支持的模式须在发送前选择 Dart。

当前 COOKIE_HEADERS.md 已证明不同 wire 输入会得到相同 Foundation 值，c1/AsyncBytes/
HTTPTypes 都不能恢复丢失信息。下一步优先独立验证 AsyncHTTPClient/SwiftNIO 的有序字段
transport，暂不增加依赖。AHC 1.36.1 [manifest](https://github.com/swift-server/async-http-client/blob/1.36.1/Package.swift)
有 iOS condition 和 Swift 6.2 tools，这是候选支持意图，尚非本仓 iOS16 编译证据。
NIO [HTTPHeaders](https://github.com/apple/swift-nio/blob/main/Sources/NIOHTTP1/HTTPTypes.swift)
提供字段数组，但还需实际 HTTP1/HTTP2 重复字段/顺序/TLS/取消检查；AHC 的取消和 head
backpressure 不能代替本项目一次性终结门禁。其 gzip/deflate 解压与 Dart Brotli 存在差距，
压缩、代理、证书、超时、iOS 链接及依赖体积均须验证。NW HTTP1 自建 parser 暂作备选。

顺序：c1 生命周期 → 有效 policy → 有序字段 transport 编译/wire 门禁 → Native trending
composition。已发送请求不得再次请求来掩盖 Cookie 表示错误；账户/API 对照验证后才允许
运行时切换。完整原生数据供应是目标，接口和 fixture 成功不等于该目标已经完成。
