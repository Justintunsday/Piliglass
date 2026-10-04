# Policy-3：发送前的原生能力判定

2026-10-05，Policy-2 Actions 期间基于实际生产源码准备。
实施前必须先让 Policy-2 完整 release 与全 preview 同一代码 SHA 成功。
仍按 PLAN.md 推进，视觉 UI 重写最后。此文件不是运行时切换或 transport 验收。

## 源码事实与边界

`PiliURLSessionHTTPClient` 强制隔离 Cookie/credentials/cache，复用 session、拒绝
redirect，但把 request/resource timeout 都固定为 10 秒。生产 `transfer` 限定 HTTPS，
每 task delegate 保留 head/cancel/error；Foundation Set-Cookie 来源仍然是 combined。
真实 c1 wire 只证明这部分生命周期，并未证明 Dart 的 connect/receive-idle/send/
transform timeout、br/gzip raw bytes、UTF8 allowMalformed、HTTP2/fallback/proxy/trust。
不能因配置看起来相等就给当前客户端发运行时 Native 请求的许可。

当前 `PiliNativeSearchTrendingService.keywords(headers:limit:)` 是 P04a 的独立未接入
切片，使用 body-only send；运行时 composition 必须先取得一次性 context，并用
head-aware transfer → HeaderFinalizer → body/API mapper。不能直接把旧 helper 接到
Root，或把账号/协议判断放到 View。AetherEngine 不参与能力和 endpoint 策略。

## 可回滚的交付

1. 在 Networking 增加纯 Sendable/Equatable policy evaluator 与 typed decision/reasons。
   输入是 prepared policy 和具体 transport 已验证的能力 profile，无 Pref、账户、
   全局开关或网络副作用。不回显 Cookie、proxy host、token 或实际配置内容到日志。
2. known/unknown 描述与 capability 分开：已描述的负 retry count、负 delay、无效 port
   仍然 unsupported；version/types 由 strict codec 拒绝。issues 有值不补成默认配置。
3. 证据 profile 由具体 transport/composition 固定提供。没有真实 wire/平台证据的
   profile 不得在生产标为 verified；测试的合成 profile 必须明确只用于纯 evaluator。
   当前 Foundation profile 保持 unsupported，不能写几个 true 来打开门禁。
4. 先在独立 Data request executor 建立发送前边界，不改 Root/Search composition。
   unsupported 在未发送时单次 abandon，返回 typed routing decision；上层随后才
   能选择已有 Dart Repository。没有 head/发送结果不明/finish ack 未知时不能回 Dart
   重发。已发且有 head 的所有结果仍 HeaderFinalizer 终结原 owner。
5. 本切片不增加任意 URL、POST、重试或账号权限。门禁仍是两项 false；真正支持的
   transport 组合、API 对照与原账户持久化验收之后再单独提交 composition 切换。

## 第一轮能力矩阵

| 实际输入 | 必须验证的能力 | 当前 Foundation 限制 / 决策 |
|---|---|---|
| pool 缺失或 issues 非空 | 完整有效输入已描述 | unknown → unsupported |
| main 的 H2+H1 fallback；forced HTTP11 | ALPN、fallback、H1-only 路由与同池复用 | URLSession 默认协商不证明可强制 H1；待独立 wire |
| proxy/trust；signed/越界 port | 实际代理、CONNECT、证书与隔离 | 不静默改 host/port/trust；unsupported |
| retry absent / installed count0 | 无 attempt 重放；endpoint redirect=false | 两种状态保留；不将零次数等于无 interceptor |
| retry count2 或其他正数 | 原 owner 上多 attempt、错误类型和增量 delay | attempt 合同尚未实现；unsupported |
| connect/receive-idle/send 微秒超时 | 首字节、块间隔、上传、取消，null/0 禁用语义 | resource 总时限不是 idle；unsupported |
| transformTimeout / error body | 压缩/UTF8/JSON 限时和错误 body 处理 | 默认实现不代表 Dart 语义；待对照 |
| br,gzip + manualCompressionUTF8 | 原始 Content-Encoding 顺序、解压和 malformed UTF8 | URLSession 自动解压无 raw bytes 保证；unsupported |
| persistent + idle15s | pool 生命周期、并发隔离与实际 socket | c1 同 socket 只证明 fixture 场景，未证明完整 pool 策略 |
| Set-Cookie 顺序/字段边界 | H1/H2 原字段、取消与 finish 原 owner | Foundation 信息已丢失；独立 cookie/account 门禁关闭 |

已有 schema 不描述任意自定义 interceptor/transformer/status validator 的行为。
Policy-3 实施时必须明确限定实际已识别 Request 配置，或扩展 describer/严格 schema
使未知行为保持 unsupported；不能凭 await 前后 callback identity 稳定就推断与
Native 等价。当前固定 GET 无请求正文，不扩张自定义 encoder 或上传权限。

## 检查与故障合同

- table fixtures 覆盖每一个 unsupported reason、reason 顺序/去重、全部 unknown、
  无 retry 与 installed0、signed 值、微秒/null/0、main/forcedHTTP11。纯支持例必须用
  明确合成证据 profile；不能据此宣称真实 Native transport 支持。
- 生产 Data executor + counting transfer：unsupported 与 prepare-cancel 零发送、
  单次 abandon；取消不转 fallback，head 后只 finish，unknown ack 不重放。
- 真实 Dart bridge golden 继续经过生产 Swift codec；不存在 descriptor/协议版本
  缺失后用默认值执行的路径。旧 119 context/91 transfer 和全账户/Hive检查保留。
- diff → commit → push → 完整 ios.yml + 全 ios-home-preview 同 SHA；读实际日志，
  出错修复重新跑。未验证的网络行为保持明确待验收状态，随后按 Policy-4 实测。

回滚只还原本阶段 evaluator/executor 接口；Dart 仍负责运行时供数与账号/存储 authority。
不删除设置、登录、旧 HTTP adapter、页面、资源、Flutter bridge/runtime 或 Aether 依赖。
