# Search：下一批迁移边界

2026-10-04：P02a UI 边界及 P03 Native state/Repository 边界已实施，
`7ff23b9` 的 Swift 6 严格检查、完整 Runner release 和全部 preview CI 通过。
Repository 当前仍使用 Dart adapter；HTTP 与 Hive 尚未切换。

## Feature 拆分（P02a）

保留 Root 的私有 `PiliNativeViewModel`。新增 `@MainActor`、继承
`ObservableObject` 的 `PiliNativeSearchViewState`，Search View 以泛型依赖该协议。
协议只声明搜索页面读取的 12 个属性、6 个搜索操作，以及
`openSearchVideo(_:sourceID:)` 导航入口。Root 转发导航到既有 `openVideo`；后者
还有默认的 `forceAutoplay` 参数，不能直接用两参数 protocol requirement 替代。

仅移动 Search UI、video bridge DTO、remote image、loading/error 与 transition
source 支持组件。避免为了拆分一个页面而暴露整个 ViewModel 及无关 DTO。
保持 iOS 16 baseline、布局、请求、分页、播放与 fallback 行为。

预览需要实际生产 Search protocol、泛型 View 与 fixture conformance；继续读取
生产文件，完整 Runner 编译负责发现独立文件导入、actor 与访问级别错误。

## Repository（P03）

Domain 定义独立的 `SearchRepository` 与不可变 `Sendable` 值：

- discovery：history、trending/recommendation keywords，四个 preference flags；
- keyword：keyword、reason、icon 字符串，保留当前 UI 未显示的服务端字段；
- video page：typed summaries、total、hasMore、requested page；
- video summary：稳定 sourceID、aid/bvid、title/cover/owner、当前展示文本；
- errors：bridge unavailable、invalid response/state、API failure code/message。

Flutter adapter 位于 Data，method invoker 位于 Bridge；只有 adapter 解码字典和
Flutter errors。Root/Feature 注入 Repository，不再直接调用搜索 channel commands。

契约来源：`lib/services/ios_native_ui_bridge.dart` 的 `_searchVideos`（1789）、
`_loadNativeSearchDiscovery`（1830）、`_loadNativeSearchSuggestions`（1871）、
`_updateNativeSearchHistory`（1899）。行号是本次审查时的定位参考。

- 视频第一页按设置在 HTTP 请求之前写历史，保留分页/dedup。Native 显式调用
  `recordHistory`，与 remove/clear 排序；视频调用传 `recordHistory: false` 跳过重复写入。
  旧 bridge caller 不传参数时继续原来的自动记录。权威开关仍由 Dart 的 add 操作检查。
- discovery 的两个网络分区独立失败时仍返回成功与空分区；保留开关/Hive 历史。
- 禁用联想或空词返回成功空列表；250 ms debounce 属于 Feature。
- remove/clear 不受历史记录开关限制；本阶段不替换 Hive 存储。

调用方须解决当前时序漏洞：query generation 处理重复词和 A→B→A；提交时取消
并失效待返回的联想；discovery/history mutation revision 防止清除后的历史回写。
record/remove/clear 使用统一队列，page one 等待自己的 record 结果，discovery 等待
已请求的写操作。clear 不等待视频 HTTP；历史保存失败时阻止本次 HTTP，保留原有
错误行为。视图关闭取消读取，已请求的持久化操作继续完成且不回写过时快照。
Swift Task 取消只丢弃 adapter 结果，现有 Dart transport 和已执行的历史副作用不能
因此撤销。若提前恢复 continuation，必须恰好恢复一次并忽略迟到 callback。

验证涵盖参数/错误/缺失 state、codec 混合数字与 null、乱序/取消、联想提交时序、
分页去重、历史设置与清除后的迟到结果，再通过 release 和全部 preview CI。

Bridge async 调用采用独立的不可变 `BridgeValue: Sendable` tree 与 MainActor invoker。
Flutter wrapper 在回调当前线程同步复制 codec 值、规范化 Flutter errors，再把 typed
result 传给 invoker；不跨 actor 传 `Any`，不使用 `@unchecked Sendable Any` 或回调线程
断言。Data adapter 转换为 Domain 值，Feature 不引用 bridge 类型。

每次请求有独立 MainActor completion box。调用前检查取消，安装 continuation 后
发送；完成/取消/重复/迟到 callback 通过同一个 terminal 门禁，清空 continuation
后恰好恢复一次；记录先于安装的取消。await 后再次检查取消。Swift 等待结束不能
撤销已经发出的 Dart 请求。Foundation fake 覆盖同步/后台/重复/迟到回调、取消竞态
和释放；生产核心以 Swift 6 complete concurrency checking 编译。

codec snapshot 先通过 CFBoolean 类型区分 NSNumber Boolean，再区分整数与浮点，
保留大于 `2^53` 的整数、空字符串和 null。Data coercion 再复现原有 `piliString/
piliInt/piliBool` 语义；测试 snapshot 后修改原始 NSMutable 容器不影响已捕获结果。
完整 Runner CI 负责实际 Flutter wrapper 的 SDK 类型、导入与注册验证。

## HTTP 切换的前置条件（P04/P05）

`lib/utils/accounts/api_type.dart` 将所有搜索 endpoint（包括 trending）映射到
`AccountType.recommend`。`lib/http/search.dart` 的 suggestions/video 请求依赖 WBI；
recommendations 依赖 app access_key/AppSign。匿名请求或主账户 Cookie 都不是等价替代。

trending 是最小候选 `GET /x/v2/search/trending/ranking?limit=10`，仍需匹配推荐账户、
headers、Cookie 域/路径、返回 Set-Cookie 所属账户。P04 可先验证 URLSession 和
trending fixture，不启用匿名运行时替换。先完成 P05 的最小 credential/context 边界，
再切换此 endpoint；测试过的解码器保持 N，不能据此宣称真实账户语义已验证。

P04a 已通过 `b0c098a` 的 Swift 6/74 项 HTTP fixtures、完整 release 和全部 preview。
运行时尚未切换；实现/证据见 [HTTP.md](HTTP.md)，下一阶段具体 lease 与 Cookie
generation/取消/响应头门禁见 [REQUEST_CONTEXT.md](REQUEST_CONTEXT.md)。

建议细分为 P04a（URLSession/decoder fixtures）、P05a（request-context lease）、
P04b（hybrid discovery 切换）。lease 绑定请求准备时的实际 recommend Account，
带不透明 ID 和单调 revision；响应 Cookie 写回原始绑定账户，包括非 2xx 响应。
finish/abandon 恰好释放一次；URLSession ephemeral session 禁用自动 Cookie storage。
租约保留 Dart 请求的重定向设置。允许重定向的请求在发送前交回 Dart，未支持的
代理和传输模式同样使用 Dart。

精确 pipeline 定位：`lib/http/init.dart:203`（base/timeout/headers）、
`lib/utils/accounts/account.dart:65`（账户 headers）、
`lib/utils/accounts/account_manager/account_mgr.dart:84`（按 URL 选 Cookie 与路径排序）、
`:185`（原始账户 Set-Cookie 写回）。不要使用 `BiliCookieJar.toJson()` 作为 snapshot，
它在 `account.dart:187` 扁平化域和路径。不要为 native 匿名请求另造 buvid。

目前没有可靠的 recommend-session revision。需要覆盖 `Accounts.set/refresh/clear/
deleteAll`、`login/controller.dart:629` 直接替换 `accountMode`、匿名 jar/buvid 更新；
MID 或对象 identity 无法发现凭据刷新和 A→B→A。切换前覆盖 recommend≠main、
重复/path Cookie、错误响应 Set-Cookie、换号/删除/刷新、取消不 fallback、lease 释放。
拆分旧 discovery 的数据供应，使 Native trending 成功时不再同时发送 Dart trending。

## 热搜分流切片

`loadNativeSearchDiscovery` 接受可选的 `includeTrending: false`。这时 Dart 继续返回
搜索历史、推荐和开关，跳过热搜请求。独立的 `loadNativeSearchTrending` 沿用相同的
热搜开关、推荐账号、查询上限和展示字段。

Swift 搜索仓库可以注入热搜加载器。加载器确认发出 HTTP 前放弃 Swift 路径时，
仓库才调用独立的 Dart 热搜命令。空结果、传输失败及取消均结束本次热搜。
Runner 默认使用聚合的 Dart 请求。Swift 6 搜索检查使用生产仓库和热搜解析器验证
各分流结果。

候选加载器通过现有租约和请求执行器发起热搜。直连传输收到完整正文并通过转换后，
Dart 向绑定账号写回响应头的 Cookie。Swift 解析正文后，重新读取推荐账号的凭据代次
再决定是否展示。
离线验收使用 Dart 桥接、Hive 和隔离账号生成的准备、终结与选择快照，验证正常
结果、换号、凭据替换、HTTP 错误、损坏正文和发送前回退。正式启用仍需确认实际
传输策略与真机账号行为。

### 直连 HTTP/1.1 候选

发送前检查使用热搜实际 API 请求的重定向设置和当时安装的 Dio 重试策略。默认配置
允许重定向并配置两次网络错误重试。直连 HTTP/1.1、默认证书验证的候选按实际微秒值
配置连接和接收空闲超时，复用同代次、同配置的连接池，并传入准备时的跳转和重试上限。
HTTP/2、代理、自定义发送或转换超时等组合在发送前继续交给 Dart。

Swift 传输包的 GET 可显式指定同源跳转次数。它对照初始请求的协议、主机和端口验证每个
目标，按字节上限读完中间响应，再把最终 URL、响应头和正文交给调用方。跳转次数耗尽、
目标重复或 Location 无效时结束请求。在回环测试中，固定版本的 Dart SDK 会跟随跨端口
跳转，同时剥离 Cookie 和 Authorization。Swift 会在向另一个端口发送前结束请求。

跳转后的最终响应携带每一跳的状态、原始 Location 和实际 URL。Swift 和 Dart 都按初始
请求的同源范围、准备时的跳转上限和最后一跳校验。Dart 仍由原推荐账户代次持有 Cookie
写回权，使用 Dio 现有的写回地址规则。多跳时，最后一个相对 Location 按初始请求解析的
写回路径可能与最终响应路径不同，回环和真实 CookieJar 测试都覆盖了这种情况。

最终 3xx 的写回使用原始、有序的 Location 字段。先写入 Dio 的主地址，再写入每个
同源 Location 对应的地址，全程持有同一次写回许可。每次写入后复查绑定账号的凭据代次，
最后统一持久化。Dio 按最后一跳的原始 Location 解析额外地址。末跳为相对引用时，
额外地址若缺少主机，候选会在写入前拒绝整个响应。既有 Foundation 直达响应仍沿用
主地址写回。

回环测试覆盖禁用跳转时的 302 和自动跳转后的 300，包含多个独立 Location 字段及字段内
逗号。

### 重试拦截器发起的同源跳转

Dio 重试拦截器可在连接层的自动跳转用完额度后再次发送请求，即使配置了零次网络错误
重试。再次发送的相对 Location 按当次 RequestOptions 的请求地址解析，并保留原查询参数。
Dart 在同一租约内按该规则生成 URL，核对响应链和同源范围，重读原推荐账号在目标路径的
Cookie，并合并上次请求的 Cookie 请求头。每次获准再发后，后续自动跳转上限减一。

Swift 等候有再跳转可能的响应完成正文转换。取消、正文损坏、凭据撤销或额外目标超出
同源范围会阻止下一次发送。中间响应的 Cookie 不写入。最终响应按最后一次请求的地址
写回。错误响应的 Cookie 写回次数与 Dio 逐层返回错误时一致，租约统一终结一次。回环和
跨语言测试覆盖相对目标含查询参数、成功、403、连续两次再跳转后收到 300，以及损坏正文
和撤销凭据。热搜运行时仍走 Dart，真机账号及完整传输行为待验收。

### 网络错误的重试候选

原生候选识别初次建连时明确的拒绝连接和连接超时，包括等待 TLS 握手用完连接期限。
对于 HTTP/1.1 GET，等待响应头时明确的对端关闭也可重试。若自动跳转后的下一跳在
交付响应头前关闭，重试从当次租约授权的请求地址开始，重新使用当次跳转上限。

重试次数和等待时间来自准备时捕获的 Dio 策略。默认两次分别等 500 和 1000 毫秒。
等待完成后，Dart 在同一租约内复查原推荐账号的凭据代次和请求策略，重读 Cookie 并合并
上次请求的 Cookie 请求头。凭据撤销、租约结束、策略变化或取消都会阻止再发。

回环测试核对拒绝连接、TLS 握手逾时、响应头未收完整时断线、等待响应超时及跳转后断线，
并从服务端记录实际发送次数。HTTP/1.1 候选还识别固定长度正文、分块正文和自动跳转的
中间正文截断，使用原租约重新授权并从当次请求地址重试。连接关闭作为正常正文结束、接收
超时和正文大小超限各有独立处理。

Raw 传输等正文完整且转换成功才写回 Cookie。截断尝试的 Cookie 不参与下一次发送，重试
额度耗尽或取消后释放原租约。完整的 200 和 403 都能完成一次终结写回。实际 Dio 回环使用
合成账号及 Hive 核对恢复、换号、次数耗尽和零次重试。Swift 契约检查验证同一额度内混用
建连和正文重试，保留既有 Foundation 响应头写回时点。

完整响应的 gzip、Brotli 或 JSON 解码失败使用同一重试额度。Dio 回环与 Dart/Swift
契约覆盖损坏的压缩帧、无效 JSON 和有尾逗号的 JSON。收到可转换的业务错误仍可写回
Cookie。超出本地正文大小上限和取消都不重试。

### Runner 真机试验入口

在 Xcode 的 Runner 启动参数中添加 `--pili-native-search-trending`，启动后从原生首页
打开搜索，加载接入 Runner 的热搜。无 Xcode 启动器的真机可使用单独签名的试验包，
仅在试验包的 Info.plist 将 `PiliNativeSearchTrendingTrial` 设置为布尔值 true。该包
在应用自身的临时目录记录最近的路由与请求结果，包含展现条数与有限错误类型。常规
包的普通启动使用原有 Dart 聚合入口。
试验仅接受已描述的直连 HTTP/1.1 策略。策略或客户端在发送前无法使用时，先确认租约
已放弃，再单独请求 Dart 热搜。请求发出后由同一条路径结束。

真机验收需要确认匿名及登录账号可展示与 Dart 一致的榜单，推荐账号与主账号分开时
读写正确的账号，换号或撤销凭据后没有旧榜单和越权 Cookie 写回。移除启动参数并重启
可对照 Dart 路径。完成真机验收前，普通启动仍使用 Dart。

## 其他搜索能力

Dart 完整搜索还支持综合、番剧、影视、直播、用户、专栏、筛选与风险校验恢复。
当前 native bridge 只有视频搜索；在这些能力得到原生对应前保留 Dart routes。
