# P05：签名与四用途账户边界的后续切片

2026-10-04 编写于 P05a2c1 验证期间；2026-10-05 保存。阶段最新证据见 PROGRESS.md。
此文为后续执行计划，不表示签名或账户运行时已经迁移。
继续 PLAN.md 原生业务迁移，UI 重写仍排在最后。切片分别提交、推送，完整
ios.yml 与 ios-home-preview.yml 同 SHA 全绿后才能进入下一切片。

## S1：纯 WBI / App signer，先固定实际 Dart 对照

源依据：`lib/utils/wbi_sign.dart:57`、`:62`、`:77`、`:95`，
`lib/utils/app_sign.dart:7`、`:27`，`lib/utils/utils.dart:61`，
`lib/utils/accounts/account_manager/account_mgr.dart:69`、`:84`。

1. 给现有 Dart signer 增加可选、调用处兼容的 epochSeconds 输入；默认仍取现有
   DateTime 秒值。抽取复用的纯 query helper 供实际 signer 与 golden 调用，
   测试不能复制另一套 Dart 签名算法当 oracle。
2. 固定 synthetic img/sub key、App key/sec、时间与参数；Dart 导出 JSON golden，
   包含输入、mixin key、输出 params/digest、encoder 中间 query。无真实账户凭据。
3. Swift `Networking/Auth` 实现纯、Sendable signer 与明确签名输入值；不读账户、
   Hive、网络或时钟，不在 View/MainActor 内做编码。生产 composition 以后提供时间。
   输入采用有序 Field 数组，保留重复键与规范等价但 code units 不同的 Unicode key；
   不用 Swift Dictionary 合并这些 Dart 能区分的键。
   MD5 可用 iOS 16 已有 CryptoKit 的兼容哈希，仍以实际 golden 证明字节一致。
4. CI 用真实 Dart/Flutter 生成并检查 golden，再用实际 Swift 源消费同份输入；
   严格 Swift 6 fixture 和完整 Runner 编译都要通过。此切片不切运行时请求。

WBI 必须对照的现有语义：

- mixin 表取拼接 key 的 32 个 UTF-16 code unit；非法长度须有明确错误边界。
- 覆盖 wts 为整数秒；按 key 排序，value.toString 后仅在签名字节中过滤 `!'()*`，
  返回参数本身保留未过滤值；每一对总有 `=`，然后 MD5(query + mixinKey)。
- 当前函数不移除旧 w_rid；需独立 golden 记录二次调用与旧字段，不暗中改变调用语义。
- 输入覆盖 ASCII/中文/emoji/组合字符、空字符串、空格/+/%/&/=、引号和括号、
  bool/int/string 与已有时间字段；数字/集合类型不能用 Swift 默认 description 猜测。
  已有调用类型未对齐前，新增 signer 拒绝未支持值并保留 Dart fallback。

AppSign 必须对照的现有语义：

- 覆盖 appkey，ts 是字符串秒值；query + appsec 后输出小写 MD5。
- 空字符串写裸 key，非空才写 `=`；Iterable<String> 按原顺序生成重复 key，
  空 iterable 不生成字段；null 在 debug assert 拒绝、release 写裸 key，须记录差异。
- signer 本身保留旧 sign 并将其纳入摘要；AccountManager 在重签前明确 remove sign。
  Native endpoint policy 负责该清理，不能把 interceptor 和 signer 的责任混在一起。
- 登录 dt/from_url 已在 `lib/http/login.dart:218`、`:224`、`:290`、`:296`
  预编码，golden 要覆盖百分号再次编码，不能擅自解码成另一份签名字节。

编码与排序按实际 Dart 契约：UTF-8 percent-encoding，空格 `%20`，保留
`-_.!~*'()`；按 UTF-16 code units 排 key，不使用 Swift 默认规范等价字符串排序。
主来源：[Uri.encodeComponent](https://api.dart.dev/dart-core/Uri/encodeComponent.html)、
[String.compareTo](https://api.dart.dev/dart-core/String/compareTo.html)。URLComponents
只用于已验证的 URL 装配，不充当这两套签名 query 的 encoder。

## S2：WBI key provider，缓存独立于纯 signer

现有 `_getWbiKeys` 使用 `Api.userInfo`（nav）并由账户路由选择 main；先保留
Bridge key-provider adapter。KeyProvider protocol 可注入 clock、fetch 与 store；
普通网络在独立 Service，actor 仅管理有界 cache 与单次共享在途 fetch。

需实际重放的缓存边界：

- 旧代码只比较本地 day，未比较 month/year；时间戳在 fetch 前写入。
- 同日有 mixinKey 即返回；缺 key 才复用 `_future`；跨日分支会再次赋值 future，
  并发调用可能在 timestamp put 完成前重复 fetch。
- 网络错误在 try 外传播，解析错误返回空 key；旧 `_future` 没有显式释放。
- 日期/时区切换、冷启动、旧缓存缺 key、坏 nav URL、失败后重试、取消某个 waiter
  与其他 waiter 仍需 key 都要覆盖。fetch 返回的旧结果不能覆盖较新刷新结果。

先记录旧行为并保持默认 adapter；原生完整年月日/失效/单次 fetch 策略作为独立、
可审查的行为修正，验证后才切换，不能把缓存修正混入纯 signer 提交。

## S3：四用途只读 AccountRepository / SelectionSnapshot

源依据：`lib/models/common/account_type.dart:1`、`lib/utils/accounts.dart:28`、
`:128`、`:305`、`:310`，`lib/utils/accounts/account_request_state.dart:10`，
`lib/utils/accounts/api_type.dart:6`、`account_manager/account_mgr.dart:243`、`:252`。

Domain DTO：`AccountPurpose` 精确保留 main/heartbeat/recommend/video；
`AccountIdentity` 是不透明 owner token + generation，不能仅由 MID 等值推导。
`AccountSelectionSnapshot` 包含 authorityEpoch、revision、四个 effective selection、各账户公开
mid/isLogin/activated/capability flags、持久用途与临时选择信息；history 单独解析为
heartbeat 登录账户，否则 main。DTO 不包含 CookieJar、Cookie/Token 明文或 SwiftUI。

`AccountRepository: Sendable` 首先提供 `selectionSnapshot() async throws`；
Dart adapter 在同步 capture owner/stamp/revision 后复制值，跨 await 后复查。
`AccountSession` actor 缓存已验证的不可变快照，拒绝同 epoch 内乱序 revision；
engine/authority 重建只由 composition 显式重置 epoch，不靠 MID 或任意回调重置。
它不接管 Hive owner 或写 Cookie。选择/安装/删除暂转发 Dart，返回新快照；旧请求仍以
自己的 generation 写回，不能因普通换号而把结果写到当前选中账户。

验证矩阵：四用途各指向不同账户、共享同一账户、匿名 singleton、临时无痕、
A→B→A、同 MID 新凭据、Cookie mutation、重启恢复、delete/import/clear 与乱序
bridge 回调；需要真实 Hive/Dio fixture，不用仅有 Swift actor mock 代替旧行为。
新 snapshot command 单独登记库存与 PBX，禁止向 Root 文件增加协议逻辑。

## 后续 authority / 登录 cutover 门禁

Accounts.refresh 是 Hive owner/用途对账与 buvid 激活，**不是 token 续期**。
refresh_token 目前只是保存，见 `account.dart:53` 与 `login/controller.dart:627`；
续期必须另有实际 endpoint 证据。Root QR sheet 仍经 Dart，不能代表完整登录迁移。
QR/密码/SMS/Cookie、Geetest success/error/close、密码 status=2 和 -105 challenge、
远端 logout 失败保留账户与本地删除，均要单独迁移并验收。

`LoginUtils.onLoginMain/onLogoutMain` 的 WK Cookie、userInfoCache、historyPause
副作用和 main/heartbeat 选择副作用保留；Native QR 当前全选四用途，Dart 登录默认
继承同 MID 用途/选择对话框，两者不能静默合并。
旧 CookieJar adapter (`cookie_jar_adapter.dart:15`、`account.dart:199`) 仅持久根域
`/` name/value；原生 store 应保存完整 domain/path/expiry 属性并标明旧数据限制。
KeychainCredentialStore 与原生 CookieStore 先旁路验证/import-restart 对照，确认
单一 authority 切换及回滚方案后才开放写入；禁止 Native/Hive 同时独立写账户。
