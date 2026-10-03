# Search：下一批迁移边界

2026-10-04：基于 `9d9fb2f` 的代码审查，尚未实施或验证 Repository 切换。

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

- 视频第一页按设置在 HTTP 请求之前写历史，不能再写一次；保留分页/dedup。
- discovery 的两个网络分区独立失败时仍返回成功与空分区；保留开关/Hive 历史。
- 禁用联想或空词返回成功空列表；250 ms debounce 属于 Feature。
- remove/clear 不受历史记录开关限制；本阶段不替换 Hive 存储。

调用方须解决当前时序漏洞：query generation 处理重复词和 A→B→A；提交时取消
并失效待返回的联想；discovery/history mutation revision 防止清除后的历史回写。
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

建议细分为 P04a（URLSession/decoder fixtures）、P05a（request-context lease）、
P04b（hybrid discovery 切换）。lease 绑定请求准备时的实际 recommend Account，
带不透明 ID 和单调 revision；响应 Cookie 写回原始绑定账户，包括非 2xx 响应。
finish/abandon 恰好释放一次；URLSession ephemeral session 禁用自动 Cookie storage。
早期切片拒绝自动重定向，未支持的代理/transport 模式继续 Dart。

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

Dart 完整搜索还支持综合、番剧、影视、直播、用户、专栏、筛选与风险校验恢复。
当前 native bridge 只有视频搜索；在这些能力得到原生对应前保留 Dart routes。
