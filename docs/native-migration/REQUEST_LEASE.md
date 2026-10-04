# P05a2a：Dart 请求上下文 lease

2026-10-04，实施中，等待真实 CI。修改前计划见 REQUEST_CONTEXT.md。
Native HTTP runtime 关闭；Swift adapter、响应头生命周期与 transport policy 尚未实施。

## 边界与协议

独立 `lib/services/native_http/` 承担准备/写回/释放及严格参数解析。
`ios_native_ui_bridge.dart` 只分发三个命令并在 dispose 时清理；无网络业务进入 SwiftUI。
这是临时 Dart account adapter 的前置边界，不代表账户/登录/Hive 已原生化。

| 命令 | 必需参数 | 行为 |
|---|---|---|
| prepareNativeHTTPRequest | requestID、purpose=searchTrending、整数 limit 1...30 | 绑定实际 recommend account，准备不可变请求描述 |
| finishNativeHTTPRequest | requestID、leaseID、response | 一次性处理响应 Cookie，释放 lease |
| abandonNativeHTTPRequest | requestID；leaseID 可选 | 取消准备中或已准备 lease，不写 Cookie |

requestID 由 Swift 在发送前生成，单次使用；leaseID 由 Dart 生成，均为 UUID。
prepare 成功响应包括 state/requestID/leaseID/url/method/headers/revision/generation/limit；
所有回复均 `executionAllowed=false`。本阶段不实现“已有效配置 Native transport”的推断。
finish response 包含 url/statusCode/cookieSource/setCookieValues，不接受任意账户、MID、
请求 URL 或隐藏的重定向目标。Cookie source 是 provenance，不从数组形状推断分离字段。

prepare 首次 await 前登记 pending；capture stamp 后才读 revision，避免首次匿名 activate
改变 revision。使用实际 Dio options compose 的 URI，与固定 endpoint/limit 对照；复制
base/account headers，合入 referer 和真实 URI 的 CookieJar.loadForRequest 结果。保持现有
Cookie path 排序与重复名称语义。异步返回后检查记录 identity、推荐选择、revision、
generation 与实际 Hive owner；变化时丢弃快照，不默默准备另一账户。

finish/abandon 在首次 await 前决定唯一赢家。finish 匹配原 URL，不按当前选择/MID 回查；
普通换号与其他有效 Cookie 更新不撤销原账户在途响应。同 MID 替换/delete/clear/匿名 reset
撤销旧 generation。完整解析 Cookie 后，在实际 mutation 前、await 后和 Hive 更新前
重新验证原 stamp/owner；错误 HTTP 状态也处理 Cookie，HTTP/API 解码仍由未来服务负责。
Foundation combined 的歧义批次零写入，不能重发 HTTP 来掩盖表示错误。

命令参数类型错误在进入 service claim 前拒绝，不消费有效 lease，调用方仍需 abandon。
有效 ID/token 的 service finish 若响应 URL/Cookie 验证失败，则消费 lease；不能再次写回。
`persistenceFailed` 可能在真实 jar/Hive mutation 后发生，错误回复省略 cookiesSaved，不能
推断为零写入或重发 HTTP；finally 仍关闭请求。302 仅处理原 URL，不跟随 Location，也
不扩展现有 RetryInterceptor 对中间 302 的行为。现有 Hive adapter 的根域 Cookie schema
保留；请求 path/重复名称 fixture 不代表所有 host/path Cookie 跨重启已兼容。

单调 TTL、数量上限和 dispose 释放 pending/prepared；pending 被 abandon 后迟到 load
不能重新安装。unknown ID abandon 留有限、无账户引用的 tombstone，覆盖取消先到的
情况。已开始 finish 的关闭标记不能因 TTL 重开，异常/finally 也不能恢复 prepared。
有限 tombstone 不承诺永久抑制旧 UUID 重放；registry 释放不等于任意底层 Future 被取消。

## 验证与后续门禁

测试使用真实 Hive adapters、Dio BaseOptions 与 pinned CookieJar。可控 load 延迟与同步
mutation 后的 save completion 分别验证异步窗口，不能用虚构 jar 写入时序替代依赖行为。
推荐/主账户、path/重复名、快照、代次撤销、终结竞争、TTL/容量/dispose、响应 URL 与
整批 Cookie 门禁纳入现有 accounts fixtures；定向 analyze 和 logs 进入真实 iOS Actions。
同 SHA 完整 Runner release、FFmpeg 顺序及四组 preview 成功后才标记本切片完成。

338bc39 实际 release 已验证 38 个新增 lease + 22 个已有 Flutter/Hive/Dio 测试，72 项
tracker 检查与定向 analyze 无问题。preview 导航手势失败，不能标记阶段完成。
53705e9 已修 harness 并重跑同 SHA 两条 Actions；最终证据统一写入 PROGRESS.md。

P05a2b 将添加 Swift Sendable context protocol 与 Bridge adapter。现有 invoker 取消会
丢弃 late callback；cleanup 必须使用预生成 requestID 和独立未取消任务，不能依赖收到
leaseID 后才释放。P05a2c 再扩展生产响应头生命周期与有效 transport policy。
Foundation 丢失字段边界和 body 未完成时取消的写回仍未解决，不允许接入 Native trending。
