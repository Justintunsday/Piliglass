# P08：protobuf / gRPC 原生迁移准备

2026-10-04，只读盘点；尚无本计划的生产实现、依赖添加或 CI 验收。
当前继续 P05 与完整构建闭环，本文仅并行准备；UI 重写最后。

## 实际协议与来源

`lib/grpc/grpc_req.dart` 并未使用通用 gRPC SDK：它把生成的 protobuf 交给
`Request.post<Uint8List>`，发送到 `https://app.bilibili.com` + `lib/grpc/url.dart`
完整服务路径。transport沿用Dio的有效HTTP2 adapter/HTTP1 fallback，默认HTTP2设置
false；不能因目录名就宣称现有请求必然HTTP2或把SDK默认协议视为等价。

- Request frame为1字节压缩flag + 4字节big-endian长度 + protobuf；原payload
  长度>64才gzip，flag=1；64及以下不压缩。压缩阈值针对未压缩payload。
- Response只解析第一条frame；flag=1解gzip，否则取长度对应的slice。当前没有
  多message/stream/显式最大长度检查，Native须有界解析；畸形输入改进另记行为边界。
- `Grpc-Status == '0'`且data为Uint8List才解码，isolate=true且>256KiB才compute。
- 错误读取`Grpc-Status-Details-Bin`，补base64padding，先解`bilibili/rpc.pb.dart`
  Status及details中的Status；失败退回allowMalformed UTF8。debug/release提示不同。
  不能一律简化成HTTP200成功或只保留数字status丢掉实际消息。
- metadata在`utils/accounts/grpc_headers.dart`：gzip、identify_v1 authorization、
  Device/Network/Locale/Fawkes/Metadata二进制base64、buvid/trace/device/build等。
  基础map静态初始化；LoginAccount.grpcHeaders是late final整份缓存，不能将
  fawkes/sessionId描述成当前每次请求重建。匿名账户实现也要分别对照。
- `account_manager/account_mgr.dart` 对app前缀+bytes走grpcHeaders分支，不AppSign，
  不CookieJar写回。`ApiType`标注grpc TODO、未登记这些完整路径，当前默认main；
  extra.account显式覆盖优先。禁止推测弹幕就video、评论就heartbeat而改账户。
- 当前GrpcReq.request没有传入CancelToken；Native取消是新Repository生命周期要求，
  必须有实际终结/写请求单次发送契约，不能宣称旧Dart已经具备结构化取消。

## schema 与模块边界

仓库包含`lib/grpc/bilibili/**/*.pb.dart/.pbenum.dart/.pbjson.dart`，生成头说明原始
proto名称，但当前仓库没有`.proto`源文件。pubspec.lock实际protobuf为6.1.0；生成
plugin/protoc版本与schema上游commit未记录，不能直接选最新上游全量再生成。

P08a先登记每个用到的message/tag/enum/oneof/import及生成源hash，追溯原始schema
来源/许可/commit；保存可复现schema和生成脚本后才添加Swift生成源。上游未知时
保持Dart adapter，不用手写缩减模型代替全部protobuf。SwiftProtobuf与transport
依赖版本/iOS16/Swift5 Runner链接支持须在独立依赖切片实际验证，尚未选定SDK。

拟建独立BilibiliProtocol模块承载生成消息、metadata和frame/status codec，不能
依赖SwiftUI/Flutter/Hive/Aether。Networking/GRPC承载HTTP调用与取消；Data各领域
负责消息→Domain/错误mapper，Feature只调用Repository。Aether不导入API/schema。

## 实际 caller map 与最小切片

| 来源与使用路径 | 拟建Native边界 | 验证/保留 |
|---|---|---|
| `dm.dart` DmView/DmSegMobile；bridge1070/1185、video/controller、danmaku/controller、download_service | DanmakuRPCService→DanmakuRepository | cid/aid/segment/type、6分钟分段、绘制/下载caller；engine只消费结果 |
| `reply.dart` MainList/DetailList/DialogList/SearchItem/TranslateReply；bridge2779/2955、main_reply/video/dyn controllers | CommentRPCService→CommentRepository | cursor next/offset/mode、置顶/楼中楼、翻译、筛选；不能REST替代丢分页 |
| `dyn.dart` DynRed/LikeList/RepostList；main/common dyn controllers | DynamicRPCService→DynamicRepository | 未读、点赞/转发列表与offset；未使用wrapper不标活跃 |
| `im.dart` SessionMain/SyncFetchSessionMsgs/SendMsg；bridge2291/2365/2477等、request_utils/page_utils | IMRPCService→MessageRepository/MessageSync | 会话/历史/发送/分享，写请求失败不重发；其他Im方法需逐caller盘点后保留 |
| `audio.dart` Playlist/PlayURL/ThumbUp/TripleLike/CoinAdd；audio/controller | AudioRPCService→Playback/AudioRepository | 4048 fnval、qn、item/subId/order、分页/动作；不能因为UGC REST可播就删除音频 |
| `space.dart` SearchArchive；member_search/child/controller | ProfileSearchRPCService→ProfileRepository | query/mid/pn/ps与分页，保留其他wrapper待caller审查 |

当前`ViewGrpc.view`的PGC引用被注释，Popular/PlayerOnline也注释；OpusDetail/
OpusSpaceFlow wrapper没有找到活跃caller。保留它们与schemas，区别现有功能、
可用wrapper与未使用生成message，不把它们写成已经迁移的核心数据来源。

1. P08a schema provenance/hash/生成工具与纯frame/status/metadata golden；不切网络。
2. P08b typedGRPCClient protocol+Dart adapter；每个领域独立Repository/DTO，不建
   跨全部RPC的业务manager。真实Dart生成bytes与Native消费/生成双向对照。
3. P08c先只读DmView，再单段DmSegMobile；然后评论各方法逐切片。每个endpoint
   有单独固定请求白名单/用途snapshot/response映射，policy未支持则发送前选Dart。
4. P08d dynamic/Profile/audio只读逐方法；IM读/同步之后才写/已读/置顶/删除/屏蔽。
   写请求需要服务端消息标识/unknown结果核对，不能因timeout自动二次SendMsg。
5. 每个领域验收后审核全部caller，只有全部N→V且零旧caller才删除对应Dart实现。

## 可证伪验证与回滚

- 实际Dart GeneratedMessage生成synthetic request/response，涵盖int64>2^53、
  默认/缺失/presence/unknown enum/oneof/map/repeated与未知field。protobuf map
  serialization次序可不同，要求semantic一致并对确定性字段逐byte验证，不误判。
- frame阈值63/64/65、gzip内容、big-endian、截断/负长度/超大声明、坏gzip、多个frame
  与尾随字节；兼容合法旧输出，资源上限和畸形行为显式记录，不能静默删消息。
- status/header/trailer来源分开测；Dio当前不发送te:trailers，不代表Native只读headers
  就有完整RPC状态。用真实本地HTTP2/TLS server及固定错误Status验证所选transport。
- metadata使用注入synthetic buvid/trace/session/accessKey与真实Dart生成消息；验证
  main≠video≠heartbeat≠recommend、匿名、同MID新generation、退出/换号与旧请求隔离。
- 评论过滤复用实际`needRemoveGrpc`商品/关键词/嵌套回复行为；UI pinned/图片/链接/
  被删/游标与现有preview对照。IM unread/同步顺序/取消/unknown ack单独测。
- Swift6 strict fixture + iOS16 Runner实际编译/链接 + 全preview同SHA；对照真实API
  时单路顺序请求，不在用户生产同时shadow写两套实现；脱敏产物不含认证metadata。

所有切片先保存计划、检查diff、commit/push、读取Actions实际日志；失败修复重跑。
未通过实际schema/transport/用途账户验收时保留Dart authority/fallback；Native已发
请求不转为Dart同请求重发。回滚只恢复该方法composition，生成来源与fixture保留。
