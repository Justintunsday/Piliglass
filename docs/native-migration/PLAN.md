# PiliGlass 原生迁移执行计划

日期：2026-10-03（Asia/Hong_Kong）。起点：`8044a8d`，在现有 SwiftUI frontend 分支的功能基础上建立 `codex/native-migration`，不丢弃既有 179 个未进入 main 的提交。目标是 iOS 完整业务原生化；其他平台的处置不作为移除 iOS fallback 的理由。

## 版本与验证基线

Version Baseline：Runner `IPHONEOS_DEPLOYMENT_TARGET=16.0`、`SWIFT_VERSION=5.0`；Podfile iOS 16；AetherEngine swift-tools-version 6.0。新模块按当前兼容范围实现；Swift 6 严格并发分模块启用，不在结构整理时同时抬高部署版本。

基线 release [36085475142](https://github.com/Justintunsday/Piliglass/actions/runs/36085475142) 成功；preview [36085470278](https://github.com/Justintunsday/Piliglass/actions/runs/36085470278) 失败，实际日志指向 `paginationStillWorksAtEnd`。其余账户、图片、播放器 UI job 成功。这些是起点证据，不代表本次迁移完成。

Windows 无 Xcode；本地检查仅作为提交前检查。阶段完成必须有当前提交的 GitHub Actions iOS release 和相关 simulator job 成功。编译通过不能替代登录账户、真实网络及设备后台行为验收。

## 当前架构与数据流

- `SceneDelegate: FlutterSceneDelegate` 将 Flutter 根控制器包在 `PiliNativeRootViewController`；`AppDelegate: FlutterAppDelegate` 注册 implicit engine plugins。`PiliNativeContainerViewController.m` 是保留的 Objective-C UIKit/Flutter 兼容容器。
- `PiliNativeRootViewController.swift` 约 10,100 行：宿主、Flutter surface、MethodChannel、一个跨所有 feature 的 `@MainActor ObservableObject`、字典模型、导航、所有 SwiftUI 页面、富文本、图片加载、设计样式与 codec helper 混在同一文件。
- `PiliNativePlayer.swift` 约 3,590 行：日志、HTTP range IOReader、播放 DTO、弹幕设置/规则/缓冲/绘制、偏好、session、UIKit controls 与 SwiftUI representable。session 使用 AetherEngine；URL、字幕、弹幕、进度上报等业务仍经 Dart 获取或处理。
- `lib/services/ios_native_ui_bridge.dart` 约 150 KB：MethodChannel 分发，HTTP/gRPC 调度、序列化、预加载/缓存、账户/设置/下载/页面 fallback。bridge 自身已是第二个业务聚合器。
- `lib/http/init.dart`：Dio singleton、HTTP/2 与 HTTP/1.1 fallback、gzip/Brotli、连接变化、代理与重试。`http/api.dart` 是 REST endpoint 注册表。
- `utils/accounts.dart` / `accounts/account_manager`：main/video 等用途账户、CookieJar、Cookie path 排序、CSRF、AppSign、gRPC metadata 与 buvid 激活。不能简化为一份全局 Cookie。
- `lib/grpc/grpc_req.dart`：Dio HTTP/2 上的 5-byte gRPC framing、gzip、protobuf response 与 grpc-status-details-bin；`grpc/bilibili/**` 是生成的 schema 数据。需要保留 wire format，而非用 REST 替换全部 RPC。
- `lib/tcp/live.dart`：目录名为 tcp，现有传输实际使用 WebSocketChannel；包含直播包头、认证、30 秒心跳、zlib/Brotli 多消息解包与关闭生命周期；私信另有 HTTP/gRPC 会话及未读状态。迁移需要按实际协议而不是目录名选 transport。
- `lib/models`、`models_new`：手写/生成 JSON、protobuf 与 Hive adapters；`lib/pages/**` GetX controllers 持有分页、筛选、风控校验和操作语义，不能只迁移 HTTP endpoint。
- `utils/storage.dart` 的 Hive boxes 包含 userInfo/localCache/setting/historyWord/video/watchProgress/reply，账户 adapters 及下载 entry/index JSON 有独立兼容要求。
- `services/download`：队列、HTTP range 恢复、视频/音频、弹幕、entry/index 文件与进度节流；`audio_handler` / `audio_session` / `shutdown_timer_service` 承载后台播放、媒体控制和定时行为。
- `Packages/AetherEngine` 已有 Swift playback、FFmpeg/custom AVIO、CoreMedia/VideoToolbox 与独立 tests；不得导入 Runner feature、Bilibili API、Flutter 或业务 storage。保留当前 FFmpeg 链接顺序检查。

## 目标边界

```text
SwiftUI / UIKit Feature
  -> @MainActor Feature State / Model（复杂展示才引入 ViewModel）
  -> Domain Repository protocols + immutable domain values
  -> Data repositories（Native 实现或有删除条件的 Dart adapter）
  -> Networking / Persistence / Objective-C compatibility services

App composition -> Bridge（唯一 Flutter SDK / codec / legacy route 边界）
Player presentation -> Player orchestration -> AetherEngine public playback API
Player orchestration -> Playback / Subtitle / Danmaku repositories
```

目录落在 `ios/Runner/Native/{Features,Domain,Data,Networking,Persistence,Player,Bridge,DesignSystem}`。以真实责任逐批建目录，不添加空模块或全能 manager。共享 domain 模型不依赖 SwiftUI、Flutter、GetX；普通网络与解码不在 MainActor；UI 状态在 MainActor。与 ObjC/FFmpeg 的底层兼容可用 ObjC/ObjC++，新业务优先 Swift。

## Migration map 与领域状态

状态：D = Dart 业务；B = 协议边界+桥接实现；N = Native 实现待行为验收；V = 原生实现验证完成；R = 旧依赖可删除。原生 UI 已存在不等于业务 N。

| 领域 / Dart 来源 | Native 替代组件 | Feature / 状态 | 必须验证 |
|---|---|---|---|
| `http/init,retry_interceptor,constants,api` | URLSession client、Endpoint、ResponseEnvelope、RequestPolicy | Networking / D | HTTP 状态/API code、gzip、超时、取消、幂等重试、HTTP2 |
| `utils/wbi_sign,app_sign,accounts/grpc_headers` | WBI/App signer、RPC metadata builder | Networking/Auth / D | 固定输入签名一致、时间/key 更新、头和二进制 metadata |
| `http/login,user`、`utils/accounts,login_utils`、account_service | AccountRepository、AuthService、AccountSession actor、KeychainCredentialStore | Login/Account / D | QR+密码/SMS/网页校验已有路径、刷新/注销、多用途账户隔离 |
| `http/video`、`pages/rcmd,home,hot,rank,popular*` | HomeRepository、FeedService、VideoSummary | Home / D | 原推荐来源、分页/筛选、访客/账户、去重/预加载 |
| `http/video,pgc`、`grpc/view,audio`、`pages/video,pgc,audio,music` | VideoRepository、PlaybackRepository、VideoDetail/PlaybackManifest | Video/Player / D | 分 P、合集、番剧/课程/音频、清晰度、音轨/字幕、动作 |
| `http/reply`、`grpc/reply`、`pages/main_reply` | CommentRepository、Comment/Thread、ModerationPolicy | Comments / D | 热门/最新、分页、回复/点赞/发布、图片/表情/提及/链接 |
| `http/dynamics`、`grpc/dyn,space`、`pages/dynamics*` | DynamicRepository、DynamicService、Dynamic/PostDraft | Dynamics / D | feed/detail、转发、图文/文章、投票/预约、草稿/发布 |
| `http/member,follow,black`、`pages/member*,follow*,fan,blacklist` | ProfileRepository、RelationshipRepository、Member/Relationship | Profile / D | 多内容 section、关注/黑名单、签名、用户分页、隐私/风控 |
| `http/fav,user`、`pages/fav*,history*,later*,subscription*` | LibraryRepository、Favorite/History/WatchLater repositories | Library / D | 文件夹/排序/批量操作、历史续播、订阅、账号切换 |
| `http/search`、`pages/search*`、Hive historyWord | SearchRepository、SearchService、SearchHistoryStore | Search / D | discovery/suggest、全部搜索类型、分页、筛选、风控、历史 |
| `http/msg`、`grpc/im`、`pages/contact,group_panel` | MessageRepository、IMService、MessageSync actor | Messages / D | 会话/未读、通知、图片/发送/撤回、置顶/删除/屏蔽、重连 |
| `http/live`、`tcp/live`、`pages/live*` | LiveRepository、LiveService、LiveSocketClient、PacketCodec | Live / D | 房间/分区/关注/搜索、鉴权/心跳/压缩/重连、直播播放/弹幕 |
| `http/danmaku,danmaku_block`、`grpc/dm`、`utils/danmaku_utils` | DanmakuRepository、RPC codec、RuleStore | Danmaku / D（绘制 Native） | 所有 mode、分段/预取、合并、规则隔离、发送/举报/撤回 |
| `services/native_danmaku_settings`、`storage_pref,key`、`pages/setting*` | SettingsRepository、PreferenceStore、SettingsImportService | Settings / D（部分播放偏好 Native） | 类型/默认值、按账户配置、导入导出、旧文件不丢失 |
| `models,models_new`、JSON/Hive adapters | Codable DTO -> Domain mapper、VersionedStorageMigration | Domain/Persistence / D | 缺失/可空/混合数值、缓存版本、备份/回滚、旧 box 导入 |
| `http/download`、`services/download`、`models_new/download` | DownloadRepository、BackgroundTransferService、DownloadIndexStore | Downloads / D | range/416、暂停/重启、双流/字幕/弹幕、本地播放、后台恢复 |
| `audio_handler,audio_session,shutdown_timer_service` | PlaybackCoordinator、RemoteCommandService、AudioSessionService、SleepTimer | Player / 混合 | 中断/耳机/后台、Now Playing、计时、横屏/PiP/seek |
| `native_playback_source,native_cdn_latency`、sponsor_block、DLNA | PlaybackSourceRepository、LatencyProbe、SponsorBlockService、CastService | Player peripherals / D | 原线路偏好/测速、跳段、投屏与离线/慢网 fallback |
| `router/app_pages`、`pages/article*,webview,webdav,login_devices,login_log,log_table,coin_log,exp_log,match_info,emote,share,...` | Feature route registry、WKWebView/Native utility features | Remaining routes / D | 自动盘点所有 route；逐条有 Native 对应与导航验收后删旧页 |
| `ios_native_ui_bridge`、AppDelegate/SceneDelegate、Podfile、Flutter build phases | Composition root、Native app lifecycle、仅 Native build workflow | Runtime / 保留 | 零 core bridge 调用、全 route 验收、插件替代、冷启动/深链/IPA |
| `Packages/AetherEngine` | 保持独立引擎；Runner 只通过 playback API 使用 | Engine / Native | 真正 iOS 链接、FFmpeg 顺序、engine tests、AVIO seek/取消 |

完整文件、业务函数、endpoint、bridge command、Flutter route 和依赖清单由 `tool/native_migration_inventory.py` 生成到 `build/native-migration/`。它是导航索引，具体切换前仍必须逐函数阅读业务和错误路径。每个尚未映射的 route/command 是 runtime 删除门禁。

## 阶段与提交边界

| 阶段 | 可回滚交付 | 进入下一阶段的门禁 | 状态 |
|---|---|---|---|
| P00 | 本计划+可重现 inventory；修复现有 preview 分页失败；扩充迁移目录 workflow path | 同一 SHA release+preview 成功 | 已验证 ad0e8b5 |
| P01a | 提取 Flutter player surface、诊断日志/HTTP range reader | 类型正文一致、iOS release+全 preview | 已验证 c783318 |
| P01b | 提取 DesignSystem、Bridge codec；同步 preview 源读取 | 行为正文对照、iOS release+全 preview | 已验证 9d9fb2f |
| P02a | 以专属状态协议拆出 Search（见 SEARCH.md）与跨文件共享支持组件 | 行为正文/fixture contract 对照、完整 iOS release+preview | 已验证 662f739 |
| P02b | 分批拆 Home/Account、DTO 与播放器控制/弹幕组件 | 导航/生命周期/布局回归和 iOS release | 待开始；按领域接口切片穿插推进 |
| P03 | SearchRepository、typed result、可取消 bridge、独立 Search model；显式排序历史副作用 | Swift 6 strict core fixtures、现有搜索路径、完整 release+preview CI | 实施中，待 CI |
| P04 | URLSession client+只读 discovery native slice；运行时切换前先满足 P05 最小账户 context 边界 | URLProtocol HTTP/API error/取消 fixture；真实 API/账户对照；CI | 待开始 |
| P05 | 认证/Cookie/签名/用途账户 snapshot 边界，逐项 native cutover | 固定签名、登录/退出/换号/重启实际验收、CI | 待开始 |
| P06 | Home/Video/Profile/Library/Comments/Dynamics REST 逐领域迁移 | 每个领域独立 commit+fixture+原路径对照+CI；不跨领域大提交 | 待开始 |
| P07 | Codable/domain、versioned local persistence 与 Hive 导入 | 设置/历史/账户/下载不丢失，导入重复执行/回滚，CI | 待开始 |
| P08 | protobuf schema 来源固定、gRPC metadata/framing/unary 按服务迁移 | 二进制 fixtures、status/trailers/compression、真实请求与 CI | 待开始 |
| P09 | IM/直播 TCP/WebSocket/弹幕与重连 | 包切分/粘包、压缩/恶意长度、账号隔离、后台断线与 CI | 待开始 |
| P10 | Native 下载/后台/播放器外围业务 | 恢复/暂停、后台 session delegate、媒体命令/PiP、真机与 CI | 待开始 |
| P11 | 每个剩余 Flutter route 对应 Native feature，逐条移除旧页 | route coverage 零缺项、完整核心 UI/业务矩阵、CI | 待开始 |
| P12 | 删除已无 caller 的 bridge 领域，再删除 iOS Flutter engine/build dependencies | 离线构建无 Flutter SDK；冷启动/深链/所有核心路径、CI | 待开始 |

## 每阶段执行与回滚

1. 阅读该领域所有 Dart 业务/参数/模型，记录变更与保留路径；用最小协议封装，不复制 channel 字典到 View。
2. 修改后 `git diff --check`、逐文件 diff 和资源/依赖删除检查；仅 stage 本阶段路径，不 stage 用户原有 `youtube/`。
3. commit -> push 到 `codex/native-migration`；`gh workflow run ios.yml --ref codex/native-migration`，preview 按 paths 自动触发或显式 dispatch。核对 run.headSha 等于提交 SHA。
4. 保存 run URL、SHA、结论和实际日志。失败则读取 failing job logs，修复、再次 commit+push+build；两条门禁通过后才更新状态和进入下一阶段。
5. 任何 Native slice 均先保持已存在的 Dart 实现；只有状态 V、没有旧 caller/route、数据导入已验收才到 R。账户/写请求失败不得盲目双发；取消不得被 fallback 转成第二次请求。
6. 回滚：单个阶段可 `git revert <stage-commit>`；必要的依赖提交一并回滚。切换开关在 composition/repository 中，不暴露迁移实现细节给用户；fallback 继续有明确删除门禁。

CI 证据持续写入 `PROGRESS.md`。未通过 CI 的阶段保持进行中；等待真实 API/账户/真机验证的领域标记 N，不夸大成 V。

## Skills 适用决策

已读取用户给定 [ios-engineer](https://github.com/i-stack/ai-coding-kit/blob/main/skills-engineering/ios-engineer/SKILL.md)、[SwiftUI Pro](https://github.com/twostraws/SwiftUI-Agent-Skill/tree/main/swiftui-pro/skills/swiftui-pro)、[interop](https://github.com/dpearson2699/swift-ios-skills/tree/main/skills/swiftui-uikit-interop)、[architecture](https://github.com/dpearson2699/swift-ios-skills/tree/main/skills/swift-architecture)、[concurrency](https://github.com/dpearson2699/swift-ios-skills/tree/main/skills/swift-concurrency)、[networking](https://github.com/dpearson2699/swift-ios-skills/tree/main/skills/ios-networking)、[axiom bridging](https://github.com/megastep/codex-skills/tree/main/axiom-uikit-bridging)、[UIKit modernization](https://github.com/superagents-lab/xcode27-skills/blob/master/uikit-app-modernization/SKILL.md)。最后一个仓库实际为 master，并非 main。

应用：状态所有权、依赖注入、逐 feature strangler、结构化取消、immutable Sendable、HTTP/API 双验证、representable 创建/更新/销毁与 child containment、feature 文件拆分。iOS26/Swift6.3 新应用默认和 beta API 不覆盖本项目 iOS16 兼容需求；不引入 TCA 或全库并发/样式重写。

架构决策复核（ios-engineer cognitive adversary）：

- 复述：最终 Native 业务与 UI；每领域验证后删除 Dart。
- 最强反驳：当前已有“SwiftUI 可运行但 preview 失败”的真实反例；release 编译成功也未证明功能等价。现有多账户 interceptor 与 Hive adapters 说明单纯把 endpoint 搬到 URLSession 会改变账号/缓存语义。
- 隐藏假设：REST/RPC 可保持现有协议与风控路径；旧数据可被导出/导入。任一不成立都阻止对应 fallback 删除。
- 失效条件：Native 登录丢 Cookie、搜索返回类型丢失、下载无法恢复、未映射 route 或真实 CI 失败。
- 可证伪条件：同 fixture 与原实现不一致；同账户真实服务请求结果/动作不同；取消或切账号后写回旧结果。
- 立场翻转：选择渐进 Native 迁移，但证据不满足时维持该领域 Dart 实现。
- 迎合自检：反驳强度、否定稀释、受用户确信影响、无证据置信度四项均否；不承诺未经检验的完全兼容。
- 置信度：阶段方法高；最终功能等价尚不确定，缺少账号、真机与全部领域对照证据。
- 结论：先修复基线和建边界，严禁用 SwiftUI 页面或静态分析代替业务验收。
