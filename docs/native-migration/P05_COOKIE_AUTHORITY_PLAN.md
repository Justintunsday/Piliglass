# P05 下一组：完整 Cookie 状态与单一账户写入权威

2026-10-05，基于实际 Dart/Hive writer 和已提交的 Native 源码盘点。
本文件是后续执行方案，不表示 Cookie runtime、账户存储或登录已经切换到 Native。
当前默认 writer 仍为 Accounts/Hive；schema1 只用于 Keychain shadow import。
`f834307` 修复实际 Dart golden 的 SameSite 标签，整组 CI 验收仍由 PROGRESS.md 记录。
按 [P05_GROUP_ACCEPTANCE.md](P05_GROUP_ACCEPTANCE.md) 组内并行、独立提交，组末统一
验证同一 SHA 的 release 和全部 preview；失败修复后重跑。UI 重写排在最后。

## 当前边界与下一组目标

已有 `Domain/Accounts` 四用途 snapshot/session 和 Dart adapter；
`Persistence/Accounts/PiliAccountSecretStore.swift` 保存完整的现存 Cookie 属性，
`PiliAccountStagingStore` 用隔离 Keychain namespace 与最后发布的 manifest 做 shadow
导入。`PiliNativeCookieStore` 当前是 archive storage，没有响应 mutation/删除引擎。
Native parser/selector 是纯兼容实现：只接受已分离字段，selector 限制在最多 32 条
Cookie 与 ASCII host/path 的已验证范围；它们不能授权运行时请求或开放持久化 writer。

本组先实现 schema2、真实 Dart 状态转移对照、统一 writer adapter、反向恢复；所有
能力通过 CI 和真实账户验收后才切 authority。网络 transport、签名和各登录 endpoint
仍需各自验收，不能用本组 store 完成推导 HTTP 或完整 P05 已完成。
schema1、旧 Hive adapter、Dart fallback 和 Flutter runtime 暂时保留。

## 实际 writer / reader 盘点

锁定依据为 `pubspec.lock`：CookieJar 4.0.9、Hive CE 2.20.0、Dio 5.11.1。
测试 oracle 必须调用这些实际实现，不能复制一套 Dart Cookie 算法。

| 实际入口 | 当前写入及顺序 | 本组收口位置 / 验证 |
|---|---|---|
| `lib/utils/accounts/account_manager/account_mgr.dart:193` `_saveCookies` | 正常响应、错误响应和 redirect 共用；先解析整批，按 realUri 保存，再按每个 Location 保存；每次 mutation 前与 await 后检查原 stamp，最后 `onChange` | Cookie response writer adapter；保留 original/real URL、Location 顺序、403 与取消时序；同名不能折叠 |
| `lib/services/native_http/native_http_request_lease_service.dart:250` `finish` | 先 claim 单次 terminal，验证原 owner/provenance；`:295` 更新 jar，`:302` 持久化；普通换号不撤销原账户响应 | 同一 writer adapter；未知 ack 不重放 finish/HTTP；persistenceFailed 不等于没有发生 mutation |
| `lib/utils/accounts/account.dart:83` LoginAccount.delete | revoke 原代次，jar.deleteAll；仅相同 Hive 对象 owner 才按 key 删除 | owner-scoped delete；旧同 MID 对象不能删除新凭据；重复 delete 和 await 中替换 |
| `account.dart:95` LoginAccount.onChange | 当前 owner 且未 delete 才 `_box.put`，可写 Cookie 或用途变化 | authority-aware persistence adapter；Native active 时禁止直接 Hive put |
| `account.dart:122,:148,:210` constructor / setBuvid3 | 直接补 domain `bilibili.com`、path `/` 的 buvid3，已有值不覆盖；domain 已存在但 `/` 缺失会触发现有非空假设 | 将补值作为显式有序 mutation；不另造第二份匿名 buvid，异常不能悄悄丢 bucket |
| `account.dart:158` AnonymousAccount.delete | 同一 singleton 先 revoke；activated=false、轮换 gRPC fawkes，再 deleteAll、补 buvid、启用新代次；重叠 reset 仅最新完成有效 | 匿名 reset operation；在全部完成前禁止 capture；匿名不是 Hive 登录账户 |
| `account.dart:218,:230` BiliCookieJar.fromJson/fromList | 直接安装根域 `/` map，ignoreExpires=true，重新生成创建时间；Cookie domain `.bilibili.com`、httpOnly=false | 保留旧 Cookie 登录/JSON 导入政策；新完整导入单独命名，禁止把旧输入解释成完整 attrs |
| `cookie_jar_adapter.dart:11,:15`，`account_adapter.dart:11,:26` | type8 只写根域 `/` name/value；type9 写 jar/accessKey/refresh/type；reopen 会重建对象，activated 未持久化 | Hive 原 reader/export oracle；不能原地重解释已有 typeId；明确属性已经丢失 |
| `lib/utils/accounts.dart:145,:206,:221` install/import | 替换前撤销旧 owner，pending install；Hive put/putAll 后只启用最新成功对象；普通登录继承原 type，import 使用输入 type | Account writer adapter；同 MID 并发、失败恢复旧对象不可恢复旧请求代次；import key/MID 校验 |
| `accounts.dart:251,:266,:305,:310` clear/deleteAll/临时选择/set | clear 在首个 await 前 revokeAll；deleteAll 按对象 identity；set 同时改新旧 type 并 put；临时选择只改 effective slot | Selection/credential writer adapter；四用途、临时无痕、history 回退和批量部分成功 |
| `accounts.dart:97,:128` init/refresh，`lib/http/init.dart:58,:81` | init/reconcile 注册 Hive owner；refresh 按存储迭代顺序重建 slots 并激活 buvid；buvidActive 直接改 activated | read adapter 与显式 activation 更新；refresh 不是 token 续期；保留冷启动顺序和非持久 activated 政策 |
| `lib/utils/storage.dart:110,:123,:136` compact/close/clear | account.compact/close，clear 转发 Accounts.clear | 关闭/维护也须先进入统一 barrier，不能在 migration 或在途 persistence 中关库 |

安装、选择与删除 caller 也必须经过上述 adapter，不能只改 Native bridge：

| caller | 必须保留的现有政策 |
|---|---|
| `pages/login/controller.dart:172,:623,:754` | Cookie 登录；QR/password/SMS 安装后 reset 匿名；同 MID 继承用途，必要时用途对话框 |
| `services/ios_native_ui_bridge.dart:2275` | 当前 Native QR 安装后全选四用途再 reset 匿名，不能与 Dart 默认政策混同 |
| `services/native_login/native_login_authority.dart:104,:166` | writer 仍转发 Accounts/Hive；operationID 一次性消费；每个 await 后检查原 epoch/token/generation；当前拒绝旧 Hive 无法持久的 attrs |
| `pages/about/view.dart:245,:250` | 旧登录信息 export/import 是根域格式；新完整秘密 envelope 不进入普通设置导出/日志 |
| `pages/mine/controller.dart:124,:228,:235` | main 本地删除；heartbeat 持久匿名与临时无痕是两个功能，恢复选 main |
| `pages/setting/view.dart:220,:224,:276` | 本地删除与远端 logout 分开；远端失败账户保留，只删成功的原 owner |
| `utils/login_utils.dart:25,:45,:83` | WK Cookie 镜像、userInfoCache、historyPause、AccountService 与 main 登出副作用；延迟 userInfo 失败删除必须仍指向原 owner |

WK Cookie store 是 WebView 镜像，不能反向成为 API Cookie authority。
`LoginAccount.csrf` 当前是 late final 的根域读取，`AccountManager.onRequest` 还会合并
显式 Cookie header、按 App/gRPC/CDN/NoAccount 路由；切换时都需要独立对照，不能
仅比较 CookieJar.loadForRequest。`native_account_snapshot_service.dart:53,:170`
仅只读导出；当前 flattened records 丢空 bucket，不是 schema2 或 active writer。

CA3 同时盘点 credential reader：`lib/http/{video,live,user,login}.dart` 有显式
accessKey，`http/{reply,fav,msg,dynamics,member,follow,danmaku,pgc}.dart` 等在
拦截器之前读取 csrf；`account_mgr.dart:66,:71,:82` 读取 gRPC/header/accessKey。
NativeActive 下这些读取及 `Accounts.account.values/toMap/isEmpty` 的页面读取须
经同一 authority 的 proxy/read adapter。同步旧 Account 镜像只能是只读展示缓存；
不能凭过时缓存组装 csrf、签名和另一 owner 的 Cookie。请求构造前取得同一原生
request context，验证原 owner 再发送；writer 接入完成但 reader 未收口时不得切换。

## schema2：完整有序 jar，不从 schema1 猜历史

新增独立有界 DTO / strict codec，不改变现有 schema1 decoder 的含义。建议 envelope
字段分工如下；具体名称在 CA1 固定，未实现前不是已支持 wire。

| 层 | 必须保留的信息 |
|---|---|
| envelope | schemaVersion=2、source app/dependency version、export ID、authority kind/epoch/revision、snapshot 与导出一致性证据 |
| account record | active 前需要 durable record ID；只读 shadow 未配置时明确标记 capture/shadow scope；MID、原 storage key、凭据、持久用途及两种实际账户顺序分开保存；ownerToken/generation 不能由 MID 推导 |
| jar | ignoreExpires；domainBuckets 与 hostBuckets 分开的有序数组；空数组也保留；来源 live / legacyHiveReopened / schema1Derived 及缺失属性/顺序标记 |
| domain/host bucket | 原 bucket key 的 UTF-16 code units、有序 pathBuckets；**空 domain key 和没有 path 的 bucket 均可表达** |
| path bucket | 原 path key、有序 cookieEntries；**空 path key 和空 name map 均可表达**，不能过滤“没有 Cookie”的 bucket |
| cookie entry | 原 name/value、可空的 cookieDomain/cookiePath（与 bucket key 分离）、secure/httpOnly、SameSite 标签、expiresMicroseconds、maxAgeSeconds、createdSeconds |

数组位置是三层 Map 的插入顺序，替换现有键不移动位置，删除后重插才追加。
键 equality/hash 使用拥有的 UTF-16 code units；Swift String/Dictionary/Set 的规范
等价不能合并 Dart 区分的键。JSON 对象的成员顺序不能承载契约，nil 与空字符串区分。
非成对 surrogate 若不能无损表达，应保留原 code units 或显式 unsupported，不能
用 Swift replacement character 合并键；支持范围要在请求发送之前检查。
SameSite 以实际 Dart `SameSite.name` 的 `Strict` / `Lax` / `None` 导出，null 单独保留。
新增总字节/bucket/entry/字符串限额；超过限额或坏字段显式失败且不发布，不能截断。

schema1 可以在旁路中升级为 marked-incomplete schema2：只能保留现存非空记录
及已知顺序，不能宣称恢复空 bucket 或完整过去状态。active authority 初始输入必须
从冻结后的**实际 live Dart jar**重新导出 schema2；Hive reopen 数据保留实际损失标记，
不补造 expiry/Secure/host/path。Native restart 保存完整新属性是明确持久化改进，
和旧 Hive reopen 的丢属性行为分别验收。

账户顺序不能用当前按 MID 数值排序的公共 descriptors 代替。实际锁定的 Hive CE
2.20.0 使用 defaultKeyComparator；String keys 按 String.compareTo 排序，values/toMap
沿同一顺序，并非安装插入历史。`Accounts.refresh` 则遍历私有 `_owners.values` 的
Map 顺序；同 key 替换先删除旧 owner 再追加新 owner，live 顺序可能与 Hive/冷启动
不同。两种顺序都需从实际来源复制，多个相同持久用途仍由 refresh 最后迭代者覆盖。
旧 snapshot `_temporary` 又沿 Hive.values 计算，不能用它反推 live owner 顺序。
导出分别保留持久用途、两种顺序及四个 effective selections/history，不重算旧政策。
重启保留旧“临时选择不落库、匿名 session 重建、activated=false”政策。
durable record ID 不是请求授权身份；重启和 authority handoff 生成新 epoch 与运行时
owner 代次，旧 lease/bridge callback 不得在新 session 中复活。

## CA1–CA6 有限实施切片

| 切片 | 具体交付 | 停止边界 / 验证 |
|---|---|---|
| CA1 有序格式与 exporter | 新 schema2 DTO/codec；真实 Dart 两类三层 Map 导出；Native shadow importer；记录旧 schema 损失 | 不切 writer；实际空 domain/path/name buckets、overwrite/remove/reinsert、同 MID、顺序冲突、Hive reopen、重复导入及 Keychain restart |
| CA2 Cookie 状态转移 | 纯 Native ordered jar reducer、注入 clock 的 batch apply/expiry/delete；生产 store 的单账户事务 | 从真实 CookieJar 生成操作轨迹与每步完整 jar/header；不联网、不切 writer；超过支持范围保持显式 unsupported |
| CA3 统一 authority adapter | Dart 所有已盘点 mutation/Hive/lifecycle 收口；Native Account/Cookie/Selection authority protocol；默认 Dart 实现和 credential reader adapter | writer 与 reader 分别提交；Dart 回归行为不变；旧 caller 不得有旁路写；barrier/await/同 MID/取消竞态 fixture；actor await 可重入也须受 operation gate 控制 |
| CA4 durable 交接与回退 | authority marker、冻结/排空/导出/发布协调器；兼容完整 reverse-import reader；crash phase recovery | 仅 sandbox/synthetic 启用；每个持久化/ack 边界故障注入；旧 schema1 不升 active；无 Native/Hive 双写 |
| CA5 真实账户候选验收 | Native active + Dart proxy 的 opt-in composition，登录/UI caller 继续同一 authority；四用途/main 副作用重放 | CA1–4 同 SHA 完整 CI 通过后，在测试设备验收四种登录、多账户、实际响应 attrs、杀进程/重启及回退；无凭据入 artifacts |
| CA6 按证据开放默认 | 只有已验收 capability 开放；更新状态、缺口与回退说明 | CI/真实账户不全则保持 Dart 默认；不删除旧 reader、Flutter、Dart runtime；不把其他 P05/P06 领域自动标完成 |

CA1 与 CA3 的默认 Dart adapter 可并行；CA2 依赖 CA1；CA4 依赖 CA1/CA3 和
CA2 的 mutation 契约，CA5/CA6 顺序进行。每个切片独立小提交；格式、reducer、
writer 接入和开关变更不能塞进一次不可回滚提交。新增 Swift 文件保持
Domain/Accounts、Data/Accounts、Persistence/Accounts、Networking 的边界；
UI 只调用 Repository/Feature State，AetherEngine 不读取这些 store。

### CA1 第一组实施范围：jar-only shadow 格式

首个有限交付只表达 jar，不把当前公共 snapshot 的 MID 排序当成账户存储顺序，
不新增账户 envelope、durable record ID、authority handoff 或 bridge 命令。账户级
一致性、全部用途和 schema2 反向恢复属于后续切片。

`NativeOrderedCookieJarExporter` 同步复制真实 live maps；jar2 的 domainBuckets /
hostBuckets、paths、cookies 均为有序数组。所有键和 Cookie String 是 raw UTF16
units，cookie map key 与 Cookie.name 分开；nullable 字段必须存在且为 null 或值。
provenance 区分 unknown / legacyHiveReopened，始终明确无法证明过去 Hive 属性
完整，currentBucketOrderComplete 只表示本次捕获的现有 maps。UTF16 格式支持不
扩大已有网络 selector 的 ASCII / 至多32条范围。

硬上限：16MiB JSON、深度32、3Mi JSON nodes、2Mi UTF16 units、8192个 outer/path
buckets、16384个 entries；key/domain/path 4096 units、name1024、value65536。
Swift strict codec 拒绝重复字段/键、缺失 null、类型与数值越界、超出资源限额；
原始整数 token 保留 Int64，expiry 限于实际 Dart DateTime 范围。空 bucket 与原
数组顺序全量保存，超过支持范围直接失败，不截断。

新 jar-only staging actor 使用独立 Keychain namespace、不可变记录、内容摘要及
唯一 manifest。先全量验证、写候选、实际 reread，再发布；write-then-error 通过
读回指针确认，无法确定时保留旧/新记录并返回 publicationUnknown。actor await
期间有显式 operation gate。没有 live account identity、Native writer 或请求权限。
进程中断的未引用候选清理及账户级事务恢复留 CA4，不把 shadow manifest 当
authority marker；shadow 不能作为旧 Hive 的自动兜底来源。

实际 golden 调用生产 CookieJar / Cookie parser / AccountManager 与 Hive type8；
保存15个格式 case、9组状态轨迹、真实 reopen 属性损失。creation/expiry 无可注入
生产 clock，时间窗口实测；Int64/DateTime 极限只作为标记的 synthetic seed。
Native harness 对照原 Dart JSON 结构和数组顺序，不只检查同 codec 自洽；真实
Keychain restart 消费 fullattrs 和 UTF16 jars。故障测试用不同第二份 jar 区分旧/新
指针，覆盖候选失败、写后错误、未知确认、损坏记录、await 重入与重复导入。

本组在 `0527fb2de6c00baded5a53f7dcbc8ae6661da6ec` 同 SHA
[release5](https://github.com/Justintunsday/Piliglass/actions/runs/37374811289) 与
[preview4](https://github.com/Justintunsday/Piliglass/actions/runs/37374822907) 全成功。
实际 producer18、Swift6 codec155、真实Keychain staging36、完整Runner及7合同门禁
通过；只接受 jar format/shadow 边界，不表示 CA1 全部账户 envelope、CA2 mutation
engine 或 P05 已完成。压力数量/功能通过，时延单样本异常仍未验收，见 PROGRESS。

### CA1 下一账户 envelope：只读准备边界

新增 Accounts 内部同步复制接口，分别捕获 Box.toMap 的当前 key 顺序、私有 owner
Map 顺序、exact object/stamp、四 selections/history、revision 和 pending/reset 状态。
不能公开可变 Map、调用 refresh/reconcile 或触发 buvid。原 storage key 不能由数值
MID 规范化，account equality 也不能用于合并同 MID successor。未知/坏 stored entry
显式失败，不能过滤后发布不完整列表。旧 schema1 两命令和 DTO 保持原语义。

新 service 在同一个无 await 段复制完整 jar2、credentials/type/activated及两种顺序；
checkpoint 后全量 re-capture 对照，不只复用旧 public descriptor/revision 检查。
必须设置整份 envelope 的累计限额，不能累积256份各16MiB后才检查。任一变化或
越界不发布；一个 manifest 发布账户集合和 selections，不逐账户零散替换。

当前 type9 没有 durable UUID；epoch/ownerToken/generation 都是运行时身份。
下一 shadow 可用 capture-local candidateRecordID 关联同一候选，但明确 durable
identity 未配置，不能把 MID、随机 token 或 shadow 重启恢复当成 Dart owner 跨
冷启动连续。active durable ID registry 留给有 writer lifecycle 屏障的后续切片。

Hive put 的新值在 backend await 完成前即可见；read/recheck 不能证明全部响应、
Cookie/用途更新及持久化已排空。合法停止边界是 coherent live-memory shadow，
durabilityVerified/authoritySwitchAllowed 继续 false；flush 不等于冻结或交接。
矩阵补充：字符串 key 10/2 与数值顺序冲突、同 MID 替换后两种顺序分歧、实际冷
启动、四用途/history、未 notify 的 raw jar 更新、pending/reset/unknown entry、
全量 shadow 重启和未知 ack。CA3/CA4 完成前不从此 envelope 安装 active writer。

2026-10-06 下一只读 capture 的实现边界补充：入口留 Accounts 内部，直接纯读
`_requestState.capture/isCurrent`。不能复用 public captureRequest/ownsCredentials，
后者会为匿名 activate；未注册匿名明确 unavailable，捕获不 reconcile/refresh。
读取匿名还必须从原active stamp取得已有对象，不能调用匿名factory后才检查注册；
否则dormant捕获会初始化Cookie/协议随机状态。新增纯registry类型查询只读原stamp。
pending install/reset 令整个捕获 busy，不过滤未知/retired/错key的存储对象；exact
object/stamp 与 raw storage key、Box顺序、owner顺序、四slots/history全量保存。
共享累计预算约束256 records（含匿名）、16MiB wire、2Mi UTF16 units、8192 buckets、
16384 entries及节点/深度，先检查再复制，不能为每jar单独开上限后拼巨量envelope。
checkpoint后重新完整复制并逐字段对照，包括无notify的jar/type/activated变化；
opaque原引用只用于进程内复核，公开payload深不可变。保留captureLocal身份、
durabilityVerified=false/authoritySwitchAllowed=false；这份只读候选不发布manifest。
下一实际测试须包含'02'/'2' distinct owners、独立cold-init isolate、pending真实Hive
内存可见、raw未notify变更和跨账户累积越界；不使用fakeHive或公开可变owner Map。

本组具体接入为 Accounts library 的独立 part 与薄 capture service；原账户私有
lifecycle不搬出库，不向service暴露可变Account引用。公开payload全部deep-owned /
unmodifiable，private stamp/object只供复核。共享ledger在每次UTF16/bucket/entry
复制前记账；固定jar shape计JSON value nodes，最大嵌套含envelope不超过12。
metadata保守预留固定64+每record40nodes、固定2048+每record512units，覆盖固定
字段/枚举值；rawkey/凭据/全部jar units另按实际长度累计，不能添加任意新字段
绕过ledger。实际JSON byte计数使用非const JsonUtf8Encoder的chunk sink，不缓存
完整UTF8编码再查大小。新producer不发布Keychain/bridge/authority，只读候选。
新增19项case覆盖真实Hive双顺序/rawMID/four slots/pending/reset/unknown entries/
无notify变更/累积bucket、units、entries/255+匿名容量、deep ownership，以及独立
dormant/cold-init和JSON framing字节计数；尚待同SHA完整Actions实际验证。

### CA2 必须对照的 mutation / selection 语义

2026-10-06 已验收有限切片的范围（精确构建 `74101fad17d57933e85c965708ef70052cf74e6a`）：

| 组件 | 实施状态 / 本组验证 | 仍未交付的边界 |
|---|---|---|
| CA3 response / legacy persistence port | 默认实现同步转发真实 Dart jar / Hive；四个新增实际账户测试随105-test suite通过，同SHA release5/preview4成功 | install/delete/selection/activation/maintenance、credential reader、完整 writer barrier |
| CA2 ordered mutation candidate | `PiliNativeOrderedCookieReducer` 纯值 save/delete/deleteAll；Swift6 complete concurrency与独立真实 Dart 9轨迹/34步/43headers共271 checks通过 | 生产单账户事务、账户身份/写权限、durable commit、运行时安装 |
| CA2 集成与门禁 | Runner source实际构建；mutation driver消费同job新ordered goldens；独立artifact与8个mandatory outcomes同SHA全成功 | 仅纯值candidate验收，未提供生产store事务或authority |

真实 Cookie 创建读的是秒级 wall clock，Native batch 本切片注入单一 clock。
短创建操作在实际秒的前半段开始，仍记录并断言实际 started/finished 同秒；跨秒
证据明确失败，不重试 mutation、不跳过 snapshot/header、不从 expected jar 安装
Native 输入。waitRealWallTime 保留真实等待与过期观测。人工 DateTime/Int64 极限
只是显式注入的格式边界，不能声称实际 Dart clock 的精确边界已证明。
本组保持 runtime/authority 关闭；同 SHA 实际编译失败继续修复，不标记 P05 完成。

- 整批 raw fields 先解析成功，再按原顺序 apply；坏第 N 条不得留下前 N-1 条写入。
  provenance 独立保存；FoundationCombined 或无法确定的字段边界不以猜测拆分入库。
- domain 属性非 nil 时只去一个 leading dot，默认 bucket path `/`；host-only 用
  uri.host 与原 `_curDir`：空请求 path 是 `/`，请求 `/video` 会得到空 path bucket。
  可空原 cookiePath 不变，不能用 bucket path 回填后改变最终排序。
- 同 bucket/name overwrite 保留键位置并重置 creation seconds；expired replacement
  会删 name，却保留 domain/path 空 maps。之后重插会追加 name，原 bucket 顺序不变。
- ignoreExpires=true 不删除/过滤过期 Cookie。否则 maxAge<1、elapsed>=maxAge 或
  expires<=now 任一成立即过期；旧实现同时检查 maxAge 和 expires，不能套标准优先级。
  实际 SerializableCookie 在每次构造时读取 wall clock、保存秒级 creation，expiry
  则用 DateTime 的实际精度。Native reducer 注入明确 wall-clock 值；真实 Dart 的
  started/finished 时间窗口与 unchanged creation 分别验证，不能把格式测试中人工
  种入的 Int64/DateTime 极限值当成已验证的 clock/溢出语义。
- load 的 host-only 在前，其 path 按 UTF-16 长度降序；domain 部分按三层插入顺序。
  最后 AccountManager 再按**原 Cookie.path** nil 优先/长度降序，保留重复 name。
  大集合的 Dart sort tie 行为与 Unicode URI/小写转换未对齐前不扩大 selector 门禁。
- 旧 path 匹配忽略大小写；旧 `_check` 是 `(secure && HTTPS) || !expired`，存在
  Secure/HTTP 与 expired/Secure/HTTPS 的非标准行为。compatibility mode 显式记录；
  安全政策修正独立提交与验收，不能偷偷改变 golden 或把兼容 helper 当网络授权。
- jar.delete(uri,false) 删除 exact host 整个 bucket 并忽略 path；true 再删除匹配的
  domain buckets。生产当前主要调用 deleteAll；仍测试 delete 的全量语义再开放 API。
  deleteAll 清两类 maps；匿名补 buvid/reset 是上层操作，不由 reducer 自动重建登录。

## 单一 writer 屏障与 durable handoff

CA3 第一独立切片先引入同步 forwarding 的 response Cookie mutation / nullable
legacy persistence port，仅收口 AccountManager、Native HTTP lease 两个响应写者和
LoginAccount.onChange。默认 Dart 实现不加 async wrapper，不先 await gate 再改变
jar/Hive 内存；原 parser、redirect 顺序、claim、owner检查、notify与await复核位置保留。
onChange 的私有删除 guard 留原库，port不反调onChange形成递归。install/delete/
selection/activation/constructors/maintenance与同步csrf/accessKey读者留后续切片，
不能把这一小接口叫完整 writer barrier。Hive backend 已写入后 compaction 仍可抛错；
Future failure不证明durable未写入，不因错误ack自动回滚或重放操作。

下一有限 CA3 切片为 install/import 持久化转发（上组完整CI已通过，进入实施）：
独占新增 `account_install_persistence_port.dart`、`accounts.dart`
的两处 put/putAll 与一份实际 Hive 测试。默认方法接调用方原 Box/key/candidate/map，
同步直接返回原 Future；不重排 map、不拆 bulk、不先 await，也不调用 ownsCredentials
拒绝合法 pending candidate。`_beginInstall/_completeInstall/_failInstall`、私有
pending/retired/owner guard、refresh及catch/rethrow全部留原位置。
新增验证只补实际安装/import在await前Box可见而candidate不可capture、await后新
generation，以及production type9编码失败后旧stamp不能因Hive回滚或refresh复活。
这仍不覆盖delete/reset/selection/activation/constructor/maintenance/readers，
不引入authority开关，也不宣称编码失败证明后端未写入或完整writer已冻结。

同一下一验证组另拆 LoginAccount 删除转发切片：新增 `AccountDeletionPort`，默认
Dart 实现同步返回原 jar.deleteAll / Box.delete Future。caller 的 `_hasDelete`、
revoke、先启动 jar 清空、随后 exact Box object 判定及 Future.wait 顺序保持原样；
不能以 ownsCredentials 拒绝已 revoke 的合法删除，也不能用 MID 查询 successor
作为删除目标。匿名 reset 和 Accounts.clear 留后续切片。本组仅补删除开始后的
即时 jar/Box 状态、在途删除后安装同 MID successor、jar 完成错误不复活旧请求的
实际 Hive 回归；错误不证明两项删除都没发生，不自动回滚或重试。两切片分别
commit/push，汇合后同一 SHA release5 + preview4 全部实际验收。

上述安装/import与LoginAccount删除转发在`74e8a4d7e919e3ff80047bb68be69b20f70c3246`
同SHA release5/preview4全成功；实际112账户tests中新增7项全部通过，8强制门禁及
Runner/Aether顺序通过。仅接受两项legacy forwarding边界，下一只读capture仍须
新组验收；完整writer/reader/barrier及NativeActive门禁继续保留。

统一 coordinator 状态为 DartActive → Transitioning → NativeActive；反向为
NativeActive → Reverting → DartActive。authority marker 与 phase journal 只保存
非秘密元数据；完整 Cookie/Token、candidate manifest 和回退数据均留安全 store。
Keychain 的多 key 不是整体事务：先写不可变候选记录，再原子发布单个 manifest/marker
引用；跨步骤恢复以已发布指针为准，不能以内存 bool 或某次 bridge ack 判定 authority。

1. **先收口，仍 DartActive。** prepare/read/响应写回、登录安装、选择、activated、
   clear/delete、import、buvid reset、Hive onChange/close 均经 adapter。Dart 同步
   `saveFromResponse` 与 Hive 内存 put 不会等 Future 才 mutation，检查必须紧邻实际
   写入；已有直接 mutable type/activated 和构造器补值也纳入 barrier。
2. **冻结入口并排空旧写任务。** Transitioning 不接收新的账户请求或 mutation，取消
   未发送 prepare；等待已 claim 的 response/安装/持久化终结至明确 receipt。不能用
   timeout 声明旧 writer 已停止；未知结果不重试写请求/切 native，保留 closed gate。
   记录排空结果后撤销旧 epoch 全部请求身份，阻断迟到 Dio/lease/登录副作用。
3. **在屏障内捕获 live schema2。** 同步复制所有 owner/stamp/revision、账户顺序和
   完整 jar，跨 await 后核对；原 owner、选择或 jar 不一致就废弃候选，不发布。
   Import candidate 全验证、durable 写入、完整 reread 对照成功后再发布指针。
4. **单点提交 authority。** marker 发布为 NativeActive 的步骤是唯一切换点。
   重新建立新 epoch/owner session 与实际 selections 后解除屏障。Flutter 留存 caller
   通过 Dart proxy 调 Native authority，既有 Hive 只冻结留作旧快照，不能继续独立 put。
   proxy 返回明确 receipt；未知 ack 不因 fallback 再执行一次 mutation。
5. **恢复先读 durable marker。** 发布前崩溃保持 Dart authority，候选可丢弃；发布后
   崩溃一律按 Native 指针恢复并保持 Hive writer 关闭。未完成 phase 在开放页面/网络前
   恢复，坏 manifest/较新 schema/锁定 Keychain 时保持关闭，不能静默读旧 Hive 顶替。

Native account actor 的串行边界覆盖每个 mutation 与 durable commit；await 允许
actor reentry，必须排队或显式 operation gate。响应写回验证原 epoch/ownerToken/
generation，不能只看 MID，也不能用 selection revision 丢弃其他有效在途响应。
Cookie/用途/activated 更新提高 revision；凭据替换、delete/clear、匿名 reset 撤销代次。
普通 A→B→A 或暂时选择不重绑请求。同 MID 新凭据与远端 logout 的本地删除均按原
owner 处理，原请求失效不删除 successor。错误 receipt 区分未 apply、已 apply 未
durable、durable、结果未知；任何部分成功不得对新 owner 做自动回滚或 HTTP 重放。
CA3/CA4 明确现 Dart memory-before-durability 与新事务发布时机的差异并实际验证。

## rollback / reverse export

未切换时只丢弃隔离 shadow，Dart/Hive 数据不动。切换后 **不能直接开旧 Hive**：
Native 已新增或删除的账户、完整 attrs、顺序、四用途会丢失或复活旧账号。

CA4 在开放 NativeActive 前必须提供能读取 schema2 的 Dart compatibility adapter。
旧 type8/type9 ID 与旧 JSON export 保留；完整反向 envelope/独立有版本 store 按
Native 当前全量状态恢复，包括删除 tombstone 或完整 replacement，不能只合并新增。
兼容 reader 重建有序 maps/创建时间/ignoreExpires，并通过 Accounts 的 owner 注册
路径启用新 session；旧 adapter 的 root name/value 文件不能承载这份恢复结果。
秘密恢复数据使用安全通道/安全 store，不写普通 Hive sidecar、设置导出或日志。

回退同样冻结并排空 Native writer，反向导出当前 durable manifest，先写兼容候选，
实际 reread 与请求 header 对照后单点发布 DartActive，新 epoch 启用再解除屏障。
失败保留 NativeActive，未知 ack 不重导/重复写。测试回退中崩溃后的两侧恢复、
Native 新登录/同 MID 替换/删除后回退、再迁移，以及所有 full attrs/order 无损。
回退到未带 schema2 reader 的旧二进制无法无损恢复：CA5 之前明确支持版本边界与
升级/降级恢复路径，不能将“旧 Hive 还在”称为可回退能力。

## 验收与证据

| 层次 | 必需证据 |
|---|---|
| 实际 Dart golden | 调用真实 Cookie.fromSetCookieValue、DefaultCookieJar/save/load/delete、AccountManager.getCookies；按步骤导出完整 schema2 与 header；实际 Hive write/close/reopen 单独记录损失 |
| Native production fixture | Swift 6 complete concurrency 编译实际 DTO/reducer/store/coordinator；同份 Dart 轨迹逐步比较，真实 Security Keychain write/read/update/delete 与 fresh actor restart；缺 goldens/平台 skip 都失败 |
| 故障与所有权 | 批中坏字段、重复 terminal、取消、未知 ack、每个 Keychain/manifest/marker 写失败、进程中断；同 MID 替换、clear/import、旧 response、匿名同对象 reset 与乱序 snapshot |
| 完整 iOS CI | 定向 Dart analyze 保留 fatal-infos；现 `flutter test --no-pub --reporter expanded test/utils/accounts/`、`python3 tool/check_native_accounts.py`、`python3 tool/check_native_cookies.py`；新增 CA2–4 fixture 独立 job/强制汇合门禁；完整 Runner/release 与全部 ios-home-preview 同 SHA 成功 |
| 真实账户/设备 | QR/password/SMS/Cookie 与 Geetest/手机验证路径；四个不同用途账户及共享账户、临时无痕/history fallback；main WK/cache/history 副作用、服务端错误/redirect Cookie、远端部分退出失败、本地删除；杀进程/重启、Keychain 锁定/解锁、Native 写后 reverse restore |

golden/Actions artifacts 只含 synthetic 凭据。真实账户报告记录功能结果、脱敏 owner
变化、构建 SHA、设备/系统与重启恢复结果，不采集 Token/Cookie/认证头正文。
冷启动验证 session identity 轮换和持久值，不要求旧请求授权 token 跨重启一致。
正常 API 读取和有写副作用的操作分开验证；登录未验收不能以页面打开替代。

组末检查 git diff 与资源 → 分切片 commit/push → 同 SHA Actions → 下载实际
日志/artifacts → 修复/再提交/重跑，直到所有必需门禁成功。CI 未成功只能记“已实现，
未验收”；真实账户未成功不能开放默认 authority 或删除 Dart fallback。并行收集
诊断时仍以强制 aggregate outcome 为准，不能用 step 的表面 success 或 Runner 编译
成功覆盖 fixture failure。CA6 的状态更新必须列出依赖 Dart 的剩余路径。
