# P05：有效 HTTP policy 的下一切片计划

2026-10-04 编写于 c1 验证期间；2026-10-05 保存，c1 已通过完整 CI，证据见 PROGRESS.md。
以下 policy 切片待实施，运行时 Native HTTP 未开启。
沿 PLAN.md 推进，UI 重写最后。此计划不把读取最新 Pref 当成有效 transport 状态。

## 已确认的实际语义

来源：`lib/http/init.dart:32,:106,:143,:161,:196,:215`、
`lib/http/retry_interceptor.dart:15`、`lib/utils/storage_pref.dart:560,:741`。

| 项目 | 当前有效状态来自何处 | Native 对照要求 |
|---|---|---|
| HTTP2 | `_enableHttp2` 在 Request 初始化时固定；default false | 区分 HTTP1-only / HTTP2 adapter + HTTP1 fallback，不用当前设置覆盖启动状态 |
| Proxy | `_createPool` 捕获开关/host/可解析port，实际有host和port才启用 | 报告有效pool而非设置意图；敏感host不进入诊断日志 |
| Trust | Proxy时H1/H2都接受坏证书；无proxy时只有H2读取badCertificateCallback，H1不读 | 不能把一个bool套所有transport；暂不支持的组合发送前回Dart |
| Pool重建 | iOS connectivity skip(1)，非none事件debounce500ms，再替换adapter | generation与实际成功安装绑定，失败或部分替换必须unknown，不能伪造新pool成功 |
| Retry | interceptor创建时捕获count/delay；defaults 2/500ms；0时不安装 | 不是每次读取Pref；实际attempt状态保留，未知receipt不重试 |
| Timeout | BaseOptions connect/receive各10秒；receive为数据间隔 | URLSession resource总时限10秒不等价；先用slow-body/idle实测，不用名称映射 |
| Compression | br/gzip请求头，autoUncompress=false，独立gzip/Brotli decoder | actual wire +解压字节对照；不得简单删br改变已有策略 |
| Decode | `_responseDecoder` UTF8 allowMalformed=true | 正文解压/UTF8/API mapper分层；无效字节的行为须明确对照 |
| Connection/cache | pool idle15秒、persistentConnection=true；H1默认keep-alive | session复用/池寿命/URLCache差异单独验证，不因单请求结束销毁Session |

HTTP1 clone 懒创建并复用 Http2Adapter.fallbackAdapter，retry.copyWith 指向clone。
网络变化后 `_http11Dio` 也更新adapter，不能将main与clone描述成永远不同policy。
端点 Options 与Dio BaseOptions可覆盖策略；trending lease目前仅允许固定GET，
不扩展任意URL/POST。账号/敏感头仍来自原lease，不复制到policy store。
`AccountManager._bindRequestAccount`让retry/redirect继续绑定首次owner/generation，
即使用途选择已经变化。当前lease是一次性终结，不能每次retry重新prepare并改用
新选中账户；尚无等价的attempt/owner合同前，非零retry模式发送前选择Dart。

RetryInterceptor 只在无response且 connectionError/connectTimeout/sendTimeout/unknown
时按递增delay重试，TransportConnectionException除外；stream完全不重试。
有response只处理其明确redirect分支（303改GET/清body、递减maxRedirects），其余next。
原策略未按method安全性筛选，Native不能据此自动重放认证/写入请求；后续行为修正
独立审查，保留该写领域Dart实现。当前trending GET实际options/redirect对照仍待验证。

## 小阶段交付顺序

1. **Policy-1：Dart实际状态描述与fixture。** 引入不可变effective descriptor，分别
   记录启动protocol、实际pool配置/安装generation、已安装retry值、Dio有效timeouts/
   decoder/persistence。描述必须在对应真实创建/安装处捕获；不修改策略或设置默认值。
   描述不持有客户端/CookieJar/账户，也不含proxy凭据。失败与部分安装标unknown。
2. **Policy-2：lease snapshot扩展与Swift严格codec。** 带versioned policy DTO以及
   generation；prepare在await前后检查pool/请求revision，混合快照明确拒绝或重新
   prepare，不能让已发送请求自动重发。新增字段同步实际Dart/Swift合同及inventory。
   不将policy变化等同账户generation撤销；实际head仍须终结原owner。
3. **Policy-3：纯Native能力判定。** 注入typedPolicy到Data执行器，返回supported/
   unsupported原因；unsupported只在发送前选Dart，非诊断UI。当前Foundation不能
   保留所有Set-Cookie边界，故即使policy支持也不能开启runtime。
4. **Policy-4：逐项真实transport对照。** timeout/解压/protocol/连接/代理分开commit，
   每次实际Dart adapter与候选Native跑相同无凭据loopback/TLS场景。原值/设置不改。
   保持严格证书验证；旧宽松trust模式未有明确原生实现与验收前走Dart，不默认扩大。
5. **后续字段transport门禁。** 独立验证有序Set-Cookie HTTP1/HTTP2来源与取消、TLS、
   iOS16编译/链接。AHC/SwiftNIO仅候选，尚未增加依赖；再决定支持policy的组合。
   最后只有通过transport/account/API对照的trending composition才能开启。

这里的阶段标签是实施组，每组可能拆多个可回滚commit。阶段源码必须加入Runner及
独立Swift6 fixtures；不在Root/Player/View增加policy判断或请求逻辑，不改变Aether。

## 可证伪验证

- 真实Dart fixture启动后更改Pref：HTTP2/retry值应保持原effective状态；显式成功
  pool重建后proxy/trust描述才变化。失败、fallback clone、并发prepare与部分安装测试。
- deadline/idle分开：持续小块正文超过10秒、首字节延迟、块间暂停、连接超时与取消。
  记录真实错误类型和已收到head；已收到Cookie仍finish原lease，不能用重试掩盖错误。
- 真实raw gzip/Brotli/identity与错误Content-Encoding、损坏压缩、malformed UTF8；
  actualDart decoder输出与Native输出逐字节比较，不只测新实现自己的expected。
- Retry用本地实际attempt计数/参数/header/owner；覆盖count0/2、response403/5xx、
  stream、已取消、unknown ack、TransportConnectionException，写请求不扩张Native范围。
- HTTP1/HTTP2 ALPN与fallback、proxy CONNECT、证书错误、共享Session同socket与网络
  变化代次分开观察；机器无法验证的组合保持unsupported，不标兼容成功。
- synthetic报告不含Cookie/accessKey/refreshToken/私人proxy信息。每阶段diff→commit→
  push→ios.yml和全ios-home-preview同SHA，读取实际日志，失败修复重跑。

## 回滚与开放门禁

Policy-1/2只增加可对照描述，authority继续Dart；回滚恢复旧协议和关门禁，不删除
原adapter/设置/重试路径。policy变更不能使一次已发送请求转为第二次Dart请求。
设置为0或关闭HTTP2/代理不作为用户必须接受的迁移前提，兼容组合逐步实现。
UI风格、普通Feature结构与业务参数不混入此阶段；现有Flutter fallback继续保留。
