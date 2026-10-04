# Policy-4 与字段保留 transport：可执行对照顺序

> 2026-10-05 执行节奏更新：按用户最新要求，同组并行实施、各切片独立检查/提交/推送，整组汇合后统一运行 release 与全部 preview，并读取实际日志修复至成功。本文件旧有逐切片完整 CI 门禁由此替代；功能/数据验收、fallback 删除和权威切换门禁保留。见 [P05_GROUP_ACCEPTANCE.md](P05_GROUP_ACCEPTANCE.md)。

2026-10-05，在 Policy-2 完整 Actions 期间准备，不增加生产依赖或切换运行时。
按 P05_POLICY_CAPABILITY_PLAN.md 的发送前边界推进；UI 重写最后。

## 固定版本候选复核

已读取 [AHC 1.36.1 manifest](https://github.com/swift-server/async-http-client/blob/1.36.1/Package.swift)
及 [HTTPClient 配置源码](https://github.com/swift-server/async-http-client/blob/1.36.1/Sources/AsyncHTTPClient/HTTPClient.swift)。
该候选使用 Swift tools 6.2，NIO 最低 2.100.0，并有 NIOTransportServices 的 iOS
dependency condition；这不构成本仓 iOS16 编译/链接或行为支持证明。不能以 manifest
没有排除 iOS 代替实际 Runner 编译。采用前记录完整 transitive resolved versions。

该版本配置源码显示 decompression 默认 disabled；redirect nil 创建默认 redirect
配置，必须显式 disallow。connect=nil 有 10 秒默认、read/write 可独立描述，自动协议
和 http1Only 是不同模式。共享 event loop 的 shutdown authority 也需明确。
这些是选型输入，不是与 Dart 等价的结论；不得盲目使用候选默认值。
有序字段候选类型见 [NIO 2.100.0 HTTPTypes](https://github.com/apple/swift-nio/blob/2.100.0/Sources/NIOHTTP1/HTTPTypes.swift)。

## 小切片及先后门禁

1. **隔离候选编译/字段 probe。** 新 Networking package 或独立验证 target，不把
   HTTP 依赖加入 Aether。先用 Xcode 实际编译 iOS16 device/simulator，并在同轮完整
   Runner/preview CI 验证链接、包解析和 FFmpeg order；记录包体变化。依赖选择失败
   时保留原 runtime 与 probe 日志，不能删旧路径来修 build。
2. **HTTP1 raw fields 与取消。** 实际 IPv4 server 逐行输出重复 Set-Cookie，候选
   response head 逐项遍历字段，复制顺序和值；禁用自动解压、redirect 和 Cookie
   authority。不要调用逗号拼接/规范化接口。覆盖单字段、Path/Expires 歧义对、空值、
   同名 Cookie 不同 path、403、302、head 后 cancel/EOF、head 前 cancel、并发和释放。
  与当前 Foundation 对同一 wire 的信息丢失报告并列保存，不能据 parser 猜回原字段。
   当前 PiliHTTPResponseCookieFields 只有 foundationCombined/unsupported，候选有序
   字段需与 HeaderFinalizer 同阶段增添明确 provenance；不能把旧 combined 改名
   separatedFields。旧 factory probes 与真实 wire 的来源区分继续保留。
3. **原 owner 终结。** 候选 transfer 遵循现有 Outcome/HeaderFinalizer 契约；head
   到达后 body 的错误/取消不丢头。将有序值交给实际 Dart lease/Hive，关闭重开 Box
   验证原 owner 与单次消费。回环地址不获得 Bilibili API 权限，测试映射明确标记。
4. **HTTP1 timeout 对照。** 真实旧 Dio forced-H11 与候选跑同一 server schedule，
   记录首字节/每块到达/完成/实际错误及 attempt；先证明而后实现最小默认组合。
   保留 Duration 微秒；null/0 的禁用语义不能映射为候选默认 10 秒或立即超时。
   微秒转纳秒检查 Int64 溢出；超范围保持 unsupported，不截断/饱和改变行为。
5. **正文解压/UTF8。** server 提供 identity/gzip/br 实际压缩字节；Dart 使用当前
   Request.responseBytesDecoder 和实际 responseDecoder/transformer，候选保留原 bytes
   再调用独立 Native decoder。记录原始字节与实际字符串/JSON，不只比较重编码后的
   数据。损坏压缩、大小写/未知/multiple encoding、无 Content-Type、malformed UTF8
   的行为依原 Dart 对照；Swift 默认 JSONDecoder 的 UTF8 验证不能替代 allowMalformed。
6. **HTTP2/TLS/fallback。** 固定无私人数据的本地 TLS fixture，实际 H2 frames/重复
   字段及 ALPN/fallback 观察；系统 trust、无效证书/host、取消和 shared connection
   单独记录。fixture trust 只能用于隔离验证目标，生产不改 ATS 或宽松 trust 门禁。
   Mac wire 成功后仍需 Runner/iOS 编译；真机条件不足的行为明确待验收。
7. **Proxy/pool/retry。** CONNECT、网络变化 generation、idle15s、共享连接及多
   attempt 原 owner 独立小阶段。未覆盖设置组合继续走 Dart，不要求用户关闭 proxy/
   HTTP2 或把 retry 调成 0。GET 的错误分类与 delay 对照成功不授权重放登录/写请求。
8. **trending composition。** 只有实际 transport/policy/account/API 门禁都通过才接
   Feature→Repository；先只固定 endpoint GET。Root/SwiftUI 不包含协议、Cookie、
   status 或能力逻辑；不能让 body-only helper 绕过 context/HeadFinalizer。

每个代码小阶段必须 diff→commit→push→ios.yml + 全 ios-home-preview 同 SHA→实际
日志修复到成功，再进入下一代码小阶段。纯计划与 fixture 准备可在 CI 等待中继续。

## Timeout schedule 的真实反例

| schedule | 应观察的语义 | 对照限制 |
|---|---|---|
| 首字节晚于 receive limit | 实际 Dio receiveTimeout / Native 实际错误 | 不从 elapsed 自行伪造错误码 |
| 连续小块总时长 > 10 秒、每块间隔 < limit | Dio idle 不应因总时长触发；检验当前 Foundation resource 差异 | 明确默认组合，不用小 timeout fixture 代替默认总时长反例 |
| head 后块间隔 > limit | head 保留、Cookie finish 原 owner、正文 timeout | 未知 ack 不能重放或二次 abandon |
| null/zero 与短正常响应 | 不应立即 timeout | 单次成功不足以证明无限 timeout，另观察延迟场景 |
| cancel 与 head/timeout 同时发生 | 一次 Outcome、真实已观察 head、单次 terminal | 不依据取消 flag 编造 -999/零发送 |
| connect/send/transform limit | 连接/上传/解码各自阶段 | 第一轮 GET 不假装覆盖上传；未覆盖组合 unsupported |

首批 fixture 可缩短额外场景，但必须保留 >10 秒的默认 idle 与总时长区分反例。
纯 sleep 不当作 wire 延迟证据；server/client 实际事件各记单调时钟与 connection ID。
报告只含合成字段/账户/代理数据，绝不导出真实 Cookie/token/accessKey 或私人 host。

## 不能绕过的证据

有序 header 容器并不证明 HTTP2 field order 或 cancel 保留；必须实际传输。
AsyncHTTPClient API 返回 response 后仍需逐步读取 body，不能 collect 成功才记录 head。
request deadline 不得偷偷成为 Dart idle timeout。压缩禁用是候选配置，Brotli 实现/
损坏字节行为仍需独立 C/Objective-C/Swift 桥接与实际测试；不把协议放进 SwiftUI。
具体库能否完全匹配将在 probe 中决定，未验证前 runtime/account 门禁保持关闭。

另有已核对的长请求门禁：Dart lease 默认 ttl=1 分钟，当前 HeaderFinalizer 接收的是
transfer 完成 Outcome，finishing marker 则在 finish 命令才建立。若 head 早到而 body
持续超过 ttl，当前 prepare lease 可能先到期。trending 的短 wire 检查没有覆盖这点。
在允许无限/长时间 idle 或下载执行前，必须实际验证并明确 head 时点终结/续期或
其他生命周期方案；不能靠资源总时限截断来掩盖，也不能未经合同增加 terminal 重放。
任何 ttl/stream 改动另成可回滚阶段，测试 timer、cancel、expire、owner revoke 竞争。
