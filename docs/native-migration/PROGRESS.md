# 迁移进度与编译证据

最后更新：2026-10-04（Asia/Hong_Kong）。目标仍在进行，Flutter runtime 保留。

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
