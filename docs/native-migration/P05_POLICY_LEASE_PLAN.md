# Policy-2：将有效配置绑定到一次性请求上下文

2026-10-05，Policy-1 CI 等待期间保存准备；现已实施，完整 Actions 尚待验证。
最新阶段状态以 PROGRESS.md 为准。继续 PLAN.md，UI 重写最后。

## 源码约束

`NativeHTTPRequestLeaseService.prepare` 在 CookieJar 的 await 前 compose 固定 trending
GET、复制 headers、绑定 recommend owner/stamp/revision，await 后复查账户选择和代次。
现在没有 pool 或 BaseOptions 复查；仅增加 poolGeneration 不足以识别 options/retry
变化。`NativeHTTPRequestLeaseBridge` 和 Swift `PiliHTTPRequestContextBridgeCodec` 都有
严格字段集合，不能只在 Dart 单侧增加任意字段。HeaderFinalizer 的终结所有权依然
来自已准备的 context，不从当前设置/用途选择重新推导。
Policy-1 实际 CI 与 pinned Dio.clone 源码确认：main/HTTP11 clone 共享 BaseOptions，
但 RetryInterceptor 被复制并绑定 clone；两者不能假设所有配置都独立或都共享。

## 单独可回滚的交付

1. 定义不可变 prepared policy DTO；有明确 schema version、poolGeneration、客户端
   模式、实际 pool 配置、有效 retry presence/count/delay、timeout 单位、persistent/
   redirect/encoding/decoder。无 Dio、账户或回调引用；proxy 配置不写到诊断日志。
   保留实际 Dart Duration 精度，不以毫秒截断微秒值。unsupported 值由能力层拒绝，
   不把旧设置归一化成另一种网络行为。
2. prepare 同步 capture 实际基础 policy，并 compose 本次 endpoint Options；使用
   composed 的 redirect/timeouts 等值，而非未合并的 BaseOptions。当前 trending 明确
   followRedirects=false；不能把基类默认 true 误写进请求 policy。
3. Cookie await 后复查 pool 描述/代次、retry 实际值/绑定和完整有效请求输入，包括
   composed headers；同时保留现有 owner/revision 检查。变化时清理 pending 并返回
   snapshotChanged；不自己重试 prepare，不给已发送请求换账户或重新发起 HTTP。
4. snapshot 添加唯一嵌套 policy 字段；Dart bridge 和 Swift codec 同一 commit 升级。
   Swift Networking 独立 Sendable/Equatable DTO 与严格 policy codec，Data context
   引用它；顶层 UUID/固定 endpoint/headers/false gate 的现有约束继续保留。
   未识别 schema/缺字段/错 Bool-Int-Double/矛盾 pool 状态必须拒绝并单次 abandon。
5. 未描述配置可以明确返回 unknown DTO，但不能伪装成已知默认 policy；Native
   capability 判定在 Policy-3 单独交付。executionAllowed 仍 false，不接入 Root/Search。

codec 只证明结构和值表示合法；例如负 retry count、无效 proxy port 或暂不支持的
压缩/超时/证书组合不等于 Native 可执行。是否支持必须由独立能力层给出原因。
无 RetryInterceptor 与 count=0 的已安装 interceptor 需区分，后者仍有 redirect 行为。
池配置的 HTTP2 启动值和 forced HTTP11 客户端模式也分别保留。

## 所有权与终结

prepare 后的 policy 变化不能撤销原账户 generation。尚未发送的请求可由执行器在
明确 preflight 中一次 abandon；已经发送并获得 head 的请求仍 finish 原 lease，即使
新 pool/选中账户/设置已变化。未知 ack 不重试，不能改为 Dart 请求来掩盖结果。
Retry 非零的支持仍等待多 attempt 与首次 owner 的明确合同，不为每个 attempt
重新按当前用途 prepare；本切片不增加重试、写请求或任意 URL 的 Native 权限。

## 可证伪验证与门禁

- 真实 Dart lease + Hive：在受控 Cookie await 中成功换 pool、部分替换失败、修改
  timeout/encoding/base header/decoder/实际 retry；混合快照拒绝，无 Cookie/Hive 写入。
  单纯写 Pref 且未替换实际 pool/retry 时按原有效状态处理，不误判为账户撤销。
- 正常 prepared DTO 完整等于实际 composed 输入；override followRedirects=false、
  微秒 timeout、零/非零/未安装 retry、forced H11 模式和 unknown 状态均有实际对照。
- 同一 job 用真实 Dart bridge 导出无凭据 golden，Swift 6 complete 编译实际 production
  DTO/codec/provider 消费该输入；保留既有 119 context 与 91 transfer 检查，不只测试
  Swift 手造回包。额外 malformed fixtures 验证 schema、类型和单次 cleanup。
- finish 已有 head 后改 policy/换号：真实 Hive owner 写回仍准确，取消/超时/晚 ack
  无重放。Policy-1 回环结果只证明旧 Dart 配置，不升级为 Native transport parity。
- 检查 diff→commit→push→完整 ios.yml + 全 ios-home-preview 同 SHA 成功，读取实际
  日志后才闭环。保持 Aether 独立、Flutter fallback 和两项 runtime 门禁关闭。

回滚同阶段 Dart/Swift 协议及 fixtures，保持旧 runtime 继续供数；不删 bridge command、
旧登录、CookieJar/Hive、页面、资源或依赖。实施前再次核对 Policy-1 的最终已验证代码。

## 当前实现及验证入口

`prepared_http_policy.dart` 复制版本 1 的嵌套 policy；connect/receiveIdle/send/transform
timeout 使用整数微秒，保留 receiveDataWhenStatusError、有效 pool/proxy/trust、实际
retry presence/count/delay 和 decoder 描述。未知 pool/retry/decoder 明确标注 issues；
注入自定义 BaseOptions 而未配对描述器时保持 unknown，不能借用 Request 的已知池。
prepare 在 Cookie await 后重新 compose，比较 policy、headers、URL 和仅内部保留的
decoder/encoder/validateStatus identity；这些回调不进入 snapshot 或 bridge。
基础 followRedirects 被 endpoint false 覆盖，配置变化不改变已经 prepared 的 owner。

Swift Networking DTO/strict codec 验证字段集合、Bool/Int/Double、版本、池/issue 和
retry presence 的一致性；Data context codec 继续固定 URL/GET/limit/false gate，另验
encoding 与已验证 headers 一致。负 retry/port 等实际配置保留为描述，不能据此宣称
Native 支持。当前 schema 不描述任意自定义 interceptor、transformer/status validator
的运行行为，Native capability/transport 对照仍是后续独立门禁。

两种冷启动的真实 Hive/Request/IO/H2 fixtures 包括 await 中成功/部分失败的 pool 变化、
timeout/encoding/headers/decoder/retry/validator 修改、Pref-only、403 head 后改 pool/换
用途且实际关闭重开 Hive 验证原 owner 回写；根 domain Cookie 的持久化与 host-only
Cookie 的旧 adapter 丢失分别断言，不声称
恢复所有 domain/path 属性。实际 Dart bridge 导出 16 组只含合成
账户/代理数据的 golden；`check_prepared_http_policy.py` 编译 Swift 6 complete 的
生产 codec/provider 消费它们，另验证 malformed policy 的单次 abandon。旧 context/
transfer 合同继续执行；本地 Windows 检查不作为编译完成依据。
