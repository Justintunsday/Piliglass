# P06 DTO 准备与 P07 Models / Persistence 执行计划

> 2026-10-05 执行节奏更新：按用户最新要求，同组并行实施、各切片独立检查/提交/推送，整组汇合后统一运行 release 与全部 preview，并读取实际日志修复至成功。本文件旧有逐切片完整 CI 门禁由此替代；功能/数据验收、fallback 删除和权威切换门禁保留。见 [P05_GROUP_ACCEPTANCE.md](P05_GROUP_ACCEPTANCE.md)。

2026-10-04，只读盘点后的修改前计划；尚无本计划中的生产实现或 CI 验收。
PLAN.md 的 P06 是 Home/Video/Profile/Library/Comments/Dynamics REST 逐领域迁移，
P07 才是 Codable/domain、versioned local persistence 与 Hive 导入。P06 每个领域
先建立对应 DTO/Domain，不提前全库重写模型；P07 在这些边界上逐 store 切换。
UI 重写最后；AetherEngine 只消费播放描述，不直接访问 API/Hive/Keychain。

## 当前所有权与模型对应

Native 目前只有 Search typed repository/DTO 和 Bridge presentation model；
`PiliNativeRootViewController.swift:3060` 起仍有 VideoDetail/Library/Dynamic/Comment/
Download/Account/Profile 字典 DTO。`Native/Persistence` 目录与 Keychain 实现尚不存在。
`PiliNativePlayer.swift:493` 的 `pili.native.*` UserDefaults 与 Root 的 AppStorage
是真实现有本地设置，不能只导入 Hive 后将其覆盖。

| 实际 Dart / Native 来源 | 目标 Native Data / Domain | 范围与验证 |
|---|---|---|
| `http/video.dart:53,:171`; `models/home/rcmd/result.dart`; hot/rec video item | Home response DTO → FeedItem/Page + HomeRepository | 推荐用途、web/app参数、过滤与分页；先只读，app路径等待签名 |
| `http/video.dart:291,:814`; `models_new/video/video_detail/*`; Root VideoDetail | VideoDetail/PlayInfo DTO → Video/Part/Subtitle/Quality | UGC/PGC/PUGV、权限/付费/分P，不把未知类型删掉 |
| `http/member.dart`; `models/member/*`; `models_new/space/*` | Profile DTO → Member/ProfilePage | 投稿/动态/收藏/关注、页面游标与账户用途 |
| `http/fav.dart:53,:398`; `models_new/fav/*`; Root LibraryItem | Library DTO → Folder/Resource/Page | 失效资源/公开私有/视频/文章/PGC/笔记，服务端是 authority |
| `http/user.dart:85,:288`; `models_new/history/*` | History DTO → HistoryEntry/Cursor | heartbeat 登录否则 main；API 秒→播放毫秒，progress=-1→0 |
| `http/reply.dart`; `models_new/reply/*`; Root Comment | Reply DTO → Comment/Thread/Page | pinned/top/图片/表情/二级回复/排序/权限；RPC路径留到P08 |
| `http/dynamics.dart`; `models/dynamics/result.dart`; Root Dynamic | Dynamic DTO → DynamicItem/Module/Page | offset/转发/opus/投票/预约/直播，保留未知 module 与跳转 |

Wire DTO 精确对应 key/null/数值类型；Domain 不依赖 SwiftUI、Flutter 或网络。
网络 DTO、Domain 与持久化 DTO 分开，不把展示文案当唯一源数据。已有 Search 的
`Domain/Search/PiliSearchRepository.swift`、`Data/Search/PiliSearchTrendingDecoder.swift`
可作为小范围边界参考，不能直接把复杂领域塞进统一万能 Model。
`DynamicsDataModel.fromJson` 当前还读取 Pref 并过滤商品/屏蔽词；Native 解码与过滤
拆开，Domain policy 注入已有设置并对照过滤结果，不能把移除副作用当兼容完成。

## 本地数据逐 store migration map

`lib/utils/storage.dart:17` 定义 boxes/init/adapter；`:80` 的 exportAllSettings
只导出 setting/video，不能用它代表历史、账户、回复与下载全部导出。

| 来源 / authority | Native store | 必须保留 |
|---|---|---|
| `GStorage.setting/video`; `storage_key.dart`; `storage_pref.dart:52` | SettingsRepository + versioned SettingValue/PlayerPreferences | 缺 key 与显式false/0、enum原值/集合、设置默认、未知键；现有Native值有明确优先级 |
| `historyWord['cacheList']`; `search/controller.dart:53,:180`; `ios_native_ui_bridge.dart:1914` | SearchHistoryStore actor | 原顺序、去重置顶、remove/clear、recordSearchHistory开关；不冒充服务端观看历史 |
| `watchProgress`; `video/controller.dart:326` | LocalPlaybackProgressStore | cid字符串、毫秒与完成近尾阈值；旧数据没有账户字段，不能猜造归属 |
| `userInfo['userInfoCache']`; `models/user/info.dart`; `LoginUtils` | Account-scoped ProfileCache | 只是nav缓存，不是登录凭据；换号/登出失效，int money转换等旧字段契约 |
| `localCache`; `native_danmaku_settings.dart:18` | VersionedCache + DanmakuRuleStore | full/simple独立、owner/profile、导入负ID/local规则；historyPause是服务端状态缓存 |
| `reply: Uint8List`; `reply_item_grpc.dart:1034` | ReplyBlobStore | optional saveReply/debug保存的protobuf字节；schema解码留到P08，不改写为猜测JSON |
| `Accounts.account`; account/cookie adapters | AccountSelectionStore / KeychainCredentialStore / NativeCookieStore | 沿用P05四用途/owner+generation/authorityEpoch，明确单一写入authority |
| `download_service.dart:32,:250,:400`; `models_new/download/*` | DownloadManifestStore | entry.json/index.json、cid/quality/UGC/PGC/PUGV、路径与partial状态；传输队列切换留到P10 |

服务器收藏/稍后看/观看历史的读取和增删由 Repository 调用 REST；本地缓存只能
保存已验证响应。删除搜索词/播放进度不能调用 clearHistory，清 cache 不能删收藏。
旧 `cookie_jar_adapter.dart:15` → `account.dart:199` 只保存 bilibili.com 根 `/`
name/value，非根 domain/path/expiry 属性已经丢失；导入不能宣称恢复不存在的数据。

## 最小可回滚切片

1. P06 各领域先提 Domain protocol + Dart adapter，拆对应 Root DTO/Feature State；
   每次一个领域、沿用 UI 外观，比较字段/分页/错误/取消/账户来源。Native REST 实现
   另 commit，严格响应解析与HTTP/API双验证，验证后才切composition。
2. P07a 建 `Persistence` 的 version envelope/typed值/导入记录与只读 exporter。
   exporter 使用真实 Hive adapter 读取，不能在 Swift 猜 Hive 二进制；导出包含
   source版本/box/key类型/完整值，set/bytes/adapter对象有明确编码，不丢未知键。
3. P07b 先导入搜索历史到 native staging，重复导入与重启对照后才切该 store。
   导入前后 revision 检查与受控写屏障确保快照一致，失败保留 Dart authority。
   所有 Flutter/Native 写 caller 必须通过同一个 repository adapter 再切写入，禁双写。
4. P07c 设置分批导入：明确旧Hive与既有UserDefaults优先级，native已有明确值优先；
   enum/range默认不盲取 ordinal。验证重启、外部设置import与每一个既有读写caller。
   watchProgress/缓存/回复/下载manifest分开小提交，不一次迁移所有box。
5. P07d 账户安全存储沿P05方案先shadow读取/导入synthetic验证，再安排authority切换；
   Token/refresh/敏感Cookie不写报告或普通JSON日志，Keychain与Cookie store职责分开。
   WK Cookie/main副作用仍有独立owner，不能因存储导入就宣称登录完成。

新 Native store 使用显式schemaVersion与有界解码，文件置Application Support，
经临时文件/原子替换提交；记录导入完成仅在数据durable成功后。数据量大的store
采用按key可更新的容器而非每次全量写巨大JSON，具体格式在对应切片盘点后确定。
下载导入只读取manifest/引用既有媒体，不移动删除文件；路径与沙盒容器变化单独
验证，后台任务/断点恢复不属于P07已完成声明。

## 真实验证与回滚门禁

- Dart fixture 实际写Hive并close/reopen，含现有adapters/Set/bytes/缺失/null/坏类型；
  Swift消费同份export，在临时目录与UserDefaults suite中验证读写/restart，不改用户库。
- 网络DTO对照实际Dart解析与脱敏fixture：空页/重复/失效资源/未知enum/module/
  缺字段/错误envelope/游标/取消/换号。播放单位、API progress=-1、local尾阈值独立测。
- 导入重复执行、导入中断/写失败、较新schema拒绝、安全旧副本保留、并发编辑/换号
  及authorityEpoch重建要测试；导入前旧应用和导入后native读取结果逐项比较。
- 每切片检查diff/resources → commit/push → ios.yml + 全ios-home-preview同SHA；
  编译失败读实际日志、修复重跑；账户/真机未验收时只能标N，不能标V/R。
- authority尚未切换时丢弃native staging即可回退。切换后的新增写入必须有兼容
  reverse-export/回退方案才允许开关回Dart；禁止直接读旧Hive造成新数据丢失。
  未验收前保留Hive、旧adapters、Dart fallback与所有原媒体资源。
