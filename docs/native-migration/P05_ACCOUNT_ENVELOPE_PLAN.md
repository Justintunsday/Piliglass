# P05 下一最小切片：完整账户 capture-local Native DTO / strict codec

2026-10-07。实施前保存的下一组执行计划，不是实现、CI 验收或 authority 切换证明。
前置 capture 组 `6673e38` 已完成同 SHA release5 + preview4；现按本计划接入本组生产代码。
本组不创建 Keychain 集合 manifest、bridge 命令、Native writer、runtime 开关或新 UI。

## 实际来源与可以复用的边界

- `lib/utils/accounts/account_live_memory_shadow.dart` 当前同步捕获真实 Box.toMap
  顺序与 `_owners.entries` 顺序；使用 identity HashMap，为匿名分配 record 0，
  登录账户沿 storedOrder 分配连续 ordinal。key 从 storageKey 原样复制。
- `lib/services/native_accounts/native_account_live_memory_capture.dart` checkpoint
  后完整 recapture。opaque object/stamp 引用只留在 Dart 进程内；公开树 deeply
  unmodifiable。相同端点不能证明 await 期间 writer 冻结或已 durable commit。
- `lib/services/native_accounts/native_ordered_cookie_jar_export.dart` 的真实 jar2
  使用 raw UTF16 arrays，保留空 bucket、map key 与 Cookie.name 分离、nullable attrs、
  ignoreExpires 和 current-only provenance。整个 capture 共用一个累计 ledger。
- `ios/Runner/Native/Domain/Accounts/PiliOrderedCookieArchive.swift` 已有 owned
  Sendable / Equatable UTF16、jar2 DTO 与完整属性验证，可以直接复用。
- `ios/Runner/Native/Data/Accounts/PiliOrderedCookieArchiveCodec.swift` 已有 strict
  JSON grammar tokenizer：raw integer token、UTF8 验证、raw UTF16 string/escaped
  surrogate、重复键、深度和节点计数。不能用 Foundation dictionary 替换它。
- `PiliAccountSelectionSnapshot.validated()` 是旧 schema1 契约，要求唯一 MID、
  mid>=0、isLogin==(mid>0)、匿名 persistedPurposes 为空。它不能用于新 envelope。
  `PiliAccountStagingBridgeCodec` / 旧 credential records / schema1 staging 也不能
  作为新的完整账户 reader；不得改变旧 schema1 验证来容纳新格式。

## 最小交付与文件边界

一个 Domain 文件：`Domain/Accounts/PiliAccountLiveMemoryShadow.swift`，仅完整
envelope、record、raw-key/order-entry DTO 与 validation。`let` 值与拥有的数组；
全部 Sendable / Equatable，显式 nil encoding，capability flags 固定 false。
purpose 可复用 `PiliAccountPurpose` 枚举，但 `persistedPurposes` 保存有序数组，
不能转 Set 后丢失实际 Dart Set 迭代顺序。

一个 Data 文件：`Data/Accounts/PiliAccountLiveMemoryShadowCodec.swift`，纯 bounded
decode/encode，没有 URL、账户 registry、actor、store、UIKit 或 Flutter 引用。
不创建未来 Native repository/authority 的空壳 class；不复用 public descriptor 的
MID 排序或旧 bridge projection。

测试/driver 独立文件与 PBX source membership 是本组接线；jar codec 如需极小
共享改动必须保留它原来的 decode/encode 和错误契约，并跑现有 jar155、staging36
与 mutation271 suites，具体数量以新 SHA 实际输出为准。

## 新 envelope 精确约束

顶层 exact keys 与生产 capture 一致：schemaVersion、scope、identityScope、revision、
durableIdentityConfigured、durabilityVerified、authoritySwitchAllowed、nativeWritesAllowed、
records、storedOrder、ownerOrder、selectionPurposes、selections、history。
schemaVersion=2；scope=coherentLiveMemoryShadow；identityScope=captureLocal；四个
能力 bool 必须实际 JSON false，不能接受 0、字符串或自动 coercion。

每 record exact keys：record、generation、storageKeyUnits、mid、isLogin、
accessKeyUnits、refreshTokenUnits、persistedPurposes、activated、jar。
record 是本 envelope ordinal：records[i].record==i，1...256 条，0 是唯一匿名。
generation 为 actual Dart registry 正 Int64，revision 非负 Int64；可检查本候选
generation 唯一，不能将它与另一个进程、重启或候选相比后恢复授权。
所有数值从原 integer token 解析，拒绝 Bool、1.0、1e0 和 Int64 overflow。

record 0 保留 isLogin=false、mid=0、storageKeyUnits=null、credentials=null 的
实际匿名契约；**persistedPurposes 可以非空**。`Accounts.set` 对 AnonymousAccount
真实可变 type.add；不因 isLogin=false 删除用途。其余 record isLogin=true，
storageKeyUnits 必须是拥有的 raw UTF16；**MID 不需要正、不需要唯一**。
生产测试已覆盖 '02'/'2' 两个 exact owner 同 MID，以及 '0' / '-2' 登录对象。
不从 jar 的可变 DedeUserID 重新推导 storageKey/MID：LoginAccount 是 late final
缓存 `_midStr`/mid，原 jar 可被无通知改写。也不把 raw key 规范化成数值字符串。
不自行声称 Swift decimal parser 等价 Dart int.parse 的所有可接受输入。

storedOrder 与 ownerOrder 分开保存，均有 N-1 个 exact {keyUnits,record} entries，
不含匿名；每登录 record 恰好一次、无重复 raw UTF16 key、key 与 referenced record
storageKeyUnits 完全一致。storedOrder 顺序应对应 records[1...] 的 capture ordinal；
ownerOrder 可以是任意排列，不排序、不要求等于 storedOrder。不能用 Swift String
equality 合并组合字符或 unpaired surrogate；两张表的 key equality 用 UTF16 units。

selectionPurposes 必须实际固定 ['main','heartbeat','recommend','video']，selections
长度4、每值为有效 ordinal。history 也必须引用同一 envelope：当前真实 Accounts.history
政策是 heartbeat record.isLogin 时取 heartbeat，否则取 main；零 MID 的登录对象
仍因 isLogin=true 被选为 history，不按 MID>0 判断。不按 persistedPurposes 重算
effective selections；temporary slots 和持久用途可以不同。

每 jar 保留已有 jar2 exact/provenance/attribute/order 契约，不复制另一个解析算法。
完整 envelope 只比较 coherent memory 内容；decode 成功不意味着冻结、落库、
跨重启连续身份、Native 请求 context 或 durable authority。

## tokenizer / 累计预算的最小共享方案

现 parser/value/pair 是同一 codec 文件内的 private types。最小方案是将它们变为
模块 internal（维持现名字），让新 codec 一次 parse 完整 envelope；向 jar codec
增加 internal `decodeValue` 或同等 value projection entry，现 public decode 仍走
同一 parser + 原验证。嵌套 jar 必须消费已解析的 value，不能每 jar JSON encode
后重 parse、也不能每 record 重置 parser/node 预算。

如果抽成独立 Networking/Data strict JSON 文件，必须同时修复所有 swiftc driver
显式 source lists/glob 与 PBX；当前 `check_native_ordered_cookies.py` 只 glob
`PiliOrderedCookie*.swift`，重命名会漏编。首组无需为了命名洁癖做大范围搬迁。
parser 错误可内部映射到独立 envelope error；不可静默 fallback 到 JSONDecoder。

全树 parse 前查16MiB；整个 parse 最大depth32、3Mi nodes，现 tokenizer 连 object
key 都计 node；严格 UTF8/重复 escape alias 与 raw整数规则保留。exact schema
projection 拒绝未知/缺失 keys 和漏掉的 nullable field。

Domain validation 共用一个累计 ledger：UTF16<=2Mi、buckets<=8192（outer+path，
含空 bucket）、cookies<=16384、最多256 records 含匿名；key/domain/path<=4096、
name<=1024、credential/value<=65536。先比较剩余额度再加，避免 Int overflow。
jar.validated() 当前每次重置 buckets/cookies/units；仅逐 jar 调它**不能**证明总预算。
最小可复用抽取是 jar validation 添加 internal inout ledger helper，原 standalone
validated 创建 ledger 后调用；新 envelope 为所有 jars 和 metadata 使用同一个。

Dart capture metadata 另保守预留 `2048+512*records.count` UTF16 units、
`64+40*records.count` export nodes；storageKey 在 records 与两顺序表重复计量，
credentials 和所有 jar strings 另计。Native budget 应明确保留相同 units reservation，
并把每一次 wire 表达重复字符串也计入；不能只对 unique secret/key 记账。
parser exact nodes 与 exporter 保守 nodes 是两种检查，二者均保留各自上限；
不要声称其计数定义相同。encode 后同一完整 strict decode 再查 wire/depth/nodes，
防止直接构造 DTO 绕过 wire 预算。标准限额只能下调，不能用 test options 提升。

## 实际 Dart golden / Native 独立 oracle

新 `native_account_live_memory_golden_test.dart` 使用真实 AccountTestStorage/Hive、
production LoginAccount/CookieJar、Accounts.install/import/selection 与 capture service，
只放 synthetic secrets。tearDownAll 写 `build/native-account-envelope-check/capture.json`；
driver 运行前删旧文件并要求 fresh producer pass + sha256，不拷贝历史文件冒充输入。
producer 包含独立 case id 和 setup 的 raw key/用途等明确 fixture 意图；序列化的
envelope 是实际 capture.value，不能在测试里拼另一套期望 capture 算法。

最小正样本：空登录集合/匿名；'2' 后 '10' 两顺序冲突；替换 '2' 的 owner 追加；
'02'/'2' distinct owner 同 MID；'0'/'-2' 登录；四用途与临时匿名/history；匿名
非空 type（只为增加 type 的 case 可直接真实 anonymous.type.add，另核查实际
Accounts.set 的已有 suite）；空桶、rawUTF16（含 unpaired/composed）、nullable
credential 与真实 response attrs。冷初始化 case 在独立 Dart test isolate 生成
单独 cold.json，确认 type9 reopen 的 activated=false/实际属性损失与冷顺序。
绝不把在 live capture 中 unknown 的 provenance 改成 legacyHiveReopened 来补猜历史。

Native harness 在 Swift6 complete concurrency 下编译**实际生产 DTO/codec**，
decode actual Dart goldens；将重新 encode 的 JSON 与原 Dart 全树逐字段比较，
保留全部 array 顺序与 nil。这个比较使用独立 JSON structural walker/原 tokens，
不只 `decode(encode(dto))==dto`；完整 jar attrs 不以 expected DTO 自己生成 oracle。
同时检查外部 fixture setup 意图，确保 stored vs owner divergence、02/2 同MID和
anonymous purposes 不被误丢。record ordinal 和 generation 只比较原捕获值，
不套 durable UUID 或 timestamp identity，不把创建时间改写成 expected 输入。

负例从 actual wire 做单处明确破坏，每例验证具体错误：duplicate/escaped-duplicate
顶层或深层字段、invalid UTF8、缺失 nullable、unknown fields、Bool-as-int/float/
exponent/Int64overflow、flag true、record gap/重复/匿名位置、两顺序漏项/错key/
重复引用、purpose顺序/重复/未知、dangling selection/history、history政策不一致。
资源 tests 包括两份 individually valid jar 累计超 units/buckets/entries；rawkey与
credentials 累计；256含匿名边界、wire/depth/nodes 边界。人工容量/数字 seed 明确
标 synthetic representation，不冒充 actual Dart 运行时极限或 durable 行为。

## 同组验收与后续边界

相关 CA3 最小切片并行接入 `AccountResetPersistencePort`：const 默认 Dart 实现只直接
转发现有匿名 jar.deleteAll 的 Future<void> 和 Hive Box.clear 的 Future<int>。只替换
AnonymousAccount.delete / Accounts.clear 中两个持久化调用，不改变 revoke、reset、
并发 Future.wait、reseed、activation 或错误传播顺序，不新增 queue 或写入屏障。
五项真实 fixture 验证 raw'02'/'2' clear 数量及 reopen、默认转发无生命周期副作用、
实际 anonymous.delete、实际 Accounts.clear、closed Box 错误与并发匿名 reset 部分结果。
不得断言 Hive.clear 在 await 前内存已清空，也不得将 closed-before-backend 的错误
当作 durable unknown 或 backend write-then-error 的回滚证明。

提交顺序：本计划与当前 capture 验收记录 → 原生 DTO/codec/共享资源预检/PBX → 默认
reset port + 两调用 + 五 fixture → 实际 Dart producer/独立 Swift oracle/driver/mandatory
workflow。每个提交审阅 diff、独立 push；相关组汇合后才启动完整 release 与全部 preview。
真实 producer 8 tests / 10 observations 是预计范围，整 accounts 144 是预计数量；最终
证据必须读取 Actions 实际输出，不能把预计数量写成通过。

新独立 Python driver 在 macOS 真跑 Dart analyze --fatal-infos、producer、Swift6
compile/run，artifact 保存原 goldens/hash/log/summary。失败/缺失/skip 均失败。
在 ios.yml 新增明确 mandatory envelope outcome，与现8 outcomes同等门禁；
路径过滤器和 PBX 同时更新。组末同一 SHA release5 + all preview4、全部实际日志
通过后，只接受完整 capture-local format / codec，不宣布完整 P05 或 CA1/CA3/CA4完成。

本组不写 Keychain，不发布 accounts manifest，不导入 live registry，不新增 ownerToken，
不设置 authority marker，不接 credential reader/writer，不创建 bridge/runtime入口。
集合持久化、单账户 mutation事务、统一 lifecycle/barrier、reverse-import与 crash
恢复留下一独立可回滚组；正式 authority handoff 仍需全部前置 CI 与实际账户设备验收。
