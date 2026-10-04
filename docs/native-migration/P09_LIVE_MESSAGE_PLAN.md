# P09：直播消息、私信同步与弹幕迁移准备

> 2026-10-05 执行节奏更新：按用户最新要求，同组并行实施、各切片独立检查/提交/推送，整组汇合后统一运行 release 与全部 preview，并读取实际日志修复至成功。本文件旧有逐切片完整 CI 门禁由此替代；功能/数据验收、fallback 删除和权威切换门禁保留。见 [P05_GROUP_ACCEPTANCE.md](P05_GROUP_ACCEPTANCE.md)。

2026-10-04，仅只读准备；实际实现与 CI 尚未开始。先完成 PLAN.md 的网络、账户、
存储及 P08 协议门禁，再按方法切换；UI 重写最后，Flutter fallback 保留。

## 现有实现，不能按目录名推测协议

`lib/tcp/live.dart` 使用 WebSocketChannel，并非直接TCP socket；
`pages/live_room/controller.dart:542`从LiveDmInfoData.hostList构造
`wss://host:wssPort/sub`，使用token、roomId与`Accounts.heartbeat.mid`鉴权。
LiveHttp房间信息/弹幕token等按ApiType为heartbeat；发送直播消息则取main.csrf。
推荐直播列表另为recommend，不能把直播所有REST与Socket改成同一账户。

| 原层/入口 | 拟建Native组件 | 保留语义 |
|---|---|---|
| `http/live.dart`; live/list/area/follow/search controllers | LiveRepository/LiveRESTService | 区域/房间/画质/编码/音频、WBI、用途、关注/搜索与错误 |
| PackageHeader/AuthPackage/HeartbeatPackage | LivePacketCodec | 16字节big-endian header，length/headerSize/version/op/seq |
| LiveMessageStream.init/onData/close | LiveSocketClient actor + transport protocol | 多服务器依次尝试，鉴权/心跳/压缩/关闭/事件订阅 |
| live_room `_danmakuListener` | LiveEventMapper→LiveEvent/LiveFeatureState | DANMU_MSG/表情/回复/勋章/屏蔽、自发标记、SuperChat、人数/房间变化 |
| `grpc/im.dart`与bridge `_loadNativeSessions/_loadNativeChat` | MessageRepository/IMRPCService/MessageSync actor | offsets/hasMore、sequence、msgKey、已读/未读、发送/图片/撤回/屏蔽 |
| `http/msg.dart`通知/上传/ack/设置 | NotificationRepository/MessageRESTService | 回复我/@我/赞/系统、上传、cursor/设置/免打扰，不用私信列表替代全部通知 |
| `grpc/dm.dart`; native player segment接口 | DanmakuRepository/SegmentCache/RuleStore | P08消息与分段预取、规则、发送/举报/撤回，Native绘制继续独立 |

现有鉴权请求op=7/headerVersion=1，body protover=3/platform=web/type=2。
收到op=8启动30秒周期心跳，op=2/seq递增；op=3被忽略。版本0/1原始JSON消息，
版本2 zlib、3 Brotli，解压后可递归处理多个packet。不要用WebSocket ping替代
Bilibili应用心跳，不能移除Brotli后宣称直播弹幕迁移完成。

旧init仅连接阶段依次尝试host，onDone/onError调用close并永久active=false；
没有实现连接后自动重连。Native重连是明确的新生命周期改进，独立切片验收，
不能声称旧代码已有无限重连或沿用永久关闭flag却保证恢复。

旧parser在不足10字节时拒绝，却随后读16字节header；压缩路径固定从0x10取到
data末尾，多个/异常包边界与资源上限不完整。Native应有界逐packet解析，合法
旧输出对照；畸形输入、压缩膨胀和鉴权失败处理作为明确修复记录，不掩盖异常。

## 可独立验证的切片

1. **P09a纯codec。** 实际Dart Auth/Heartbeat产生synthetic golden，Native比较
   完整bytes；JSON/裸packet/zlib/Brotli/多packet解码对照。schema/event mapper
   不依赖View或Aether，保留原字段并明确未知cmd，不删业务模块。
2. **P09b typed Repository + Dart adapter。** Live与Messages分别建立protocol/
   Domain/Feature State；每次一个领域，沿用原UI，Root只组合。实际caller/route
   在inventory有对应，原server-list/account/token所有权清晰。
3. **P09c Native Socket隔离验证。** 可注入clock/transport、连接epoch与heartbeat
   owner；单receive循环、明确close与cancel，迟到connect/data不得重建旧房间。
   先真实本地WebSocket/TLS验证，再只读真实房间对照，token不进日志。
4. **P09d REST + Socket切换。** P05有效policy/signature/heartbeat快照支持后，
   逐房间/列表方法切；account/room变更先关闭旧socket，新结果按epoch更新。
   留原播放路径，列表/弹幕成功不能构成删除直播playurl/音频/画质/点赞等的条件。
5. **P09e有限重连。** exponential backoff+上限+jitter、单在途connect，close/退出/
   换房间取消所有retry。网络恢复/foreground策略明确，凭据或token失效先重新取得
   已验证token，不重用退出账户。鉴权ack失败不开始心跳，不盲目并发多个host。
6. **P09f MessageSync。** 先会话/历史/未读只读，再ack/置顶/删除/设置，最后发送/
   上传/撤回。并非已存在私信WebSocket，按实际HTTP/gRPC轮询/同步caller迁移，
   不自行引入不存在的TCP协议。每方法继承P08实际main/extra.account规则。

## 验证与删除门禁

- packet分片/连续拼接/多压缩包、10–15字节header、错误headerSize/length/op/
  version、零长度/超大/深递归/压缩炸弹、坏UTF8/JSON；最多packet/event/buffer明确
  有界。不从网络字节直接递归到MainActor UI，不让后台无限积累显示消息。
- 实际本地WebSocket验证auth bytes、ack→30秒heartbeat、并发close/迟到connect、
  host失效/中断/重连上限、房间/账号A→B→A、后台恢复；fake clock不代替真实wire。
- Event mapper覆盖实际controller支持的DANMU_MSG/SUPER_CHAT_MESSAGE/
  WATCHED_CHANGE/ONLINE_RANK_COUNT/ROOM_CHANGE；原注释的SuperChat删除不标已支持。
  头像/勋章/表情/颜色/模式/屏蔽/自发标记及消息trim策略与Dart脱敏fixture比较。
- IM pagination offsets与message seq/key不能用展示index替代；撤回隐藏、图片/表情、
  时间单位、session类型/免打扰/置顶、未读数与style分开。发送unknown结果先核对，
  不因超时或取消重复SendMsg；上传/撤回/通知另有动作与权限矩阵。
- 原直播播放器/列表/关注/贡献榜/表情/屏蔽、通知所有route保持可达。P08与P09分别
  验收codec、传输、状态/业务，不能借Native弹幕绘制压力通过跳过协议验证。
- 每切片diff→commit/push→实际Swift6/Runner与全preview同SHA；账户/真实房间/
  真机后台仍需独立验收，CI编译不能证明它们。失败读日志修复重跑。

Socket可回滚到Dart前先终止Native会话/计时器/订阅，禁止双连接/双发送。Aether只
消费播放与弹幕输出，不访问Live REST、socket、账户或业务storage。全部caller与
功能验证完成前，不删除tcp/live、Dart IM/弹幕实现、protobuf或Flutter runtime。
