# P05a2b：Swift 请求上下文边界

状态：已验证。最终代码 `4148caf52de9cfefb4af56ed298c21cecb94717f` 的
[完整 ios.yml](https://github.com/Justintunsday/Piliglass/actions/runs/37195363892) 与
[全部 ios-home-preview.yml](https://github.com/Justintunsday/Piliglass/actions/runs/37195365890) 同 SHA 成功。
本阶段继续 PLAN.md；视觉 UI 重写留到原生化主线完成后。
后续 Policy-2 已在 7192a0c 完整验证：context 增加 Networking 的不可变 policy，
严格 codec 要求嵌套版本/类型/一致性，真实 Dart bridge goldens 经生产 provider 验证。
当前协议见 P05_POLICY_LEASE_PLAN.md；以下生命周期合同继续保留，runtime 仍关闭。

## 可回滚范围

| 责任 | 生产实现 | 当前替代范围 |
|---|---|---|
| Domain | `Native/Domain/Accounts/PiliHTTPRequestContext.swift` | Sendable 请求描述、用途、Cookie 来源、receipt/error 和 provider protocol |
| Data | `Native/Data/Accounts/PiliFlutterHTTPRequestContextProvider.swift` | 临时转发 Dart lease；最多 32 个 pending/prepared/ending records |
| Data codec | `Native/Data/Accounts/PiliHTTPRequestContextBridgeCodec.swift` | 校验复制后的 BridgeValue，拒绝宽松类型转换 |
| Bridge | `Native/Bridge/PiliBridgeLeaseFinalizer.swift` | 一次性 terminal dispatch、独立任务、回包超时 |

四个文件注册 Runner。没有创建 URLRequest、替换 HTTP Client、接入 Search/Root，
也没有修改 Flutter runtime、播放器内核、UI 或资源。`executionAllowed` 始终 false。
账户对象、CookieJar 和 Hive 所有权继续位于 P05a2a Dart adapter，Swift 仅持有值描述
和不透明 token；不能据此宣称账户实现或搜索请求已原生化。

## 生命周期与错误契约

prepare 在发送前生成本地 UUID，复用现有可取消 invoker。独立 operation 由调用方取消
或显式 dispose 取消。坏快照、传输错误与取消统一用本地 requestID 发送独立 abandon；
即使 prepare callback 已被 invoker 丢弃、leaseID 未返回，也能清理对应 Dart pending。
迟到或重复 callback 不安装 context、不发送第二次清理。

finish/abandon 在第一次 await 前同步 claim，然后启动不继承调用方取消状态的终结任务。
终结器直接调用 transport 的 callback，不修改 Search invoker；MainActor acknowledgement
box 只恢复一次 continuation。默认 5 秒回包超时只结束 Swift 等待，不能撤销 Dart 写入。
回包丢失、损坏、迟到或服务错误之后不再次 finish/abandon、不重发 HTTP、不自动 fallback。
仅本地 finish preflight 失败可以改为单次 abandon，因为尚未发送 finish。

dispose 同步关闭 provider、移除 registry 并取消 pending prepare，给尚未终结的 records
发 abandon；已发出的 finish 保持独立等待。registry 不重复保存 headers/Cookie 描述。
调用方一直不终结 context 会占用最多 32 个有界 slot；Dart TTL 不会自动清除 Swift map。
prepare 没有自动 Swift 超时，运行时接入前必须验证调用方取消与显式 dispose 的生命周期。

服务返回 invalidArguments/leaseMismatch/notPrepared 等 preclaim 错误时，Swift 仍保持
本地终结门禁关闭；未消费的 Dart lease 可能依靠 TTL 释放。未知回包不能被当作「未写入」
证据；persistenceFailed 也不能证明 CookieJar 未发生 mutation。正常 receipt 可报告
revoked 且已有部分 Cookie 写入，保留这种结果。

## Codec 门禁

prepare reply 须完整匹配字段集合：规范 UUID、固定 HTTPS trending endpoint/limit 1…30、
GET、非负 Int64 revision、正 Int64 generation、String headers、严格 false Bool gate。
header name 采用 HTTP token，拒绝重名大小写变体、Host、Content-Length 与 CR/LF。
Cookie 字符串保留原顺序/重复名称；响应保留原始 Set-Cookie 值、顺序与 provenance，
不通过 Foundation Cookie 重序列化。非 2xx status 也发送 Cookie metadata。

正常 receipt 和服务 error 分开；不接受 Double/Bool/String 代替整数。现有
PiliBridgeValue 原始 NSDictionary copier 会兼容忽略非 String key，本阶段不改变该
Search 兼容行为。因此严格性只覆盖复制后的 String-key snapshot，而非整个原始 wire。

## 验证与下一阶段

`tool/check_native_request_context.py` 在 macOS 以 Swift 6 complete concurrency 编译
实际四个生产文件及现有 BridgeValue/Invoker，运行 FakeTransport fixture。覆盖严格字段、
跨 task 值所有权、同步/后台/重复 callback、prepare 取消竞争、取消后的真实终结发送、
finish/abandon 竞争、坏 preflight、未知/错误回包、真实超时、容量和 dispose。
新增 ios.yml `native-request-context-core` job 上传 compile.log/result.log/summary.json。
Windows skip 与静态审查仅为提交前检查，不是完成证据。

实际 artifact 确认 119 项 context 检查通过，Swift 6 complete 编译无本阶段警告。
初始 63dac5f 的 fixture 捕获警告以 4148caf 修正，旧 workflow 已被最终 SHA 替代，
不作为阶段完成证据。最终 Runner release、已有 HTTP/Search/Cookie/account、新 context
core 和全部 preview jobs 同 SHA 成功，完整证据记录到 PROGRESS.md。
下一阶段 P05a2c 单独处理响应头时序、取消写回与有效 transport policy，继续保留
COOKIE_HEADERS.md 的 Foundation 字段歧义门禁；不会因 context 验证成功提前切换请求。
