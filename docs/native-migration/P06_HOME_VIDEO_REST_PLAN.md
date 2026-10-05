# P06：首页与视频详情 REST 迁移准备

> 2026-10-05 执行节奏更新：按用户最新要求，同组并行实施、各切片独立检查/提交/推送，整组汇合后统一运行 release 与全部 preview，并读取实际日志修复至成功。本文件旧有逐切片完整 CI 门禁由此替代；功能/数据验收、fallback 删除和权威切换门禁保留。见 [P05_GROUP_ACCEPTANCE.md](P05_GROUP_ACCEPTANCE.md)。

2026-10-04 编写，2026-10-05 复核；本文件是 PLAN.md 的 P06 准备切片，不切换运行时、不修改 UI、不移除 Dart。

Version Baseline：Runner iOS 16.0 / SWIFT_VERSION=5.0；AetherEngine swift-tools-version 6.0。新 Domain/Data 用 immutable Sendable；独立 fixture 以 Swift 6 strict-concurrency 编译，保留 iOS16 兼容，不引入 beta API。

## 已做与进入条件

- P03 SearchRepository/模型已验证 `7ff23b9`；P04a Client/trending decoder 已验证 `b0c098a`，运行时仍是 Dart Search adapter；不存在已完成的 HomeRepository/VideoRepository。
- P05 Dart lease `c0fbdbf`、Swift provider `4148caf` 已验证；当前 purpose 只允许固定 trending GET，`executionAllowed=false`，不能拿它发送下表的新 endpoint。
- P05a2c1 head/outcome/共享 Session/薄 HeaderFinalizer 已在 d80c92b 完整验证，Policy-2 lease/codec 已在 7192a0c 完整验证。新增 raw transport、capability、head-time executor 正在整组验收；不能以旧阶段成功证明新增实现已通过。字段保存与生产 policy/runtime 仍待验收，见 [P05_GROUP_ACCEPTANCE.md](P05_GROUP_ACCEPTANCE.md)。
- 可先做协议、Dart adapter、纯 DTO/参数/过滤 fixture；实际请求切换必须等 P05 的 policy、字段保留 transport、账户 lease、WBI/App 签名与多用途账户验收。每个新 endpoint 单独扩展白名单，禁止通用任意 URL lease。

## 当前入口与拟建边界

| 当前来源 | 实际责任 | Native 替代（全部拟建） |
|---|---|---|
| `lib/pages/rcmd/controller.dart`；bridge `requestSnapshot/refreshSection/loadMore` | 首页推荐的 Dart 列表状态，page 从0开始；按 `appRcmd` 选 App/Web REST | `Domain/Home/PiliHomeRepository`；`Data/Home/PiliFlutterHomeRepository` 先封装现有命令；后续 `PiliNativeHomeRepository` |
| Root `applyHome/refresh/loadMore/prewarmHomeFirstVideoIfNeeded` | Swift 展示状态、首卡预热、最后一项触发分页 | `Features/Home/PiliHomeModel` 持有展示/任务/请求代次；Root 只组合和导航，保留既有 UI |
| bridge `loadVideoDetail/loadVideoDetailExtras/loadRelatedVideos` | 核心简介与可选元数据分开；详情预加载/缓存、相关推荐 | `Domain/Video/PiliVideoRepository`；`Data/Video/PiliFlutterVideoRepository` 先适配；再按方法替换 Native Service |
| `Native/Bridge/Models/PiliNativeVideo.swift`；Root 私有 Detail/Part/Tag/Staff | bridge 字典→展示文本，sourceID 与 UI id 分离 | Domain `PiliVideoSummary/Detail/Part/Tag/Relation` + Data Codable DTO + Feature mapper；格式化不进 HTTP client |
| `http/video.dart`、`http/user.dart`、`http/api.dart`、账户 interceptor | endpoint/参数、签名、账户用途、响应 envelope、过滤 | `Data/Home`、`Data/Video` 专属 Service 注入 Client/账户执行器/Signer；SwiftUI 不构造请求 |

Home adapter 的初期接口表达读取/刷新/下一批快照，不把现有 Dart 累积列表伪装成服务端分页响应。现 bridge 没有 home hasMore/cursor 字段；新增元数据须独立契约验证，不能从 UI 列表长度猜 fresh_idx。
网络解码/过滤不放 MainActor；Feature 更新在 MainActor，刷新/隐私模式/账户变化用请求代次阻止旧结果覆盖。缓存 key 后续必须纳入用途账户 generation/选择 revision、请求参数与过滤模式。

## REST 映射与必须保留的请求契约

除 App 推荐外均以 `https://api.bilibili.com` 为基址，全部为 GET。purpose 来自 `utils/accounts/api_type.dart` + `account_manager/account_mgr.dart::_findAccount`；`extra.account` 显式覆盖优先，未列入用途表的 endpoint 默认 main，不能统一绑定 main 或 video。

| Dart 函数 / endpoint | 参数、签名与用途 | 拟建 Service → DTO/Domain |
|---|---|---|
| `VideoHttp.hotVideoList` / `/x/web-interface/popular` | `pn,ps`（controller 从1、ps20）；无 WBI；recommend | `PiliPopularService` → `HotVideoDTO`/Summary；`data.list` |
| `getRankVideoList` / `/x/web-interface/ranking/v2` | WBI `rid,type=all`；recommend | `PiliRankingService` → `HotVideoDTO`/Summary；`data.list`；不新增已注释的 others |
| `pgcRankList` / `/pgc/web/rank/list` | WBI `day=3,season_type`；recommend | 独立 PGC Ranking Service → `PGCRankDTO`；`result.list` |
| `pgcSeasonRankList` / `/pgc/season/rank/web/list` | WBI 同上；recommend | 同 Service 不同 decoder；`data.list`，不能套 UGC envelope |
| `popularSeriesList/One` / `/x/web-interface/popular/series/list,one` | WBI `web_location=333.934`，One 加 number；PC UA/origin/weekly referer（One 含 num）；recommend | `PiliWeeklyService` → SeriesList/Config/Reminder/HotVideo DTO；保留首期默认选择 |
| `popularPrecious` / `/x/web-interface/popular/precious` | WBI `page_size=100,page,web_location=333.934`；PC UA/origin/history referer；recommend | `PiliPreciousService` → Precious DTO（list/media_id） |
| `rcmdVideoList` / `/x/web-interface/wbi/index/top/feed/rcmd` | WBI `version=1,feed_version=V8,homepage_ver=1,ps=20,fresh_idx,brush=fresh_idx,fresh_type=4,disable_rcmd`；recommend | `PiliWebRecommendationService` → WebRcmd DTO/Feed；`data.item` |
| `rcmdVideoListApp` / `https://app.bilibili.com/x/v2/feed/index` | 全部 params/headers 保留 `video.dart:91–168`；`idx=freshIdx,pull=(idx==0),disable_rcmd`；recommend 的 access_key + interceptor AppSign；App 不管理 Cookie | `PiliAppRecommendationService` → AppRcmd DTO/Feed；`data.items`，不得改成 Web 请求 |
| `videoIntro` / `/x/web-interface/wbi/view` | WBI `{bvid}`；heartbeat（不是 main/video） | `PiliVideoDetailService` → VideoDetailDTO/Detail；`data` |
| `UserHttp.videoTags` / `/x/web-interface/view/detail/tag` | `{bvid,cid?}`；main；bridge 当前只传 bvid | `PiliVideoTagsService` → VideoTagDTO/Tag；`data` 可空列表 |
| `videoRelation` / `/x/web-interface/archive/relation` | `{aid=IdUtils.bv2av(bvid),bvid}`；main；仅 main 登录时 bridge 请求 | `PiliVideoRelationService` → RelationDTO；bool 状态 + num coin，不以缺失状态推断未点赞 |
| `relatedVideoList` / `/x/web-interface/archive/related` | `{bvid}`；recommend；无 WBI | `PiliRelatedVideoService` → `[HotVideoDTO]?`/Summary；`data` 可空，保持服务端顺序 |
| `HomeController.querySearchDefault` / `/x/web-interface/wbi/search/default` | WBI `web_location=333.1365`；recommend；失败静默保留旧值 | 后续 SearchRepository defaultWord 能力；不混入 feed HTTP |
| `onlineTotal` / `/x/player/online/total` | `{aid?,bvid?,cid}`（至少一个编号）；heartbeat；返回字符串 total | 后续视频外围 `PiliVideoPresenceService`，独立小切片 |
| `aiConclusion` / `/x/web-interface/view/conclusion/get` | WBI `{bvid,cid,up_mid?}`；heartbeat；嵌套 `data.code==0` 才成功 | 后续 `PiliVideoConclusionService` → AI DTO；嵌套错误 code 单独保留 |

App 推荐不能省略 `build=8430300,mobi_app=android_i,platform=android,statistics=Constants.statisticsApp,fnval=976,fnver=0,fourk=1,force_host=2,qn=32` 或 buvid/fp/session/env/app-key/trace 等 headers；参数中的空字符串、布尔值和签名编码按现有 AppSign 对照，不以 URLQueryItem 默认行为替代。
WBI 必须保留时间/key cache、参数过滤/排序/编码；先复用 P05 独立 signer 与用途快照，不能在 Service 自建登录态、匿名 buvid 或全局 Cookie。

## 响应、过滤与状态兼容

- 原 `Request.get` 仅接受 2xx，DioException 转成 `{message: AccountManager.dioError}`；多数上述方法只检查 `code==0`，失败保留 message，原 code 常未外传。Native 错误分 transport/HTTP/API/decoding，界面 mapper 保留当前提示和可重试语义，不能把非2xx解析成成功或虚构 API code。
- 先按响应 head 完成原账户 Cookie lease，再判断正文/HTTP/API；收到头后的取消/断连仍需终结；未知 ack、取消或已发送后的表示错误不得再发 Dart 同请求。unsupported 必须发送前选 Dart，发送后失败明确返回。
- Web 推荐只保留 `goto=av`、有 owner、非 blackMids，再跑 RecommendFilter；App 排除 ad_av/ad_web_s/ad_info、要求 can_play=1/args、分区词过滤，再用 App DTO 与 RecommendFilter。
- `RecommendFilter` 的时长/播放/赞比/标题词、已关注豁免必须逐值对照；App 的“已关注/新关注”来自推荐原因，不能丢。Hot/rank 的 filterLikeRatio 同时检查最低播放数，不额外套最低时长；related 仅在 applyFilterToRelatedVideos 时 filterAll，没有已关注豁免。
- 过滤快照取实际 mutable static 状态：RecommendFilter 的 minDurationForRcmd/minPlayForRcmd/minLikeRatioForRecommend/exemptFilterForFollowed/applyFilterToRelatedVideos/rcmdRegExp/enableFilter，以及 VideoHttp.zoneRegExp/enableFilter；只导出 Pref 不能证明当前有效过滤策略。HV2 必须对照这份实际快照。
- Rcmd 从0分页，成功非空页才推进；CommonListController 对成功空页提前返回，后续仍请求原 page；isEnd 始终 false。refresh 默认可追加旧 feed（旧列表>200只保留50），错误可保留旧数据；personalizedRcmd 改变时暂禁保留旧 feed。不要强行用空页永久终止推荐、去重所有重复项或改变保留策略。
- DetailDTO 按 `models_new/video/video_detail/data.dart` 保留 aid/bvid/cid、pages、完整 ugcSeason sections/episodes/arc、staff、rights/desc_v2、dimension、argue_info、season_id/upower/redirect_url，不能只保存当前 Swift 可见标题。
- fast=true 核心简介不能等待 tags/relation；extras 失败仍可播放，relationLoaded 区别未加载与 false。保留 videoDetailGeneration、videoActionRevision，迟到 extras 不覆盖点赞/投币/收藏。
- 保留 BV/AV 互转、title/cover fallback、首 cid/page 的选择、反转分P/合集和 PGC redirect 路由；Dart UgcIntroController 的行为仍需覆盖，即使当前 Swift Detail 未显示某字段。
- bridge 当前详情/播放预热共享 dedup、成功缓存 TTL30分钟/最多48项，refresh=true 清详情缓存且失败不缓存；首次点击与首卡预热不能导致重复业务请求，sourceID 与带 index 的展示 id 不混作 API 编号。

## 可独立回滚的实施顺序

| 切片 | 交付与状态 | 实际验证 / 切换前置 |
|---|---|---|
| P06-HV1 | 待做；窄 Home/Video Domain 协议、Dart adapters、Detail/Part/Tag/Staff 移出 Root；保留 UI/原命令、原状态 owner | strict Swift 6 bridge DTO/error fixture；首页刷新/末项分页、快速切视频、extras/action race 与现有 preview；不增加 Native 请求 |
| P06-HV2 | 待做，可独立推进；分批纯 REST DTO/Domain mapper、参数 builder、RecommendFilter policy snapshot | 脱敏固定 JSON 同跑 Dart 原 model 与 Swift decoder；nullable/错误类型/coin num/PGC result-vs-data、参数全集和签名 golden；每次只一组 DTO |
| P06-HV3 | 待做；先 hot 单 endpoint，随后 rank/weekly/precious 每组独立提交；功能路由仍完整保留 | P05 门禁+recommend purpose；URLProtocol 请求/HTTP/API/错误/取消、真实访客及 recommend≠main 账户对照；只该 endpoint 开关 |
| P06-HV4 | 待做；videoIntro 核心 → tags → relation → related，每步独立提交 | 各自 heartbeat/main/recommend lease；多P/合集/缺cid/PGC redirect、可选元数据故障、换号、动作后 refresh、预热去重；关联失败不阻止播放 |
| P06-HV5 | 待做；Web 推荐，再 App 推荐分别迁移；保持 appRcmd/privacy/过滤配置原选择 | Web WBI/App access_key+签名+headers golden；第一页/后续页、旧 feed 保留、关闭个性化不混数据、blocked/低赞比/未知卡、实际账户对照 |
| P06-HV6 | 待做；presence/AI 与 PGC 排行按需独立迁移；最后审核各方法旧 caller | 嵌套 API code、账户登录限制、番剧/影视/课程路径；未完成领域继续 Dart，不能据 UGC REST 成功删全 video.dart |

每行是阶段组，不是一份大 commit；组内 endpoint/方法各自 diff→commit→push→Actions。HV1/HV2 可在 P05 网络门禁等待时实施，HV3–HV6 不得抢先切换。回滚单切片 `git revert <sha>` 恢复 composition 的 Dart 选择；保存 fixture、run URL/SHA/日志。
实现阶段接入 `ios.yml` 的生产源 Swift 6 checks，并保持完整 Runner release 与 `ios-home-preview.yml` 的 home/navigation/player/account/image 全部同 SHA 成功；失败读取实际日志、修复、commit/push 重跑。文档或 Windows skip 不算业务验证。
fixture 不能只检查新实现自洽：对照原 Dart 参数/过滤/错误 fixture，真实 API 与多用途账户只做单路顺序对照，不在生产同时请求两实现；脱敏日志不含 Cookie/access_key/signing secret。

## 2026-10-06 首个热门 REST 切片复核

HV2/HV3 首候选仍为 `hotVideoList`，不替换当前 rcmd 首页或删除入口。
真实 oracle 调用 VideoHttp、HotVideoItemModel、RecommendFilter 与 Hot/CommonList
controller，仅 stub Dio adapter 并记录请求；不能复制过滤算法生成期望值。

- Hot 对成功的**过滤后空列表**才结束且不推进 page，短非空页继续。与上面 rcmd
  的 `isEnd=false` 政策分开，不以 `count<20` 编造服务端 hasMore。
- 黑名单检查发生在原 JSON `owner.mid` 上，早于 Owner.safeToInt；wire string/int
  MID 的差异须保留。热门不应用最低时长或已关注豁免，赞比/最低播放的严格边界
  使用实际 mutable filter snapshot。用户 RegExp 未对齐时保持 Dart 处理。
- DTO 保留完整字段、charging_pay→cooperation→pgc_label badge 优先级和 num coin；
  必需类型错误显式失败，不变成成功空页；保留重复 bvid 与服务端顺序。
- actual fixture 至少覆盖空原页/全过滤/短非空、MID string/int、like/view 的
  null/负值/零/阈值等号、badge/coin小数、403正文code0、解码错误与实际取消。

其他领域的新增核对：Profile 卡片实际为 App `/x/v2/space`、main+AppSign；
Library history 显式使用 Accounts.history，即使入口要求 main 登录也不能换用途。
Comments 主列表优先 gRPC、失败才 REST，二级回复只有 gRPC；P06 先建接口与
fallback 边界，完整主路径仍属 P08。Dynamics 保留递归 offset 与发布/转发后的
计数、刷新、关闭 composer 副作用。Home/Video 的展示代次还须包含原 owner
generation，不能只比较 MID/bvid；原预热、TTL/inflight 与 action revision 分开。
这些均为准备约束，尚无上述六域 Native Repository 或实际业务 golden 验收。

## 保留的路径与模块界限

当前首页没有在用的推荐 gRPC：`GrpcUrl.popular`、`GrpcReq.popular` 都是注释；`ViewGrpc.view` 是 wrapper，PGC controller 引用也被注释。保留 `lib/grpc`/protobuf 的全部现有路径，后续 P08 按真实 caller 迁移，不能宣称已迁移首页 gRPC，也不能删 schema。
首页 live/bangumi/cinema、热门/分区/每周/入站必刷与原 Web/Dart 页面继续可达；不把无 Native 对应的路径改成热门替代或空入口。
UGC/PGC/PUGV playurl、字幕 playInfo/getSubtitles、弹幕/评论、点赞/投币/三连/收藏/关注/历史上报、下载/投屏/音频/后台仍走现有实现与专属后续阶段；读详情成功不构成删除这些功能的条件。
playInfo `/x/player/wbi/v2` 当前默认 main，playurl/vide shot 等是 video 用途；字幕 CDN 有既有 _skipCookie 规则，不能沿用 detail 的 heartbeat Cookie 发送到 CDN。播放请求保留 qn/fnval4048、PGC/PUGV envelope、试看/语言及 UGC→PGC fallback，禁止用 TV URL 简化丢掉 DASH/4K/HDR。
AetherEngine 仅消费播放输入与核心控制 API；Home/Video Repository、HTTP、账户、字幕/弹幕业务留在 Runner Data/Player orchestration，不导入播放器包；本准备切片不改 Aether。

## Skills 与决策复核

应用 [ios-engineer](https://github.com/i-stack/ai-coding-kit/blob/main/skills-engineering/ios-engineer/SKILL.md)、[swift-architecture](https://github.com/dpearson2699/swift-ios-skills/blob/main/skills/swift-architecture/SKILL.md)、[swift-concurrency](https://github.com/dpearson2699/swift-ios-skills/blob/main/skills/swift-concurrency/SKILL.md)、[ios-networking](https://github.com/dpearson2699/swift-ios-skills/blob/main/skills/ios-networking/SKILL.md)：逐领域 strangler、状态所有权/依赖注入、可取消读取、不可变跨域 DTO、HTTP/API 双验证和可执行回滚。现有 head/Cookie 要求继续 delegate-based transfer；不套用示例 Bearer/401 刷新或新增自动重试覆盖本项目协议。
**复述：** 先建立可测试 Home/Video REST 边界，逐 endpoint 验证后切换核心数据供应。
**最强反驳：** 现有 `ApiType` 把详情分给 heartbeat、related 分给 recommend；同时 Foundation wire 已证明 Cookie 字段不可逆合并。只搬相同 URL 仍会用错账户或丢响应 Cookie，因此当前不能切换。
**隐藏假设：** 用途与签名可精确复现（必要，匿名/多账户不符即失效）；transport 可保留 Cookie/policy（必要，歧义或代理不符即失效）；原始模型可对照（必要，只有扁平 UI 快照不足）。
**失效条件：** 错账户请求、关闭个性化混入旧推荐、分P/PGC redirect 丢失、迟到关系覆盖动作、重复发送或 CI 失败。
**可证伪条件：** 同 fixture 请求/过滤与 Dart 不同；多用途实际账户返回或写回不同；任一受保护路径在同 SHA preview/设备验收回归。
**立场翻转：** 选择协议与离线 DTO 先行；若 gate/对照不成立，保留该方法 Dart 供应并修边界。
**迎合自检：** ☒ 最强反驳充分；☒ 未稀释否定结论；☒ 未因用户自信降低审查；☒ 置信度有源码证据。
**置信度：85%**（限于入口/参数/用途映射，依据实际 controller、api_type 和 bridge；实际网络等价不确定）；若降至65%，需要发现未盘点的真实 caller、不同有效 interceptor 参数或 DTO 对照失败。
**结论：** 本文件仅证明准备范围与执行门禁清晰；实际 Native Home/Video 业务仍待实施、同 SHA CI 与账户/API 对照验证。
