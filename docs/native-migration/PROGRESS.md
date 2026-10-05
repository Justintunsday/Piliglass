# 迁移进度与编译证据

最后更新：2026-10-05（Asia/Hong_Kong）。目标仍在进行，Flutter runtime 保留。

当前阶段为 **P05**。上一并行组在 `bedde36` 的完整 release5 + preview4 jobs
通过；当前实施 [CA1 jar-only shadow](P05_COOKIE_AUTHORITY_PLAN.md) 第一组，
不是完整账户 authority 切换。exporter、严格 UTF16/有序格式及 Keychain staging
已分五个独立提交推送，集成代码 `f11329b` 的 CI 正在验收。
首次实际 Dart 检查发现一个 fixture 错误：原 nil path Cookie 已被同 bucket/name
的 `/x` Cookie 覆盖，最终 header 不能继续包含旧值。独立 producer 17pass/1fail、
完整账户 suite 100pass/1fail，strict analyze 均无问题；修复 `4fdb871` 保留操作
序列并分别验证覆盖前后的完整 jar/header。Swift 独立 codec/staging 尚未执行，
必须在修复后的同一 SHA 重跑完整 release 和全部 preview 后才接受本组。
P05 仍需完整账户 envelope、mutation engine、统一 reader/writer、durable 交接/
回退及真实账户/设备验收；Native runtime 关闭，视觉 UI 重写继续排在 P05–P12 后。

2026-10-05 执行节奏按用户要求改为组内并行实施、独立提交推送、组末统一编译
验收。当前 P05 并行组已提交网络能力/响应头执行边界、原始字段候选、签名/cache、
账户 shadow store、Cookie parser/selector、独立 body codec、登录协议/状态机及
H1/H2/TLS 对照，整组验收进行中，不计入已验证阶段。
详见 [P05_GROUP_ACCEPTANCE.md](P05_GROUP_ACCEPTANCE.md)；最终仍以同 SHA release
及全部 preview 实际日志为准，Native runtime/账户权威保持关闭。

第一轮集成 dfcd9c3 的 [release](https://github.com/Justintunsday/Piliglass/actions/runs/37283325975)
失败：新 raw job 未应用已有 Flutter SDK patch；账户 analyze 报两个 fatal-info。
签名/cache 局部检查 102 项、19 个实际 Dart 签名及 5 个实际 Hive cache 场景通过；
body codec 的 25 个实际正文、67,854 个 UTF8 向量及 iOS16 device/simulator build
通过。这些局部成功不能替代完整 Runner 或整组完成。

已分别提交 raw 环境修复 818a989、实际依赖锁定 3776573、账户 lint 15b2351、
独立诊断与强制聚合门禁 d9c0da1、登录 await owner 复查/真实 Hive 竞态 8eb2050。
第二轮代码 8eb2050 的 [release](https://github.com/Justintunsday/Piliglass/actions/runs/37284584075)
与 [全部 preview](https://github.com/Justintunsday/Piliglass/actions/runs/37284588783)
第二轮 release 失败、四个 preview jobs 成功。完整 Runner 已构建（109.1 MB），
FFmpeg 顺序通过；强制门禁正确阻止失败组发布。实际失败为 TestWidgets 的 400
网络 override、Dart SameSite 标签大小写、登录四项 fatal-info，已分别修复。

第三轮代码 94b62e5 的 [release](https://github.com/Justintunsday/Piliglass/actions/runs/37286952156)
及 [preview](https://github.com/Justintunsday/Piliglass/actions/runs/37286957408)
已完成：完整 Runner、账户 shadow 67、Cookie 68、登录 225 项检查通过；
登录实际 Dart 7 个测试及 20 个 golden 通过。raw H1 的实际 Dart 测试通过，
Swift 14 个观测符合预期，但 no-head 取消分支错误继续要求成功正文，测试失败；
已按真实结果修正断言，H2/TLS 尚未执行，不能算通过。导航 preview 9 个用例
中的 settings 单次侧滑没有启动 pop；实际 event/录屏未见生产 UI 回归，已按真实
窗口坐标及 150ms down 修正 fixture，保留单次返回和持久化断言，尚待重跑。
完整 Runner 实际 27 项 Swift dependency resolution 已复制锁定，不由本地猜测。
当前仍未整组验收，将在修复汇合后的同一 SHA 重跑 release 与全部 preview。
聚合门禁以每组 step.outcome 检查 success，任一失败/跳过/缺失均 fail，发布前执行。

后续 Cookie/账户权威方案保存于 [P05_COOKIE_AUTHORITY_PLAN.md](P05_COOKIE_AUTHORITY_PLAN.md)：
CA1–CA6 分别收口有序格式、mutation、统一 writer/reader、durable 交接与回退、
真实账户候选验收及按证据开放。仅并行准备，旧 runtime/authority 保持不变。

第四轮集成代码 **bedde36e4f08337bb42a18e7bb1da4799b04a09d** 的
[release](https://github.com/Justintunsday/Piliglass/actions/runs/37318516019) 5个 jobs 与
[preview](https://github.com/Justintunsday/Piliglass/actions/runs/37318521532) 4个 jobs 全部
success，已读实际日志/artifacts。完整 Runner 109.1MB、BUILD SUCCEEDED、Aether
FFmpeg 顺序通过。raw H1 实际 Dart/Native 各14观测、iOS16 device/simulator 通过；
H2/TLS 14传输+2信任拒绝+2主机名拒绝+1自动H1 fallback通过。签名102/19/5、
body25/67854/4、账户67、Cookie68、登录225/20及实际账户83tests通过。
导航9tests、账户6、图片3、播放器2及压力 failures=[] 通过：comments1000懒加载/
无离屏分页/末项分页正常，danmaku100000/maxActive60。资产、AetherEngine源码
没有意外删除或本组变更。本组编译与这些合同验收完成，P05整体未完成；实际
API/账户设备、proxy/retry/pool完整语义、Native写入权威与生产composition仍待做。

下一组 CA1 第一交付准备了 jar-only 有序 schema2 exporter/strict codec/Keychain
shadow，及真实 CookieJar/Hive mutation轨迹；不包含账户envelope或mutation engine。
将独立提交后在同一SHA统一CI验收；准备代码尚不属于上述bedde36已验证范围。

| 阶段 | 阶段代码 Commit | iOS release | Preview | 状态 |
|---|---|---|---|---|
| 起点 | 8044a8d | [成功](https://github.com/Justintunsday/Piliglass/actions/runs/36085475142) | [分页检查失败](https://github.com/Justintunsday/Piliglass/actions/runs/36085470278) | 仅基线 |
| P00 | 603d3c6 -> ad0e8b5 | [成功](https://github.com/Justintunsday/Piliglass/actions/runs/37132297374) | [全部成功](https://github.com/Justintunsday/Piliglass/actions/runs/37132297176) | 基线与迁移计划完成 |
| P01a | b906383 -> c783318 | [成功](https://github.com/Justintunsday/Piliglass/actions/runs/37133641553) | [全部成功](https://github.com/Justintunsday/Piliglass/actions/runs/37133641528) | 首批组件边界完成 |
| P01b | 9d9fb2f | [成功](https://github.com/Justintunsday/Piliglass/actions/runs/37135310166) | [全部成功](https://github.com/Justintunsday/Piliglass/actions/runs/37135310327) | DesignSystem/codec 边界完成 |
| P02a | 662f739 | [成功](https://github.com/Justintunsday/Piliglass/actions/runs/37136856478) | [全部成功](https://github.com/Justintunsday/Piliglass/actions/runs/37136856328) | Search Feature/UI 状态契约完成 |
| P03 | 7ff23b9 | [成功，含 Swift 6 core](https://github.com/Justintunsday/Piliglass/actions/runs/37140033171) | [全部成功](https://github.com/Justintunsday/Piliglass/actions/runs/37139965902) | Native Search state、typed Repository 与临时 Dart adapter 完成 |
| P04a | aa8e3c4 -> b0c098a | [成功，含 HTTP/Search Swift 6 core](https://github.com/Justintunsday/Piliglass/actions/runs/37163367936) | [全部成功](https://github.com/Justintunsday/Piliglass/actions/runs/37163367691) | Native HTTP Client/热榜 Service fixture 完成；runtime 未切换 |
| P05a1a | dc8bbbb -> 834c3b9 | [成功，含 Cookie wire/parser](https://github.com/Justintunsday/Piliglass/actions/runs/37165907525) | [全部成功](https://github.com/Justintunsday/Piliglass/actions/runs/37165910178) | 共享响应 Cookie parser 与表示门禁完成；账户/context/runtime 未切换 |
| P05a1b | a19fe5a -> 15a7f9d | [成功，含账户生命周期测试](https://github.com/Justintunsday/Piliglass/actions/runs/37177848831) | [全部成功](https://github.com/Justintunsday/Piliglass/actions/runs/37177850629) | 账户 generation/存储所有权与 Dio 写回边界完成；Native lease/runtime 未切换 |
| P05a2a | 78a0948 -> 338bc39 -> 53705e9 -> c0fbdbf | [成功](https://github.com/Justintunsday/Piliglass/actions/runs/37193624110) | [全部成功](https://github.com/Justintunsday/Piliglass/actions/runs/37193623955) | Dart lease 与薄命令完成；Swift adapter/runtime 未接入 |
| P05a2b | 63dac5f -> 4148caf | [成功，含 119 项 Swift 6 context 检查](https://github.com/Justintunsday/Piliglass/actions/runs/37195363892) | [全部成功](https://github.com/Justintunsday/Piliglass/actions/runs/37195365890) | Swift context/adapter/terminal cleanup 完成；runtime 保持关闭 |
| P05a2c1 | eddc20a -> d80c92b | [成功，含 91 项实际 transfer 检查](https://github.com/Justintunsday/Piliglass/actions/runs/37215530254) | [全部成功](https://github.com/Justintunsday/Piliglass/actions/runs/37215523453) | 响应头/取消/一次性 lease 终结完成；有效 policy、字段保存 transport 与 runtime 尚未切换 |
| P05 Policy-1 | 60817d7 -> 62eab04 | [成功，含 21 个实际 policy tests](https://github.com/Justintunsday/Piliglass/actions/runs/37218110078) | [全部成功](https://github.com/Justintunsday/Piliglass/actions/runs/37218112840) | Dart 实际 pool/retry/BaseOptions 描述已验证；lease/Swift policy codec 与 Native runtime 待接入 |

P00 证据：inventory 包含 59 个 bridge commands、62 个注册 Flutter routes、311 个 REST 常量、45 个 gRPC 常量、95 个依赖。压力检查 `failures=[]`，1,000 条评论保持懒加载、未在离屏处触发分页、实际末条出现后分页成功；100,000 条弹幕保留，活跃渲染上限 60。仅测试 harness 调整了懒加载自适应行定位等待；没有修改生产 UI 或业务。

P00 实际 Actions 工具链：Xcode 26.6 / Apple Swift 6.3.3；Runner 仍以 Swift 5 language mode 构建。release 日志确认 Aether FFmpeg 在 media-kit FFmpeg 之前链接。

P01a 范围：从 Root 抽出 Flutter player surface，从 Player 抽出诊断日志与同步 HTTP range IOReader。保留 child containment、缓存/seek/取消和所有 fallback；同步扩展 localization checker 到 Native 子目录。逐类型对比移动前后正文，仅放宽两个 file-private 类型到 Runner 内部可见。

P01a 验证：当前阶段代码 `c783318d8e13f93061b2ce5f6ed3cd9153097593` 的完整 iOS release 编译和 FFmpeg 链接顺序检查通过；preview 的 account-pages、image-preview、player-controls、preview 四个 jobs 全通过。本地 staged diff 检查通过；没有删除业务、资源或依赖。类型正文一致性与本地 source extractor 检查只作为提交前检查，完成依据是上述真实 Actions。

P01b 范围：抽出 semantic design tokens、3 个 view modifiers、View chrome extension 与
7 个 codec helpers；更新 Xcode 注册与集中 preview 源读取。类型正文和四个预览生成
结果与提交前一致（忽略空行），仅放宽跨文件需要的可见性。独立子智能审查发现并
修复 helper-only CI path 覆盖缺口；未删除功能、资源或 Flutter fallback。

P01b 验证：`9d9fb2fd704af2458d51cee9307b5a6146406f7a` 的 release 与 preview 同 SHA
全部成功。Actions 日志确认完整 Runner 编译、677 项双语检查与 Foundation runtime
格式化检查通过；account-pages、image-preview、player-controls、preview 全部成功。
下载实际视频压力报告：`failures=[]`、评论 1,000/懒加载/无离屏分页/末条分页通过，
100,000 条弹幕完整保留、活跃上限 60，末条定位用了 2 次真实滚动。

P02a 范围：Search View 以 MainActor/ObservableObject 的窄协议读取 12 个属性、调用
7 个操作，Root ViewModel 继续私有；新增播放导航转发保留原有默认参数。拆出 video
bridge DTO、loading/error、transition source 和 remote image。Root 减少约 420 行。
图片 loader 保留动态/评论图片所需的内部访问权限，缓存/取消和业务正文未变。
预览 fixture 使用实际生产协议与泛型 View，保持 actor/namespace/Reduce Motion guards。

P02a 验证：`662f7399d9633853e8b4167e50fd18c305487778` 的完整 release 与四组 preview
同 SHA 全成功，实际日志确认完整 Runner 编译及 FFmpeg load order。本地正文对照与
独立子智能审查无剩余问题；没有删除功能/资源/依赖。实际视频报告 `failures=[]`，
1,000 评论的懒加载/离屏分页/末条分页检查通过，100,000 弹幕完整保留、活跃上限 60。
本阶段只完成 UI/状态依赖边界，搜索业务仍由 Dart 提供；不能视作 Repository 迁移完成。

P03 范围：Root 不再持有搜索状态或发起搜索 channel 调用。独立 MainActor Search model
注入 Sendable Domain Repository；Data adapter 暂时转发现有 Dart 请求和 Hive 操作。
不可变 codec snapshot 在 Flutter 回调线程捕获后跨 actor 传递，invoker 统一完成/取消
门禁，忽略重复与迟到回调。请求代次覆盖重复词/A→B→A，提交失效联想，关闭取消读取。
record/remove/clear 统一排序；第一页先等待历史写入，保存失败阻止 HTTP，clear 不等待
视频 HTTP。已请求的写操作保留，迟到快照不能回写新状态。旧 Dart callers 默认继续
自动记历史；Native adapter 显式记录后传 `recordHistory: false` 避免重复写入。

P03 验证：`7ff23b9c52909c07dcf5ad9ff0b5d3db4d6f70e8` 两个 workflow 同 SHA 成功。
真实 macOS Swift 6 `-strict-concurrency=complete` 编译生产核心，63 项 codec/transport/
Repository/state/history/cancellation 检查通过；完整 Runner release 编译及 Aether FFmpeg
load order 通过，实际 Flutter SDK wrapper 由完整 Runner 验证。四组 preview 全成功。
下载的视频压力报告 `failures=[]`，1,000 评论懒加载、离屏不分页、末条分页通过，
100,000 弹幕完整保留、活跃上限 60。提交前 diff 检查通过，无业务/资源/依赖删除。
本阶段只完成 Native state 和业务边界，不能据此宣称搜索网络或存储已原生化。

P04a 范围：独立 Sendable HTTP contract、隔离 URLSession Client、固定 trending request
builder、API decoder 与 Domain mapping。拒绝自动重定向/共享 Cookie，保留原始 HTTP
status/body/Foundation headers（包括错误响应），不启用运行时调用、不替换账户或 Hive。
四个生产文件注册到 Runner；Swift 6 fixture 直接编译和调用生产实现。

P04a 修复闭环：首次 [CI](https://github.com/Justintunsday/Piliglass/actions/runs/37162957810)
的 HTTP job 编译成功，但实际 fixture 失败于 `Invalid header accepted`。读取下载的
compile/result 日志后，将 CR/LF 检查改为 Unicode scalar 检查，覆盖 CRLF 的组合字符，
补充独立 CR/LF 与用例编号；commit+push `b0c098a` 后重跑两条 workflow。旧 run 被新
SHA 替代并取消，不能当作完成证据。

P04a 验证：两条 workflow 的 headSha 均为 `b0c098abb4ec5d20dcd2edb2a65fee11506f7bbf`。
真实 macOS Swift 6 complete concurrency 检查通过，HTTP 74 + Search 63 共 137 项
runtime fixtures 通过。完整 Runner release 日志确认 `BUILD SUCCEEDED`、677 项双语检查
和 FFmpeg load order；preview 四组 job 全通过。实际压力报告 `failures=[]`，评论 1,000
懒加载/离屏不分页/末条分页成功；弹幕 100,000 完整保留，活跃上限 60。检查 staged diff
无功能/资源/依赖删除。Windows 本地 skip 没有作为编译证据。

下一步：P05a 共享 Cookie parser 与账户 revision/generation，然后 context lease；
计划已保存为 [REQUEST_CONTEXT.md](REQUEST_CONTEXT.md)。并行审查确认 Expires 合并
分割、同 MID 旧对象持久化、匿名 reset 与“收到响应头后取消”必须单独验证；保护也要
覆盖现有 Dart writeback。P04a 的 transport/body cancellation fixture 不代表这些门禁
已通过。Native HTTP runtime 切换仍必须保留 recommend 账户与 Cookie 语义，
P05a context lease -> P04b hybrid cutover。实现/限制见 [HTTP.md](HTTP.md)。
Dart 业务仍完整保留，整体原生化目标仍在进行中。

P05a1a 范围：抽出纯 Dart response Cookie helper 并接入现有 AccountManager，修正
Expires 日期逗号误拆；保留原账户绑定/错误/redirect/Hive 流程。显式区分真正分离字段、
Dio legacy recovery 与 Foundation combined provenance；原文、offset、顺序、诊断保留，
不按 name 去重或跳过坏记录。attribute span 里的猜测边界关闭 Native 持久化门禁，
不对 speculative segments 解码或展示半份 Cookie。没有删除功能、资源或依赖。

P05a1a 修复闭环：首次 [release run](https://github.com/Justintunsday/Piliglass/actions/runs/37165529466)
Swift 6 编译成功，但只发送头/零 body 的 pending fixture 未收到 response callback。
下载实际 report/server-wire/compile 日志后，改为同时发送头和 1024/4096 字节 prefix，
body 仍未完成；捕获头后 cancel 并拒绝 body delivery。补充真实 pair-only 顺序/替换
以及 gate-open 语义/实际 CookieJar last-write 检查。commit+push 后重新运行两条 workflow。
旧 SHA 的 preview 因被替代取消，不作为完成证据。

P05a1a 验证：两条 workflow headSha 均为 `834c3b9e57c6acdc4619f1863c33fa3114ab34d7`。
实际产物 Swift 6.3.3 的 13 个 wire case/70 项检查通过，Dart 3.13.4 的 122 项检查与
analyze 无问题；HTTP 74/Search 63 通过。完整 Runner `BUILD SUCCEEDED`、677 项双语
检查及 FFmpeg load order 通过，四组 preview 全成功。视频压力报告 failures=[]，
1,000 评论懒加载/离屏不分页/末条分页通过，100,000 弹幕完整保留、活跃上限 60。
同值的两种 wire 输入实际证明 Foundation 丢失字段边界；Native gate 继续保守关闭。
生产 Client 尚未实现 head-before-body cancellation 写回，账户保护也尚未实施，
不能据此宣称登录或 Native HTTP 已迁移。详情见 [COOKIE_HEADERS.md](COOKIE_HEADERS.md)。

下一阶段 P05a1b 的 identity generation、存储所有权、匿名 reset、普通/临时选择及
真实 Hive/Dio 测试计划已保存到 REQUEST_CONTEXT.md；不改 Hive schema，不切换 HTTP。

P05a1b 范围：identity request stamp 与 snapshot revision 分开；显式安装/导入、全部持久
账户注册、当前 Hive owner 校验、同 MID 陈旧对象不能回写/删除、reset 期间禁止 capture。
Dio 首次绑定沿用到 retry/redirect，撤销后禁止再次发送；有效 A 在普通换号后仍写回 A。
用途继承和临时无痕语义保留；clear 在首次 await 前撤销全部 generation。无功能/资源删除。

首轮 a19fe5a 的 [release](https://github.com/Justintunsday/Piliglass/actions/runs/37167645743)
成功，19 个 Flutter 测试通过，但 [preview](https://github.com/Justintunsday/Piliglass/actions/runs/37167647429)
竖屏双击暂停断言失败。实际日志、附件/录屏确认未触发暂停；坐标正确、横屏通过，根因
未证明。补充生产 RetryInterceptor 与交错安装/reset 测试并修正两处 lint，commit+push
15a7f9d 后全量重跑。播放器生产代码和断言未改变，新结果两项测试均通过。

最终两条 workflow headSha 均为 `15a7f9de53871a39a1bbe3e94d8638a95c94a49b` 且全部成功。
下载实际产物：定向 analyze 无问题，72 项纯 Dart tracker 检查、22 个真实 Hive/Dio 测试；
Cookie wire 70/parser 122、HTTP 74/Search 63 继续通过。Runner `BUILD SUCCEEDED`、677
双语 keys 和 FFmpeg order 通过；视频报告 failures=[]，1,000 评论懒加载/离屏不分页/
末条分页通过，100,000 弹幕完整保留、活跃上限 60。Windows 静态检查未作为编译证据。

当前仍为 Dart 账户/HTTP/Hive runtime；中间 302 Cookie 的既有 RetryInterceptor 行为
未扩展，Native 取消/歧义 transport 未解决。详情见 ACCOUNT_REQUEST_STATE.md。
下一阶段 P05a2a 的 lease/薄命令及后续 Swift adapter/transport 切片已保存到
REQUEST_CONTEXT.md；保持 executionAllowed=false 后推进，尚不切换热榜请求。

P05a2a 范围：独立 Dart native_http service/严格 codec 与 bridge 三条薄命令；准备 actual
recommend/Dio/CookieJar 不可变快照、一次性 finish/abandon、generation owner 写回门禁、
pending 取消/TTL/数量限制/dispose。所有结果 executionAllowed=false，没有接入 Native HTTP。

338bc39 的 [release](https://github.com/Justintunsday/Piliglass/actions/runs/37179763783)
成功：actual accounts analyze 无问题，72 项 tracker 检查、60 个 Flutter/Hive/Dio 测试
（已有 22 + 新 lease 38），Cookie wire 70/parser 122、HTTP 74/Search 63；Runner
BUILD SUCCEEDED、677 bilingual keys 与 Aether FFmpeg order 通过。但同 SHA 的
[preview](https://github.com/Justintunsday/Piliglass/actions/runs/37179765343) 导航失败，
其他三组成功，因此阶段尚未完成。

实际 navigation.log、hierarchy 和录屏确认 testCurrentSettingsAndPersistentGestures
保存 toggle 后，边缘 pop 启动再取消，仍停留播放器设置；后续查设置入口派生失败。
末次合成 move/up 同时间戳、无停留，系统取消的唯一原因未证明。53705e9 仅将 harness
返回手势明确为快速拖到 95%/停留 0.2 秒，并在重开前断言设置页面出现；保留全部
持久化/真实手势断言，未改生产 UI、无重试或按钮 fallback。重新 push/dispatch 两条
workflow，等待真实结果。

53705e9 release 全部成功，实际产物再次确认 60 个 Flutter tests、72 tracker、wire 70 /
parser 122、HTTP 74/Search 63、Runner BUILD SUCCEEDED、677 bilingual keys 与 FFmpeg
order。preview 的 player/account/image 成功，但 navigation 又失败。这次失败在开关
value != 1 的等待（NavigationTests.swift:108），尚未执行 edgeBack，不能说 pop 修复已
验证或再次失败。actual AX frame 为 {{16,606},{370,52.3}}，合成 tap 为 (356.4,632.17)、
按下到抬手 0.05 秒；继续核对录屏和触控响应，阶段仍未完成。

录屏确认 tap 坐标位于实际开关白色滑块内，之后画面与 AX value 都保持开启；没有
触点叠层，不能证明 UIKit 收到事件或 VM/短触摸是唯一原因。仅将相同坐标的单次触摸
改为 press 0.15 秒，保留值变化、pop、重新进入后的持久化全部断言；无触摸重试、偏好
写入或生产改动。再次 commit+push+全量 CI，最终结论待实际结果。

最终两条 workflow headSha 均为 c0fbdbf8377cccfedc74020fe80e85d4a737828a 且全部成功。
实际导航日志确认 testCurrentSettingsAndPersistentGestures 通过，值变化、edge pop、重进
后持久化断言完整保留；这说明当前 fixture 通过，未证明两次系统交互失败的唯一根因。
release 日志 BUILD SUCCEEDED、677 bilingual keys 和 Aether FFmpeg load order 通过；
下载当前 SHA 产物 analyze 无问题、60 Flutter tests（新增 lease 38）、72 tracker、wire 70 /
parser 122、HTTP 74/Search 63。pressure failures=[]，1,000 评论懒加载/离屏不分页/末条
分页通过，100,000 弹幕完整保留、活跃上限 60。diff 无页面/资源/依赖/引擎删除。
本阶段 inventory 为 62 commands、62 Flutter routes、95 dependencies；Native HTTP gate
依然关闭，不宣称登录、Hive 或热榜网络已原生化。现在继续已保存的 P05a2b 计划。

用户已确认先继续本迁移计划，最后再重做 UI；原生玻璃风格与方案保存在 UI_REDESIGN.md
和 brand-spec.md，尚未实施 UI 重设计。P05a2a 全绿后继续 P05a2b。

## P05a2b：Swift 请求上下文与一次性终结

四个生产文件分别位于 Domain/Accounts、Data/Accounts 和 Bridge；新增不可变 Sendable
context、strict codec、临时 Dart provider 与独立终结任务。prepare 取消/坏回包按本地
UUID abandon；finish/abandon 在 await 前 claim，已取消 caller 仍实际发送终结。
未知/损坏/error ack 或 timeout 不重发，晚/重复 callback 不恢复 gate；最多 32 个
token-only records，显式 dispose 区分 pending/prepared/ending。详见 REQUEST_CONTEXT_SWIFT.md。

63dac5f 的 macOS Swift 6 complete fixtures 119 项全部通过，但 fixture 弱引用变量与
可变 provider 捕获有警告。4148caf 仅改 test 弱引用 holder/不可变 capture，保留实际
release 断言；再次 commit+push，两条 workflow 最终 headSha 均为
4148caf52de9cfefb4af56ed298c21cecb94717f，所有 8 个 jobs 成功。旧 run 不当完成证据。

已读取/下载当前 SHA 实际产物：context 119、HTTP 74、Search 63 检查通过；context
compile.log 无本阶段警告。完整 release BUILD SUCCEEDED，account 定向 analyze 无问题，
72 tracker 检查、60 Flutter/Hive/Dio tests、Cookie wire 70/parser 122、677 bilingual keys
及 Aether FFmpeg load order 通过。全部 preview 成功，压力 failures=[]，1,000 评论
懒加载/无离屏分页/末条分页通过，100,000 弹幕完整保留、活跃上限 60。

提交前 staged diff 检查通过，无业务/资源/依赖/引擎删除。runtime executionAllowed=false，
actual wire report 的 nativeAccountCompatibilityVerified 仍 false；没有接入生产 Native HTTP。
新 source 为 480 行，444 行 fixture（后修为 450）与专属 CI 构成同一生命周期切片，
没有往 Root/Player 追加业务。P05 整体仍需传输/有效 policy、Native 账户与存储、现有
登录/用途/签名和实际兼容验收。下一步已保存 REQUEST_CONTEXT_TRANSPORT.md 的 c1 计划。

## P05a2c1：实际传输与响应头终结

Networking 独立 transfer primitive 在共享 Session 上使用每 task delegate，锁保护
head/body/取消/完成顺序；任务、continuation 和 callback 在终结后释放。原 Client
薄封装保留 HTTPS、隔离 Cookie/凭据/cache 和拒绝 redirect。Data 的 HeaderFinalizer
只在无 head 或 unsupported 字段时 abandon，有效 head 即 finish 原 lease，包含
403、原 302、正文取消和断连；未知 ack 不重发或二次 abandon。没有接入生产请求。

首次 eddc20a 的实际 Swift 编译发现 fixture trailing closure 参数匹配及 async semaphore
问题，97b9aad 修复后发现 URLSession 会正规化测试 response subclass。c9f4144 将特殊
字段类型明确改为同一生产 factory probe，真实 loopback/普通 URLProtocol 仍走 delegate；
随后按 analyze 日志清除未使用 import。e440786 加强 redirect callback 内同步取消后，
release 全通过，但 preview 的设置 edge pop 启动再取消；实际 hierarchy/录屏确认
仍停在播放器设置，唯一原因未证明。d80c92b 仅将同一个完整边缘手势改为 slow，保留
单次触摸、真实返回和重进持久化断言；无重试、按钮 fallback 或生产 UI 改动。

最终两条 workflow headSha 均为 d80c92b6d5a4437e2a34186750373c4dc2c1738b，所有 8 个
jobs 成功。已下载实际报告与日志：91 transfer 检查（87 Swift + 4 wire 组），12 个
loopback 场景，实际头后/redirect 取消 -999、断连 -1005、安装前取消零请求、单次 head、
task/delegate 释放和共享连接 [9,9]；compile 无本阶段警告。context 119、HTTP 74、
Search 63、tracker 72、68 Flutter/Hive/Dio tests（新增真实字段写回 8）、wire 70/parser
122 通过，analyze 无问题。Runner BUILD SUCCEEDED、677 bilingual keys 与 Aether FFmpeg
load order 通过；导航 9 tests、设置手势与持久化通过，其他 preview 全成功。压力报告
failures=[]，1,000 评论懒加载/无离屏分页/末条分页、100,000 弹幕保留/活跃上限 60 通过。
当前手势测试成功不证明此前系统交互失败的唯一根因。

diff 无功能、资源、依赖或引擎删除，Root/Player/Aether 未改。特殊 raw 类型 probe 不当
作真实 wire 证据；Hive fixture 的 loopback 字段映射到已授权 API URL，仅证明 parser/
原 owner 写回，不证明旧 Cookie adapter 的重启属性持久化。Foundation 字段边界丢失
依然存在，nativeAccountCompatibilityVerified=false、executionAllowed=false，P05 整体
尚未完成。下一步执行有效 policy 描述计划；后续六组准备见 [PREPARATION.md](PREPARATION.md)。

## P05 Policy-1：实际 HTTP 配置描述

新增独立 effective_http_policy.dart 的 immutable DTO/identity tracker，Request 在
原有 pool factory 捕获启动协议、proxy 和 H1/H2 分别的 trust；所有替换 assignments
成功后发布 generation。失败/部分替换清空描述，保留上次成功代次；后续完整安装
才能恢复。实际 main/HTTP11 clone 的 BaseOptions 与已安装 RetryInterceptor 分别
读取，未改原 settings 默认值、连接池替换/吞错、重试或业务行为。adapter/factory/
manager/fallback 变化、未知 decoder 或多个/错误 client 的 retry 明确返回 issue。
DTO 不持有 Dio/账户/CookieJar；无 proxy 数据日志，不开放 Native 请求。

60817d7 首轮 [release](https://github.com/Justintunsday/Piliglass/actions/runs/37217729454)
的 17 个 policy tests 通过，4 个失败；actual pinned Dio.clone 源码和日志证明 clone
共享 BaseOptions，fixture 原独立假设错误。错误断言后未恢复 encoding，派生回环
失败/timeout；并有一个 unnecessary_lambdas info。62eab04 仅修 fixture 的共享语义、
finally 清理和 tearoff，把 policy analyze 增强为 fatal-infos 后重新 commit+push，
生产描述实现未为通过测试而改变。旧 preview 被替代取消，不作为阶段完成证据。

最终两条 workflow headSha 均为 62eab0494ddac4c4e1857dd9f9e77d3cce22cace，全部 8 jobs
成功。已读取实际产物：21 policy tests / analyze 无问题，三种独立冷启动、Pref 与
实际设置分离、pool/trust/失败/clone/共享 options 和实际 HTTP11 gzip 回环通过。
context 119、HTTP 74、Search 63、transfer 91、tracker 72、68 Flutter/Hive/Dio tests、
wire 70/parser 122 继续成功。Runner BUILD SUCCEEDED、677 bilingual keys 与 Aether
FFmpeg order 成功。preview 的账户 6/播放器 2/图片 3/导航 9 tests 均通过，设置边缘
返回及重进持久化断言保留；压力 failures=[]，1,000 评论懒加载/无离屏分页/末条分页、
100,000 弹幕完整保留/活跃上限 60 成功。

已检查 diff，无功能/资源/依赖删除，Root/Player/Aether 未改；inventory 继续 62 commands、
62 routes、95 dependencies，Aether 227 files/69,886 lines。该描述并非完整 endpoint
RequestOptions 或 Native transport parity：HTTP2/TLS/proxy/timeout/Brotli 实测与字段保存
transport 仍待实施，nativeAccountCompatibilityVerified=false、executionAllowed=false。
P05 整体继续进行。下一切片 [Policy lease/Swift codec](P05_POLICY_LEASE_PLAN.md) 已在
实施前保存；P10 下载/播放器与 P11/P12 runtime 退出准备也已补充到 PREPARATION.md。

## P05 Policy-2：绑定有效 policy 到 lease（已验证）

版本化不可变 prepared policy 已同步加入 Dart bridge 和 Swift strict codec/context。
合并 endpoint Options 后保留实际微秒精度、redirect=false、pool generation/模式、
retry presence、pool/trust/proxy、encoding/decoder。Cookie await 后复查有效输入与
内部回调 identity，变化则 snapshotChanged 消耗 pending，不自动重试；finish 原有
owner/generation 与 Hive 写回不受新 policy/用途选择变化影响。运行时两项门禁仍关闭。

新增真实 Dart/Hive/Request 冷启动 fixture 及 Dart bridge → Swift 6 production codec/
provider 的跨语言验证步骤；旧 context/transfer fixture 同步协议字段。完整 ios.yml
与全 ios-home-preview 在首轮提交时尚待实际运行；最终闭环证据见下文。没有删功能、资源、依赖或更改
Root/Player/Aether，也没有开始视觉 UI 重写。

首轮 6a7bd54 的 release 37237477468：analyze 无问题，Swift 6 context 119、HTTP 和
Search 独立 jobs 成功；Dart policy tests 31 通过/4 失败。两个重启 fixture 错误调用
Accounts.init 重新赋值 late final account；Box 已关闭又使后续 golden setup 失败。
修正为在独立冷启动进程的最后一项测试关闭/重开真实 Hive Box，直接检查磁盘反序列化
结果，不重新初始化 Accounts singleton、不改变生产账户生命周期。旧 preview 将由
同 SHA 全量重跑替代，不作为阶段闭环证据。继续保留实际重启原 owner 验证。

4e3ca53 的 release 37237971494：analyze 无问题，33 policy tests 通过/2 失败，16 个
真实 Dart bridge golden 已生成。重开 Hive 的断言发现 host-only Cookie 不在旧
adapter 的 bilibili.com 根 domainCookies 导出范围，此旧数据限制已在计划记录。
修 fixture 同时保存 parent-domain 根 Cookie 与 host-only Cookie：重启验证原 owner
保留前者、后者按旧 adapter 丢失且不进入其他账号。不修改生产 Cookie authority，
不宣称恢复旧 adapter 丢失的属性；再次提交推送完整 release/preview 验证。

最终代码 7192a0cfa54109c8746656f9052d1a28c9982e26 的
[release 37238360972](https://github.com/Justintunsday/Piliglass/actions/runs/37238360972) 与
[preview 37238363602](https://github.com/Justintunsday/Piliglass/actions/runs/37238363602)
headSha 相同，两条完整 workflow 的全部 8 jobs 成功；已下载并读取实际报告/日志。
35 policy tests（原 21 + 新 14）全部成功，analyze 无问题；16 个真实 Dart bridge/Hive/
Request cold-boot golden 经 Swift 6 production codec/provider 的 477 checks 成功，
编译无警告。旧 context 119、HTTP 74、Search 63、transfer 91/12 wire scenes、tracker
72、68 account tests、Cookie wire 70/parser 122 继续通过，账户 analyze 无问题。

Runner BUILD SUCCEEDED、677 bilingual keys 与实际 Aether FFmpeg load order 通过。
导航 9、账户 6、播放器 2、图片 3 tests 均零失败；原设置返回/持久化检查保留。
压力报告 failures=[]，1,000 评论懒加载/无离屏分页/末条分页，100,000 弹幕全保留/
活跃上限 60 成功。当前字段 DTO 与 callback 稳定性并不证明所有任意 interceptor/
transformer/status validator 的 Native 语义；后续 capability 必须限制或继续描述它们。

已检查 diff 无功能、资源、依赖删除，Root/Player/Aether 未改；inventory 保持 62 bridge
commands、62 registered routes、95 dependencies，Aether 227 files/69,886 lines。
旧 Hive host-only/path 属性丢失与 Foundation 字段边界问题仍未消除；两项 runtime/
account 门禁继续 false，P05 整体未完成。下一项
[Native policy 能力判定](P05_POLICY_CAPABILITY_PLAN.md) 和
[实际 transport 对照/有序字段验证](P05_TRANSPORT_PARITY_PLAN.md) 已在本轮 CI 期间保存，
其中长请求 lease ttl/head 时点风险有独立门禁；不提前移除 Flutter 或开始视觉 UI 重写。
