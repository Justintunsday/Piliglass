# P10：下载、后台任务与播放器外围业务准备

> 2026-10-05 执行节奏更新：按用户最新要求，同组并行实施、各切片独立检查/提交/推送，整组汇合后统一运行 release 与全部 preview，并读取实际日志修复至成功。本文件旧有逐切片完整 CI 门禁由此替代；功能/数据验收、fallback 删除和权威切换门禁保留。见 [P05_GROUP_ACCEPTANCE.md](P05_GROUP_ACCEPTANCE.md)。

2026-10-05，当前 P05 Policy-1 CI 期间的源码对照；未实施 P10 生产迁移。
继续 PLAN.md，UI 视觉重写最后。Aether 保持独立播放模块。

## 当前功能与 Native 对应边界

| 当前源码 / 功能 | Native 替代边界 | 先保留的实现 |
|---|---|---|
| `download_service.dart:76,:248,:289,:539` 文件恢复、队列、单 entry 调度 | Domain DownloadRepository、actor DownloadCoordinator、Persistence DownloadManifestStore | Dart adapter/真实旧目录 |
| `download_manager.dart:33` HTTP11 stream、Range、本地文件、暂停/删除 | Networking resumable transfer、Data 下载任务记录、Native background session delegate | 原 Dart stream 和取消路径 |
| `http/download.dart:21` playurl/画质/codec/CDN/音轨选择 | PlayerMediaRepository、DownloadMediaPlan；普通请求仍通过 Repository/Client | video 用途与现有 API/选择规则 |
| `download_service.dart:308,:358` protobuf 弹幕和封面 | DanmakuRepository、CoverService、下载协调器 | gRPC adapter、CacheManager |
| `ios_native_ui_bridge.dart:3065…3257` 五个下载命令/离线播放 | Feature DownloadState、typed DownloadRepository、LocalMediaRepository | 所有命令、SourceType.file Flutter 路径 |
| `PiliNativePlayer.swift:1158,:1201,:1220` 锁屏命令、NowPlaying/封面 | Player NowPlayingCoordinator、ArtworkService、PlaybackCommand protocol | 当前 session 行为 |
| `PiliNativePlayer.swift:1338,:2769` 前后台音轨状态、AVPlayerLayer PiP | Player lifecycle/PiPCoordinator、UIKit surface adapter | 两个 Aether engine、可用 layer 与原限制 |

真实旧行为：读取全部 entry，completed 加入 library，未完成重置 wait；队列仅一个
entry 活跃，其 DASH video/audio 两个 manager 可并行，完成需两者成功。启动新 entry
先 await 旧任务取消；danmaku 首段后每批最多 4 个，失败阻止进入 playurl。封面失败
不阻止媒体下载。manager 的进度大约按整数秒更新，service 再限制 UI refresh 为 120ms；
Native 不把 120ms 误称为旧网络回调固定频率。

暂停保留部分文件并持久 entry，删除可以继续下一项；bridge pause 明确
downloadNext=false。UGC/PGC/PUGV、质量回退、偏好 codec、音频选择、CDN 策略和
video 用途须完整保留，不能改绑 main。Type1 当前仅取首个 durl/segment；导入须保留
全部 manifest 字段，扩展多段实际下载作为独立行为变更，不能假称旧实现已覆盖。

## 目录与持久化门禁

当前文件：entry 根 `entry.json`、quality/typeTag 子目录 `index.json`，Type1 `0.mp4`、
Type2 `video.m4s`/`audio.m4s`，封面 `cover.jpg`、弹幕 `danmaku.pb`。UGC page/PGC season/
cid 路径由 `_getDownloadEntryDir` 和 PathUtils 确定；执行前用实际 exporter 再锁定。
Domain DTO、旧 JSON DTO 和 versioned Native task record 分离，不将带 Widget 的
BiliDownloadEntryInfo 当作原生业务模型。

P07 的真实旧数据 import/restart/idempotence 后才能由一个 store 接管写入；Native
与 Dart 不独立写同一个 entry 或媒体文件。路径必须在 app 指定下载根下解析/验证，
保留用户已存内容；corrupt/unknown entry 留可恢复记录，不静默删除。回滚需 reverse
export 新写入的状态，不能切回过期 Hive/JSON 并宣称数据兼容。

## 独立提交顺序

1. typed DownloadRepository/LocalMediaRepository + Dart adapter，把下载 Feature/DTO/
   polling 从 Root 拆出。五命令、已有状态、选项/多选、暂停/恢复/删除/更新弹幕和
   离线打开保持；没有原生下载执行或 UI 视觉重写。
2. 真实旧 manifest/file fixtures → Native staging import、重启/重复导入、完成状态和
   DASH 双轨联合状态；媒体内容不重新下载。纯 media plan 用实际 Dart API 输出对照。
3. 可恢复 foreground transfer 与 actor 任务状态。Range 206 的起止/总长度、200
   忽略 Range、416、chunked/unknown length、ETag/If-Range、过期 URL、截断、磁盘满
   和取消必须分别验证。旧 manager 会追加 200、允许 416 并按 EOF 完成，缺乏完整性
   检查；Native 修正需单独可审查提交，不能为“兼容”把坏文件标记成功。
4. Native URLSession background session，稳定 session identifier、opaque taskID 映射、
   delegate 事件/文件原子落盘/持久化 receipt、AppDelegate 恢复 completion。Dart 当前
   没有该机制，这是新增生命周期能力，不是已存在行为已移植。BGTask 只负责系统
   允许的维护/调度，不替代长时间网络后台 session。
5. 分别迁移 danmaku/cover/media API 及离线 LocalMediaDescriptor；权限/原 owner、
   request generation、policy 和 P08 protobuf 保持。离线文件交给现有播放协议，不
   让 Aether 解析 entry JSON、请求 Bilibili 或持有 UI/账户对象。
6. 从 Player 拆锁屏/Artwork、音频 lifecycle 和 PiP，每个领域独立提交。测试新的
   session/reconfigure/dispose 的命令 target 所有权；当前 deinit 只取消 loadTask，
   未显式 remove remoteCommandTargets，不能假设重复 session 无残留 callback。

Native resumeData 是系统不透明状态，不能与旧 Range 部分文件直接互换；须记录
下载类型及保存恢复材料，不向日志输出含凭据的 URL、Cookie 或 resumeData。收到
响应后的 owner/文件任务终结不能因当前账户变化重定向到新任务；暂停/删除与
迟到回调通过任务 generation 单次消费。URL 失效后的刷新不自动重放账户写请求。

## 播放器能力与真实验收

当前背景使用独立 audioEngine 的 clock，前台恢复按 currentTime seek；Native 分拆
需保留多段 offset、buffering、seek/结束去重、播放速率和中断状态。NowPlaying 保留
标题/作者/封面/时长/速率、0.75s 刷新限制与结束后播放从头开始；下一首仍转发上层。
全局 MPRemoteCommandCenter 的 target 需按 session 所有权释放，Artwork late result
不得覆盖新视频。网络封面由独立 Service 调用，不进入 Aether。

当前 PiP 仅在 AVPlayer/nativePlayerLayer 可用时出现，复用可见 layer；FFmpeg surface
没有因此获得 PiP。保留 capability gate，不创建第二个隐藏 AVPlayerLayer。sample-buffer
PiP 若另行实现，必须独立真机验证渲染/音频/还原和 UIKit/SwiftUI containment。

每个切片 diff→commit→push→完整 ios.yml + 全 ios-home-preview 同 SHA；读取真实
下载 wire/file/重启及播放器控制日志。真机后台挂起/系统重新启动/强制退出差异、
锁屏/耳机命令、音频中断/route 切换和 PiP 恢复属于额外验收，模拟器/编译不能替代。
无设备证据的能力保留门禁；当前 Flutter 下载/离线播放 fallback 不提前移除。
