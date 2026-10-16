# P05 状态矩阵与剩余缺口（交付审核版）

2026-10-09（Asia/Hong_Kong）。本文件对应当前分支 `codex/native-migration` 的已验证
代码 SHA `e740cace879630f8968f5f0733c6af708377cddd`。结论：**P05 未整体完成**；
本阶段交付的是完整账户只读 capture-local 格式、严格 codec、隔离 Keychain shadow 持久化、
shadow-only 单账户 durable transaction（Cookie save/delete/deleteAll、临时选择、
credentials、activated）、durable authority marker/两阶段 handoff/revert/crash recovery
与 Dart reverse import，外加默认 Dart reset port 的 CI 验收。
账户/登录/Cookie/签名的生产 authority 仍是 Dart/Hive/Dio，Flutter runtime 保留。
完整交付说明与未完成门禁见 [P05_COMPLETION_REPORT.md](P05_COMPLETION_REPORT.md)。

2026-10-09 审核修复验收：旧7159af4用例未覆盖12项正确性问题；本轮修复遵循
[P05_REPAIR_PLAN.md](P05_REPAIR_PLAN.md)，已通过下列同 SHA 完整CI。反向恢复限定为
严格纯数据 decode + 空目标内存 apply；不支持非空合并/替换，不满足 durable Dart
回退前提。已发布 shadow 记录保留给 marker 精确 UUID 读取，安全 GC 暂缓。

2026-10-09 持久化恢复 Vault：按 [P05_PERSISTENT_RESTORE_PLAN.md](P05_PERSISTENT_RESTORE_PLAN.md)
新增独立 `Box<String>` 候选/唯一 manifest 发布组件并已同 SHA 验收（见下表）。它解决
“reverse import 只能内存恢复”的第一步：候选验证、持久写入、完整读回、CAS、单指针发布、
未知确认 fenced。**仍未接入** `completeRevert`/启动 apply，也不算 durable Dart
replacement 完成；legacy Hive 重启属性丢失仍未修复。

2026-10-09 R1–R4 审核修复：Codex `review-e1054b3/P05_REVIEW.md` 的 4 项问题已在
`f1eb57b` 修复并通过同 SHA release5+preview4（见下表）。create-only 事务 ID 预留、
本轮所有权清理、物理域共享 gate/CAS/fence、严格持久 JSON 入口均已落地；账户实际
`+176` tests（19 Vault）。仍未改变 runtime/authority 状态。

2026-10-09 R5/R6/C1 复审修复：Codex `review-f4219f3/P05_REVIEW.md` 的 R5（owned 快照
被丢弃后序列化 caller 可变对象）、R6（域注册表强持有 closed Box）、C1（legacy oracle
未冻结）已在 `55d6add` 修复并通过同 SHA release5+preview4。另补 published 基线下
写入后取消、完整可 load 的 CAS 竞争候选、对象域隔离与 strict parser 直接预算；
账户实际 `+182` tests（25 Vault）。仍未改变 runtime/authority 状态。

2026-10-09 CA3 默认响应写回协调器：`d255506` 新增共享
`AccountWriteBackCoordinator`（一次性 token、freeze 拒绝新 admission、admitted 链排空、
恰好一次释放；不替代 owner/generation），AccountManager `_saveCookies` 与 Native lease
`finish` 的全部真实 await 共用；冻结时零写/revoked。账户 `+196` tests（新增 14）通过。
范围仅响应写回，credential reader 与其余生命周期 writer 未收口，无生产 freeze caller。

## 同 SHA CI 证据

本轮修复 SHA `e740cac`（实际CI于2026-10-08结束，2026-10-09核对）：

- release [37781658066](https://github.com/Justintunsday/Piliglass/actions/runs/37781658066)
  5/5 jobs、preview [37782661482](https://github.com/Justintunsday/Piliglass/actions/runs/37782661482)
  4/4 jobs；Runner `BUILD SUCCEEDED`、109.1MB、FFmpeg顺序通过，九个强制 outcome 全success。
- envelope artifact `status=passed`，sourceSHA/workflowSHA均为 `e740cace879630f8968f5f0733c6af708377cddd`：
  producer8/观察10/fresh goldens2，108 oracle/43负例/40 staging/35 transaction/51 authority；
  四次 Swift6 complete concurrency 编译通过；62个相关源码 Git blob SHA256 与产物一致。
- 账户组严格分析无问题，实际 `+157: All tests passed!`、tracker72；零网络恢复、dormant
  decoder、真实Hive写后错误与clear恢复互斥用例均通过。Preview账户6/图片3/播放器2/导航9
  共20测试通过，压力fixture `failures=[]`；单次burst测量不作为性能验收。
- 历次真实失败与修复见修复计划；没有放宽 fatal-infos、跳过旧用例或降低九个强制门禁。

历史 SHA `7159af4`（旧覆盖范围）：

- release [37701163766](https://github.com/Justintunsday/Piliglass/actions/runs/37701163766)
  5/5 jobs、preview [37701168438](https://github.com/Justintunsday/Piliglass/actions/runs/37701168438)
  4/4；driver `status=passed`：108 oracle、43 负例、36 staging、29 transaction、
  24 authority checks；账户 analyze 无问题、`+146: All tests passed!`；9 outcomes success、
  BUILD SUCCEEDED/109.1MB/FFmpeg 顺序通过。

前序验收 SHA `d2058d3`（含 Cookie/selection/credentials/activated 事务）：

- release [37656023018](https://github.com/Justintunsday/Piliglass/actions/runs/37656023018)
  5/5 jobs success；聚合门禁 9 个 outcome 全部 success（含第九个
  `ACCOUNT_ENVELOPE_OUTCOME`）；Runner `BUILD SUCCEEDED`、Runner.app 109.1MB、
  实际 `Verified Aether FFmpeg precedes media-kit FFmpeg in Mach-O load order`。
- preview [37656028842](https://github.com/Justintunsday/Piliglass/actions/runs/37656028842)
  4/4 jobs success（player-controls、account-pages、image-preview、preview）。
- envelope artifact 实际输出：`status=passed`，8 个真实 Dart producer tests、10 个
  actual Dart 观察、2 个 fresh goldens、108 项 Native oracle checks、43 个精确负例、
  36 项真实 Security Keychain staging checks、29 项 durable transaction checks。
- 账户组 artifact：定向 analyze `No issues found!`、`flutter test test/utils/accounts/`
  实际 `+144: All tests passed!`（含新增 8 producer tests 与 reset port 五项回归）、
  72 项 tracker checks。

前一验收 SHA `eeed9ab`（Cookie-only transaction）：

- release [37652089143](https://github.com/Justintunsday/Piliglass/actions/runs/37652089143)
  5/5、preview [37652094105](https://github.com/Justintunsday/Piliglass/actions/runs/37652094105)
  4/4；envelope `status=passed`、transaction 24 checks。

过程记录：首轮 release `37643223421` 实际 `--fatal-infos` 报 fixture `SameSite`
未定义（修复 `d1ef763`）；第二轮 `37645667888` 的 build job 曾因 runner `pub.dev`
socket error 在既有 `Apply Patch` 失败，同 SHA 重跑后 5/5 success；扩展切片首版
`33345be` 的 Swift enum `.index` 编译错误在实跑前发现并由 `d2058d3` 修复，旧 run
被取消替代。`continue-on-error` step 的 surface conclusion 未被当作证据，验收以
driver `summary.json`、artifact 与聚合门禁 outcome 为准。

## 已实现并 CI 验收的切片

| 切片 | 生产文件 | 内容 | 边界 |
|---|---|---|---|
| 共享 strict jar helper | `PiliOrderedCookieArchive.swift`、`PiliOrderedCookieArchiveCodec.swift` | internal parser/value projection、`decodeValue`、累计 `PiliOrderedCookieArchiveBudget`；原 decode/encode 与错误契约不变 | 不新 authority |
| capture-local envelope DTO/codec | `PiliAccountLiveMemoryShadow.swift`、`PiliAccountLiveMemoryShadowCodec.swift` | 一次 parse + resource preflight + Domain 共享 ledger；全部 records/key/credential/jar/order/selections/history；四能力 flag 固定 false | 只读格式 |
| 失败关闭的 reset port | `account_reset_persistence_port.dart` + 两处调用 | 匿名 jar.deleteAll 与 Hive clear 的默认 Dart 转发；生命周期顺序不变 | 非 Native authority |
| 隔离 Keychain shadow | `PiliAccountEnvelopeStagingStore.swift` | 唯一 manifest 指针、record 全量 reread、写后错误读回、unknown ack 保留双记录、operation gate、cancel 前不发布 | shadow only |
| shadow 单账户事务 | `PiliAccountEnvelopeTransactionStore.swift` | 按 raw key + generation 定位单 record；Cookie save/delete/deleteAll 经已对照 Dart 的 ordered reducer；临时 selection（派生 history）、credentials、activated 为显式值变更；全部候选先过累计 ledger 再发布 pointer | shadow only；持久用途/install/buvid 未做 |
| durable authority | `PiliAccountAuthorityMarkerStore.swift`、`PiliAccountAuthorityCoordinator.swift` | marker 精确 UUID/digest 绑定、合法起始态、跨 await gate；51项实际检查通过 | 仅 Native；无 Dart runtime proxy；调用 completeRevert 前仍需 durable Dart 消费 |
| reverse import | `native_account_reverse_import.dart` | 纯 immutable 蓝图、strict 累计限额、显式 captured identity 构造、空目标内存安装；匿名完整状态与 owner/stored 双顺序 | legacy Hive 属性重启仍丢失，durable replacement 未做 |
| 持久化恢复 Vault | `native_account_reverse_restore_store.dart` + `strict_persistent_json.dart` + `native_account_reverse_restore_test.dart` | 独立 `Box<String>` 版本化候选 + 唯一 manifest；纯候选验证→写入→读回→CAS→发布→读回；R1 create-only 拒绝重复/已发布 ID；R2 只清理本轮独占新建且尝试写入的候选；R3 gate/fence/ID 预留按物理 vault domain 共享；R4 有界 strict JSON 拒绝重复字段/浮点/预算逃逸；R5 只序列化 strict decode 的 owned 快照，caller 在 await 期间的修改不影响本次快照；R6 弱键 Expando 域注册 + primitive 拒绝；已发布记录保留，unknown ack 保留双方并 fence | 未接 `completeRevert`/启动 apply；账户182测试（25 Vault）通过；`box.get` 内存读不等于后端故障证明 |
| 响应写回协调器 | `account_write_back_coordinator.dart` + `account_mgr.dart` + `native_http_request_lease_service.dart` | 共享 admission/drain gate；一次性 token、freeze 拒绝新 admission、已 admitted 链排空、throw/cancel/finish/abandon/dispose 恰好一次释放；AccountManager Cookie/redirect/Hive 与 lease finish 共用；冻结时零写 | 仅响应写回；无生产 freeze caller；其他 writer/reader 未收口 |
| 跨语言对照 | `tool/check_native_account_*`、Dart producer/fixture/test | fresh goldens 三阶段 hash、独立 JSON oracle、真实 Keychain/故障矩阵、真实 Dart capture→reverse→逐字节比较 | 仅 synthetic secrets |

## 当前生产数据流（authority = Dart）

```text
SwiftUI/UIKit Feature
  -> MainActor State/ViewModel
  -> Domain Repository protocol
  -> Data adapter（PiliAccountFlutterRepository / PiliAccountSnapshotBridgeCodec ...）
  -> FlutterMethodChannel
  -> Dart Accounts / AccountManager / Dio / Hive / CookieJar
```

新增 Native 路径不是运行时 caller：

```text
Dart Accounts live registry -> NativeAccountLiveMemoryCaptureService（checkpoint + 全量复核）
  -> PiliAccountLiveMemoryShadowCodec（strict bounded）
  -> PiliAccountEnvelopeStagingStore（隔离 Keychain namespace + 单 manifest）
  -> PiliAccountEnvelopeTransactionStore（shadow Cookie transaction）
  -> PiliAccountAuthorityCoordinator / MarkerStore（handoff/resume/revert）
  -> Dart NativeAccountReverseImport（重建 LoginAccount 与选择）
```

四项能力标志 `durableIdentityConfigured`、`durabilityVerified`、
`authoritySwitchAllowed`、`nativeWritesAllowed` 在 capture 与所有候选/receipt 中保持 false；
authority marker 与 coordinator 已实现并 CI 验收，但**没有** bridge 命令、
durable record identity registry 或 runtime 开关把该 authority 接给生产 reader/writer。

## reader/writer 覆盖与仍存在旁路

已收口的协议端口（默认 Dart 同步转发）：response Cookie mutation、install/import、
登录账户删除、匿名 reset + Hive clear。它们只改变调用形状，不改变 Dart writer。

响应写回链（`AccountManager._saveCookies` 的 normal/403/redirect + Hive persistence、
Native HTTP lease `finish`）已接入共享 admission/drain 协调器；写入时序、owner/
generation 检查与 Dart jar/Hive writer 本身不变。这是**局部** gate：没有生产 freeze
caller，其他 writer/reader 仍不在同一 barrier 内。

`9dc8e04` 起两个请求路径（`AccountManager.onRequest`、Native lease `_captureInput`）的
base/gRPC headers 与 accessKey 读取默认经只读 `accountCredentialReader`（owner/stamp
校验后返回 owned 快照，null 保持既有 revoked 路径）；csrf/页面读取等其余 reader 与
全部 writer barrier 仍未收口。证据：release 38004792296 / preview 38004795029
（账户 **+208**、envelope 108/43/40/35/51、九 outcome success）。

**Block 1 有限切片（B1a/B1b/B1c）已在 `405dd5c` 验收**：B1a 生命周期 Port 写入
（install/import/deleteAll/clear + 直接 delete）与 B1b 选择/refresh/登录副作用
（set/selectTemporarily/refresh、`onLoginMain`→deleteAll 透传）接入同一
admission/drain（frozen 在任何变更前拒绝、嵌套复用外层 token、drain 等真实写入）；
B1c `Accounts.csrfOf`/`accessKeyOf` + reader `accessKeyFor` 收口 `lib/http` 全部
122 处 csrf 与 15 处 accessKey 读取（缺 stamp 回退原字段，行为等价）。证据：
release [38127371993](https://github.com/Justintunsday/Piliglass/actions/runs/38127371993)
5/5、preview [38127374136](https://github.com/Justintunsday/Piliglass/actions/runs/38127374136)
4/4；账户 analyze 无问题、实际 **+230** tests；envelope 108/43/40/35/51、
sourceSHA=workflowSHA=405dd5c；九 outcome success、BUILD SUCCEEDED/109.1MB/FFmpeg。
仍未收口：页面 `account.values/toMap` 读取、WK 镜像、LoginUtils 其它延迟副作用、
Hive close/compact（B1d）；四 flag false，P05 未整体完成。

**Block 2 第一切片（B2a 持久用途事务）已在 `de2223a` 验收**：
`PiliAccountEnvelopeTransactionStore.applyPurposeChange` 在同一 candidate 内做双记录
purpose move（selected 幂等追加、previous 仅持有时移除、same-record previous 不清除、
selections/history 重算，jar/order/generation/revision 不变）；unknown/stale/missing
generation/暂停重入全部拒绝且零发布；共享累计 ledger 与 vault CAS。envelope
transaction checks 实际 **58**（原 35）。证据：release 38130025898 5/5、preview
38130028273 4/4、账户 **+230** tests、108/43/40/58/51、九 outcome success、
BUILD SUCCEEDED/109.1MB/FFmpeg。仍未接 authority、未产生 durable identity；
install/import/delete/buvid durable transaction、账号级队列与生产 composition 属后续
切片；四 flag false。

**Block 2 / B2b 切片（durable record identity + install 事务）已在 `1aa3513` 验收**：
显式 schema 3（schema 2 legacy 可读；schema 3 要求 login record canonical UUID、
匿名 nil，codec 按版本严格选择 key 形状）；`adoptMissingIdentities`（schema 2→3 一次性
升级，已 adopt 时 no-op 不发布）；`applyInstall` 仅 schema 3 原子追加完整 login record
（连续序号、storedOrder/ownerOrder 追加、selections/history/匿名/既有记录不变、identity
铸发、共享 ledger、CAS、重入拒绝；`duplicateRecordKey`/`staleGeneration`/`invalidInstall`/
`resourceLimit` 拒绝零发布；receipt 两门恒 false）。证据：release 38136462609 5/5、
preview 38136464878 4/4（无 rerun）；账户 **+239** tests、analyze 无问题；envelope
`status=passed` 109/44/40/**101**/51、sourceSHA=1aa3513；九 outcome success、
BUILD SUCCEEDED/109.1MB/FFmpeg、preview 20 tests/`failures=[]`。仍未接 authority、
无生产 caller；import/delete/buvid durable transaction、账号级队列属后续；四 flag false。

**Block 2 / B2c 切片（durable delete 与 import 事务）已在 `3b8e821` 验收**：
`applyDelete`（仅 schema 3、仅 login record；后续 record 重编号、两种 order 移除重编号、
selections 采用 Dart 删除政策（被删槽→0、后续槽−1）、history 重算、identity 保留）；
`applyImport`（同 key 原位替换保留 identity、新 key 顺序追加并铸发 identity、orders 追加、
selections/history/revision 不变；重复 key/空 key/重复 purpose/generation 冲突/超预算/
schema 2 全部显式拒绝且零发布；单 candidate 原子）。证据：release 38137735191 5/5、
preview 38137738208 4/4（无 rerun）；账户 **+239** tests、analyze 无问题；envelope
`status=passed` 109/44/40/**139**/51、sourceSHA=3b8e821；九 outcome success、
BUILD SUCCEEDED/109.1MB/FFmpeg、preview 20 tests/`failures=[]`。仍未接 authority、
无生产 caller；buvid 补值 durable transaction 与账号级队列属后续；四 flag false。

**codex-3b8e821 复审修复组在 `53aed63` 同 SHA CI 通过；独立复审 CHANGES_REQUESTED
（R10/R11 开放，退修见 P05_REVIEW_53AED63_R12_REPAIR_PLAN.md）**（release
38150244501 5/5、preview 38150247302 4/4）：drain 真实 await 与 owner 复核、维护独占
barrier（`beginMaintenance`/permanent close、不触碰 freeze）、clear 的 buvid 链进入
token、import 全新代际 + Dart refresh parity（ownerOrder/selections/history 重建）、
schema-aware record shape、purpose primitive 契约与缺失验证、bound reader 访问器与残余
直读点迁移。证据：账户 **+250** tests、analyze 无问题；envelope
**109/44/40/157/51**、sourceSHA=53aed63；九 outcome success、BUILD
SUCCEEDED/109.1MB/FFmpeg、preview 20 tests/`failures=[]`。仍未接 authority、无生产
caller；四 flag false，P05 未整体完成。

**Block 2 / B2d（buvid 补值事务）在 `9724ddb` 同 SHA CI 通过；独立复审
CHANGES_REQUESTED（R12 退修中）**：`applyBuvidSeed` 对齐 Dart `setBuvid3` `??=` 语义
（仅缺失时以 reducer 追加 `buvid3`、已存在 no-op 不发布；ASCII/无分隔符校验、schema 3、
key/generation、CAS、重入、零发布）。证据：release 38177658968 5/5、preview
38177662359 4/4；账户 **+250**、analyze 无问题；envelope **109/44/40/178/51**、
sourceSHA=9724ddb；九 outcome success、BUILD SUCCEEDED/109.1MB/FFmpeg、preview 20
tests/`failures=[]`。特别说明：9724ddb 的超长用例只证明 parser 上限拒绝，不构成共享
ledger 预算验证（R12 退修补齐主动长度上限、边界值与真实预算回归）。仍未接 authority、
无生产 caller；durable identity 消费/恢复语义与账号级队列属后续；四 flag false。

**R10/R11/R12 退修在 `6279bc2` 的 CI 已被独立核实，但 Codex 独立复审结论为
CHANGES_REQUESTED（release 38185057809 5/5、preview 38185059780 4/4；账户 **+256**
tests、analyze 无问题；envelope `status=passed` 109/44/40/**202**/51、sourceSHA=6279bc2；
九 outcome success、BUILD SUCCEEDED/109.1MB/FFmpeg、preview 20 tests/`failures=[]`）**：
R11 legacy 省略/null 水位在删除最大/最后 login 后丢失、R10 负例空转（isLogin=false）/
同对象 revoke-reactivate/direct setWebCookie stamp、以及 `4d046a7` 的 transaction 编译
180s 超时；R12 组件已被复审核实通过。**修复已在 `672e216` 完成并同 SHA CI 全绿**
（release 38188706831 5/5、preview 38188709339 4/4、账户 **+258**、envelope
109/44/40/**245**/51、sourceSHA=workflowSHA=672e216；九 outcome success、BUILD
SUCCEEDED/109.1MB/FFmpeg、20 tests/`failures=[]`），**等待 Codex 再复核**。详见
[P05_REVIEW_53AED63_R12_REPAIR_PLAN.md](P05_REVIEW_53AED63_R12_REPAIR_PLAN.md) 与
[P05_REVIEW_6279BC2_REPAIR_PLAN.md](P05_REVIEW_6279BC2_REPAIR_PLAN.md)。Codex PASS 前不
进入下一组、不写"已验收"；四 flag false。

**Block 2 / B2e-1（durable identity 消费 + 账号写入队列/receipt/unknown 语义）+ R13–R18 退修在 `0ea82b1` 同 SHA 双 CI 全绿；等待 Codex 独立复审（非 PASS）**：
按 [P05_DURABLE_IDENTITY_QUEUE_PLAN.md](P05_DURABLE_IDENTITY_QUEUE_PLAN.md) 实现有界全局
FIFO（`enqueue`、`writeQueueOverflow`、排队/发布前取消释放、每次尝试新快照重校验）、
全事务 receipt identity（adopt/install/delete/import/cookie/purpose/credentials/
activated/buvid）、只读 `lookupRecord`、A/B/C receipt→immutable candidate 关联。
R13 unknown 为 fail-closed：不可变未决证据 `{previousTransactionID,
attemptedCandidateSHA256, kind}` + 冻结后续写（queued/direct 均 `unresolvedPublication`）
+ `resolveUnresolvedPublication()` 读回释放（不重放、不从 payload 推断、不伪造 receipt）；
R14 unknownA/B 显式 admission 屏障；R15 queued `resourceLimit`/maxQueueAttempts 耗尽
→typed 拒绝后合法 follower、真实 queued purpose 读变换发布竞争与 previous-holder 失效
`staleGeneration` 零副作用；R16 retry back-off/预约等待者期间 direct public 入口
fail closed；R17 实际 activated 基线取反溢出证明；R18 A/B/C candidate 关联恢复；无
全局 purpose 唯一性约束。CI 编译预算：transaction driver 三次 180s 纯超时（无诊断、同
源码早前通过），按逐行内容不变拆为 core 68 + identity 177 = **245** 两个编译单元，预算/
严格性/断言不变。实际证据：release
[38263993936](https://github.com/Justintunsday/Piliglass/actions/runs/38263993936) 5/5
（九强制 outcome 全 success、BUILD SUCCEEDED、Runner.app 109.1MB、Aether FFmpeg 先于
media-kit 载入）、preview
[38264008966](https://github.com/Justintunsday/Piliglass/actions/runs/38264008966) 4/4
（20 tests 0 failures、fixture `"failures": []`）、envelope `status=passed`
109/44/40/**245**(68+177)/**104**/51、sourceSHA=workflowSHA=0ea82b1、87 源码 hash、
账户 `+258`/runtime 72、queue logs 无 FATAL。仍 shadow、无生产 caller/authority；B2e-2
（unknown 持久恢复面/启动 recovery）与 B2e-3（生产 composition 接线）未做；四 flag
false，Codex PASS 前不进入下一组。

**B2e-1 R19–R22（attempt-identity resolution / concurrent fence / cancellation witness / raw-vs-published fixture）在 `b7f6692` 获 Codex 有限 PASS（仅该 shadow 组件）**：
R19 以 caller-minted `candidateTransactionID`（无碰撞校验）把 unknown 关联到 attempted
operation ID，resolution 三态 `attemptCommitted`/`attemptNotCommitted`/
`ambiguousObservedCandidate` + `observedContentMatchesAttempt` 内容旁证（明确非操作证明）；
R20 resolution 单飞 + post-await token 复核 + 取消不释放 fence；R21 取消回归改用
非覆盖式 jar witness + 精确 holder+follower 计数；R22 修正 raw retained candidate 与
published pointer 混淆（真实基线捕获 + retained `loadPublishedCandidate` + 精确
±计数，未删/未放宽断言）。实际证据：release
[38746975413](https://github.com/Justintunsday/Piliglass/actions/runs/38746975413)
success5/5（九强制 outcome 全 success、BUILD SUCCEEDED、Runner.app 109.1MB、FFmpeg
顺序；envelope `status=passed` 109/44/40/**245**(68+177)/**148**/51、87 源 hash
（85+2 声明 pubspec）、golden `bff67a…`/`2337a9…`、账户258/72）；preview
[38746988047](https://github.com/Justintunsday/Piliglass/actions/runs/38746988047)
attempt1 `preview` job `last-row` 无 report 失败保留，仅该失败 job 同 SHA 单次重试 →
attempt2 success4/4（navigation9 + attempt1 同 SHA account6/image3/player2 = 20 tests
0 failures；`failures=[]` 100000 danmaku/1000 comments；last-row/returned-top-dark JSON
齐全）。**边界**：仅为 B2e-1 in-process queue/receipt/unknown-resolution 组件 PASS；
非 Block1/2/P05 完成；B2e-2 跨重启恢复、B2e-3/Block3 生产接线、53aed63
tagged-bound-reader 保留项、CA5/CA6 真机与 authority 均未闭合；四 flag false。

**tagged-bound credential reader（53aed63 保留项①）在 `e3ea5ae` 获 Codex 有限 PASS（仅该只读 adapter/wrapper 范围）**：
`AccountCredentialBinding`/`AccountBoundCredential<T>` 三态（notInstalled = 显式无 stamp
legacy；rejected = 有 stamp 被拒，绝不回退 raw；bound = 真实值，nullable accessKey 的
合法 null 属 bound）；reader 新增 tagged 主契约 + legacy nullable wrapper；`csrfOf` 对
rejected 抛 StateError（不回退缓存 csrf）、no-stamp 保留历史直读；`accessKeyOf`
retired/rejected null、bound(null) 合法；消费者盘点（request/lease 已 fail closed、
100+ csrfOf、15 处 accessKeyOf、snapshot 自带 owner/generation + checkpoint）。
证据：release [38756024676](https://github.com/Justintunsday/Piliglass/actions/runs/38756024676)
success5/5 与 preview [38756042155](https://github.com/Justintunsday/Piliglass/actions/runs/38756042155)
success4/4（均首轮、无 job 重跑）；九 outcome、BUILD SUCCEEDED、109.1MB、FFmpeg 顺序；
envelope 109/44/40/**245**(68+177)/**148**/51、87 源 hash（85+2）、golden
`8d3742…`/`fd1b38…`；账户 **264**(258+6)/72；preview 20 tests/11 reports/`failures=[]`。
carry-forward：no-stamp legacy 仍可读 retired 旧字段（文档化，不构成全部 reader 收口）；
计划中 `restoreEmptyCaptured` captured-window 定向回归**本组未执行**，恢复组必做并报告；
100+ endpoint tagged 消费与 refresh/grpc/snapshot 残余直读仍开放；四 flag false。

**B2e-2a/2c 持久 recovery journal + R23–R35 在 `75d829c` 获 Codex 有限 PASS（仅该恢复组件）**：
单槽 vault journal（canonical 严格解码/4096B、写 journal 先于候选/指针）、R23 成功 nil 读
≠读错误、R24 默认歧义保留 + 显式 `allowAmbiguous`、R25 真实 Keychain 四崩溃前缀 client
reopen、R26–R33 冷加载协调化（FIFO 预留先行/单一 queued 配额/direct fail-fast/只读恢复
独立包装）、R28 post-await 重验证、R31/R32 task-local 队列所有权 + 冷窗口 outsider 拒绝、
R34 无 IO 记账、R35 clear pre-commit 取消边界 + commit 语义、实际 Dart
`restoreEmptyCaptured` captured-window 回归执行。证据：release
[38810974696](https://github.com/Justintunsday/Piliglass/actions/runs/38810974696) 5/5 与
preview [38810980896](https://github.com/Justintunsday/Piliglass/actions/runs/38810980896)
4/4（首次尝试、无 job 重跑）；九 outcome/BUILD 109.1MB/FFmpeg；109/44/40/**245**(68+177)/
**292**/51、producer 8/10/2、账户 265/72、88 源 hash（86+2 pubspec）、golden
`933df5…`/`915f69…`、preview 20 tests/11 reports/`failures=[]`；Swift 6 strict-concurrency
complete（未声称 warnings-as-errors）。**边界**：非 whole Block2/P05、无 process-kill/
断电/真机证据；B2e-2b/B2e-3/Block3/handoff/GC/Block1/4/5 未闭合；raw import 仍
out-of-contract；四 flag false。

**R36/R37 preview-harness 诊断/owned-report 门在 `b73efec` 获 Codex 有限 PASS**：
launch `check=True` 失败先写有界证据再 re-raise；每 mode 唯一 token + `modeToken`/
`launchPID` + mtime≥launchStart 的 owned 报告接受；纯本地负例自测；launchctl 20s 有界
distinct status；runner `simctl help` 判定的 `--stdout/--stderr` 捕获（22 stream 文件）；
app 侧 pre/post-scroll 实际 offset、取消与 encode/write 阶段；30s/25min 预算、layout
断言/截图/UI 未变。证据：release
[38820520873](https://github.com/Justintunsday/Piliglass/actions/runs/38820520873) 5/5 与
preview [38820524983](https://github.com/Justintunsday/Piliglass/actions/runs/38820524983)
4/4（首次尝试）；九 outcome/BUILD/FFmpeg；109/44/40/245/292/51、producer 8/10/2、
账户 265/72、88 源 hash（86+2）、golden `462110…`/`2264d5…`、preview 20 tests、
11 reports 每个 modeToken==trace token 且 launchPID==解析 PID、压力 `failures=[]`。
**边界**：不证明此前 last-row 缺失报告的根因；诊断≠成功报告；本地 3 项 mock QA 不是
CI 计数或设备执行；无真机/authority 结论；前驱 8cf6629/085d883 preview 失败保留。

**B2e-2b-1 schema-3 durable-identity 严格解码 + R38 预投影记账在 `ea60931` 获 Codex 有限 PASS（仅该 decode/carriage 范围）**：
`NativeAccountReverseImport` schema-3 strict decode（canonical 36-unit 小写 UUID、唯一、
anonymous null/省略、high-water、tracker namespace 拒绝、四 flag false）+
`recordDurableIdentities` 只读 correlation labels；R38 修复把 `durableIdentity` units 并入
`_preflight` 同一累计预分配账本（`2b07b85`；删晚计费、无双重计费），边界回归实际执行
（exact-budget/+1/37-unit 预投影 `resourceLimit`、null high-water、anonymous 省略）。证据：
release [38829392361](https://github.com/Justintunsday/Piliglass/actions/runs/38829392361)
5/5 与 preview [38829396589](https://github.com/Justintunsday/Piliglass/actions/runs/38829396589)
4/4（首次尝试、无 job 重跑）；九 outcome/BUILD SUCCEEDED/109.1MB/FFmpeg；账户
**269**（含边界）/72/analyze clean；envelope 109/44/40/**245**(68+177)/**292**/51；
producer 8/10/2；golden `041724…`/`ae2e5f…`；preview 20 tests/11 reports/`failures=[]`。
前驱保留：`ed89e9f` 绿色但 R38 open；`a0e76ed` strict-info fatal +
aggregate 4-failure（preview 4/4 不替代）。**边界**：`apply()` 不携带 durable labels；
非 Swift→Dart 端到端 handoff；bridge export/frozen-revision/startup/revert/GC/
composition、full B2e-2b/P05/authority 未闭合；四 flag false。

**B1e refresh/export reader seam + R39–R42 在 `c6eb327` 获 Codex 有限 PASS（仅该 seam/清单/负例/fixture）**：
refresh tagged nullable binding + snapshot/shadow 同一 reader seam fail closed + 同一注入
reader 复验；R39 文本清单修正（raw 124/18、19/9；live 120/17、18/8）；R40/R41 定向负例与
精确 3/3 计数；R42 fixture 8.0（生产支持值）+ configured-vs-effective 断言。证据：release
[38843199175](https://github.com/Justintunsday/Piliglass/actions/runs/38843199175) 5/5 与
preview [38843202056](https://github.com/Justintunsday/Piliglass/actions/runs/38843202056)
4/4（首次）；九 outcome/BUILD 109.1MB/FFmpeg；账户 **284**/72/analyze clean；envelope
109/44/40/**245**(68+177)/**292**/51；producer 8/10/2；89 raw blob 87+2；golden
`cd7b0d…`/`044f33…`；preview 20 tests（**两 player 用例实际通过**）/11 reports/`failures=[]`。
前驱保留：3658406/209885f strict-analysis fatal；ae73dcf 19/20 player failure。
**精度**：ae73dcf 失败时观察到的只是 AX 树 chrome/720P **缺失**；alpha=0 为生产代码支持的
推断而非直接遥测；本次绿色不是历史 tap/AX/timer 因果证明。**边界**：非 whole Block1/
endpoints/writers/composition/Block4/5/P05/authority；四 flag false。

**B1f 真实 purpose path-routing 9 regressions + R43 判别矩阵 + harness R44–R47 在 `a50ea69` 获 Codex 有限 PASS（仅已测试路径）**：
video/HB 匿名负例（判别性 main）/real HB 表（`Api.videoIntro`）/recommend（`Api.recommendListWeb`）/
login 匿名/unmatched main/preset precedence/slot 切换后 boundA/reader context consumption +
R43 discriminating purpose 矩阵/header-cookie owner provenance；R44 非掩蔽 lifecycle 诊断 +
有界清理、R45 迭代独立检查/EOF 流状态/owned PGID 清理、R46 post-wait 重验证 + POSIX
readiness + `run_navigation` 集成负例、R47 恢复 `XCTNSPredicateExpectation`+`XCTWaiter`
（最多 5s，`.completed` 之外一律失败；无 late predicate）。证据：release
[38864047457](https://github.com/Justintunsday/Piliglass/actions/runs/38864047457) 5/5 与
preview [38864051135](https://github.com/Justintunsday/Piliglass/actions/runs/38864051135)
4/4（首次、无 job 重跑）；九 outcome/BUILD 109.1MB/executed FFmpeg；账户 **293**/72/
analyze clean；109/44/1 synthetic/40/**245**(68+177)/**292**/51；producer 8/10/2；
89 raw blob 87+2；golden `be8600df…`/`b7a6bf49…`；Mac QA 45/45（bounded elapsed 1.45s）；
UI 20 tests（两个 gallery 用例在恢复后的 5s waiter gate 下实际执行、Settings/persistence
用例在 selected My-tab 后置条件下通过）；11 reports/22 streams/`failures[]`。
前驱保留：ced3b19 void-await ERROR、d5f9d0c 25m hard cancel + guest termination、
f84314a image/nav 断言失败 + pressure SKIPPED、ea4c609/cb71a52 双绿但被 R45/R47 拒绝。
**边界**：非 whole Block1（120 csrf/18 access 全量消费、whole writer async closure、
gRPC purpose binding、generic purpose CAS 读-改-写干扰）/B2e-2b bridge/Block3/4/5/P05/
authority；real hard cancel 仍可能跳过上传；"exactly 5s" 读作最多 5s；8 存在 THEN 8 选中
为两次顺序上界；四 flag false。

**B1g 真实 VideoHttp 消费者 + R48 预绑定修复 + R49 宿主/播放器前置条件在 `c9adf9b` 获 Codex 有限 PASS（仅四个已测试消费者/调用时捕获/fixture 面）**：
22 个真实消费者用例（tvPlayUrl/dislikeVideo/feedDislike/feedDislikeCancel；调用时一次捕获 owner →
公开 `Options(extra account)`，无后读槽/私有绑定；replaced owner 取消零 fetch）+ R49 真实
SmartDialog 宿主（`FlutterSmartDialog.init`+`CustomToast`+observer+生产 onlyRefresh 配置，
有界 dismiss/清理）与播放器 `isHittable`→`exists` 前置（单次 reveal tap、8s 断言/预算不变）。
证据：release [38885857383](https://github.com/Justintunsday/Piliglass/actions/runs/38885857383)
5/5 与 preview [38885862718](https://github.com/Justintunsday/Piliglass/actions/runs/38885862718)
4/4（首次、无 job 重跑）；九 outcome/BUILD 109.1MB/executed FFmpeg；账户 **315** 全过/
runtime 72/strict clean；109/44/1 synthetic/40/**245**(68+177)/**292**/51；producer 8/10/2；
90 raw blob 88+2；golden `b503b6…`/`42c295…`；preview 20 tests 0 failure（landscape
127.606s 实际执行 720P 与后续手势/scrub/lock）；11 reports/22 streams/`failures[]`；
Mac QA 45/45（bounded 1.76s）。前驱保留：`12738bc` 311=305+**6**（owner/replacement 预绑定
六项，断言止于 owner 检查）；`8d86327` 315=314+1 `contextToast` LIE + 20 UI=19+1
landscape 720P 失败；`a50ea69` limited PASS 保留。**精度**：固定 pump 非普适清理证明、
`exists` 非全局廉价 AX、绿色不证明 8d 唯一根因、raw inner 日志未读不声称。**边界**：
非 generic purpose CAS read-transform-publish/全量 120+18/whole writer closure/gRPC/B2e-2b
bridge/Block3/4/5/authority；四 flag false。

**B1h 真实 Dart `Accounts.set` post-activation revalidate#2 干扰（7 用例）在 `eb58d5c` 获 Codex 有限 PASS（仅该 7 用例/offline seam 范围）**：
7 个真实 Hive + 受控 adapter 用例（control publish 链/selection switch 零效果/same-MID
replacement 继承 types/并发完整 set 恰一次 publish + 两 admission/deleteAll/heartbeat 对照与
slot switch）；R50 收窄由 docs-only `b4ea200` 完成（非测试 SHA）。证据：release
[38891705943](https://github.com/Justintunsday/Piliglass/actions/runs/38891705943) 5/5 与
preview [38891709617](https://github.com/Justintunsday/Piliglass/actions/runs/38891709617)
4/4（首次、无 job 重跑）；九 outcome/BUILD 109.1MB/executed FFmpeg；账户 **322** 全过
（7 新用例 157→164）/runtime 72/strict clean；109/44/1 synthetic/40/**245**(68+177)/**292**/51；
producer 8/10/2；91 raw blob 89+2；golden `5c30f83b…`/`71ed239c…`；preview 20 tests
（441.056+169.513+206.278+101.689s）；11 reports/22 streams/`failures[]`；Mac QA 45/45
（1.65s synthetic）。**精度**：证明 writer/state-machine 时序，非 headers/Cookie/auth
pipeline/Native CAS/WK 副作用/真实账户；mirror/publisher 为既有 seam；并发 future 只证重叠；
main/heartbeat 已测、default 未测；仅 post-activation/#2。**边界**：不闭合 Native
`applyPurposeChange` CAS（原 53 item8；其目标组已实现并在 `3818948` 获有限 PASS，见下条）、
初始 Hive onChange await/#1、全部 writer/async closure、B2e-2b bridge/frozen revision、
Block3/4/5、authority；四 flag false；本记录为 docs-only（实际测试 SHA `eb58d5c`）。

**Native `applyPurposeChange` read-transform-publish CAS（原 53 item8）+ R51–R54 在 `3818948` 获 Codex 有限 PASS（仅该 schema2 fixture/同 vault 合法竞争者/同进程 Keychain reopen 范围）**：
生产唯一新增为 instance-local 缺省 nil 的 `prePublicationDeliveryHook`（encode/attemptID mint 后、
shared-vault import 前 await；生产接线从不安装）；C1/C1c/C2/C3/C4 + R53 五个 helper 回归
（同 vault 合法 purpose/temporary 竞争者 → 精确 `.staleTransaction`/零 stale 发布/无新
fence/journal/成功写计数不变、cancel 显式 resume → `CancellationError`、fresh merge、
写者静默后同进程新 Keychain 实例读回）。证据：release
[38907716616](https://github.com/Justintunsday/Piliglass/actions/runs/38907716616) 5/5 与
preview [38907728006](https://github.com/Justintunsday/Piliglass/actions/runs/38907728006)
4/4（首次、无 job 重跑）；九 outcome/BUILD 109.1MB/executed FFmpeg；账户 **322**/72/strict
clean；109/44/1 synthetic/40/**285=108+177**/292/51（新用例实际执行，非借 245）；producer
8/10/2；91 raw blob 89+2；golden `2237bfdd…`/`c5d57bbb…`；preview 20 tests
（256.179+99.126+177.065+58.849s）；11 reports/22 streams/`failures[]`；Mac QA 45/45
（1.31s synthetic）。前驱保留：5d 词法编译失败、030 错误收据类型编译失败（新用例未在其执行）。
**精度**：仅 schema2 目标竞态（非 schema3/high-water 专属证明）；write 计数为成功写调用，
非全部 attempted writes/removes/orphan 清点；one-shot/single-waiter helper 非通用等待者/
cancel-responsive/硬期限证明；同进程 Keychain 实例 ≠ process kill；无 zero-warning 声明。
**边界**：不等于 whole Block1/2/P05/schema3 专属竞态/process kill/authority/handoff-revert-GC/
设备；四 flag false；docs-only 记录（实际测试 SHA `3818948`）。

**B2e-2b-3 原子只读 schema3 当前指针导出 + 真实跨运行时消费 + R62–R65 在 `6b39ac1` 获 Codex 有限 PASS（仅该只读导出/selected `stored-10-2-owner-2-10` fixture/R62–R65）**：
`exportCurrentShadow(expectedTransactionID:)`：单 shared-vault fence、fresh persistent
journal fail-closed（present/corrupt/unreadable 保留字节、绝不 resolve/clear/replay）、pinned
pointer 精确已存字节（不重编码）、严格 schema3、zero writes、post-await 精确
`CancellationError`；原 enum 只加 `shadowUnavailable`/`staleExport`；R62 次序/映射修复、
R63 负例矩阵 + 全 winner oracle + 真实 store-B correlated `publicationUnknown`（journal+fence
保留、不 replay）+ pre-cancel 零 IO + 终态 helper、R64/R65 driver 全字节 oracle + mock QA
确定性时钟。跨运行时：driver 精确 wire/元数据由**同一 mandatory outcome** 内实际 Dart
consumer 6 测试严格消费（byte/hash/consumed/指针/labels 对齐独立 capture、负例拒绝）。证据：
release [38939382819](https://github.com/Justintunsday/Piliglass/actions/runs/38939382819)
5/5 与 preview [38939388310](https://github.com/Justintunsday/Piliglass/actions/runs/38939388310)
4/4（首次、无 job 重跑）；九 outcome/BUILD 109.1MB/executed FFmpeg；账户 **322**/72/strict
clean；七个 Swift6 strict 日志 **128** export checks/consumer 6；既有
109/44/1/40/**285**(108+177)/292/51、producer 8/10/2；legacy 88；envelope 台账 94 条（92
match+2 声明 pubspec）与 legacy 14 条（全 match，两组重叠、非 unique；不做聚合文件数
声明）；goldens `d67f0fc8…`/`4f9b95f9…`/`0198a937…`/`b1220406…`；metadata
`0af69bf2…`/wire `aed83d99…`/consumed `ff52457b…`；preview 20
（398.437+62.362+173.313+71.989s）；11 reports/22 streams/`failures[]`；MacQA 45/45（1.66s
synthetic）。前驱保留：`818a0e9`/`3e7a21f` 两次 source-preflight CHANGES_REQUESTED（R62–R65）、
mock QA 14/15。**精度**：raw fault fixture ≠ 合法 writer 干涉；同进程 Keychain 新实例 ≠
process kill；warning 保留（非 zero-warning）。**边界**：不等于 whole Block2/3/P05/authority/
生产 bootstrap/binding/handoff/revert/startup/GC/设备；四 flag false；docs-only 记录（实际
测试 SHA `6b39ac1`）。下一组契约见
[P05_B2E2B3_FIRST_PUBLICATION_ASSOCIATION_PLAN.md](P05_B2E2B3_FIRST_PUBLICATION_ASSOCIATION_PLAN.md)。

**B2e-2b-2 legacy schema-1 staging fetch（`stagingExport()`）+ R55 在 `318bb88` 获 Codex 有限 PASS（仅 legacy read-only fetch/命名统一/新取消回归/组件 provenance 范围）**：
真实仓库方法 `stagingExport()`（命令 `exportNativeAccountStaging`、nil 参数、严格 codec/
error-state；R55 统一 driver 命名、无别名）+ 预取消零 invoke/受控挂起取消（显式 release）/
严格 malformed 经 repository + native-account 自持 14 输入 provenance。证据：release
[38919853808](https://github.com/Justintunsday/Piliglass/actions/runs/38919853808) 5/5 与
preview [38919866173](https://github.com/Justintunsday/Piliglass/actions/runs/38919866173)
4/4（首次、无 job 重跑）；九 outcome/BUILD 109.1MB/executed FFmpeg；账户 **322**/72/strict
clean；legacy 88 checks/14 blobs 全 match/legacy goldens `2c91d905…`/`b6cea08b…`；
109/44/1/40/**285**/292/51；producer 8/10/2；91 raw 89+2；preview 20
（299.688+85.440+187.571+70.252s）；11 reports/22 streams/`failures[]`；MacQA 45/45
（1.40s synthetic）。前驱保留：`ab1b9e5` missing-member 编译失败（不追溯接受）。**精度**：
schema-1 tracker fetch 经 fixture invoker，非 MethodChannel e2e/full schema3 durable
bridge/freeze lease/生产 composition；14/91 ledger 非 105 unique。**边界**：不等于 whole
Block1/2/P05/authority/handoff-revert-GC/设备；四 flag false；docs-only 记录（实际测试 SHA
`318bb88`）。

**Block 1 / B1d 切片（页面读取、延迟副作用、maintenance gate）已在 `98e6f9b` 验收**：
`Accounts.installedAccounts()` 纯只读 seam + 页面 `isEmpty/isNotEmpty` 切
`visibleAccounts()`（login/mine/setting/about，内容/顺序/读取时机不变、零
activate/reconcile/refresh）；`setWebCookie`/`onLoginMain`/`onLogoutMain`/
`syncHistoryStatus` 支持 admission 透传（链内单 token、独立调用自带 token、frozen 在
WK/网络/GetX 前拒绝）；`coordinator.quiesce()`（非冻结排空）+ `GStorage.compact/close`
先 quiesce 再执行。证据：release 38132428469 5/5、preview 38132430663 4/4（首次
`initial-top` render 为慢 runner 超时，同 SHA rerun 通过）；账户 **+239** tests、
analyze 无问题；envelope 108/43/40/58/51、sourceSHA=98e6f9b；九 outcome success、
BUILD SUCCEEDED/109.1MB/FFmpeg、preview 20 tests/`failures=[]`。仍未接 authority/
durable identity；四 flag false。

仍直接读写、未进入统一 barrier 的路径：

- `Accounts.set/selectTemporarily/temporary` 选择；`Accounts.refresh` 的 Hive 对账与
  buvid 激活；`LoginAccount` 构造函数 / `BiliCookieJar.setBuvid3` 补值。
- WK Cookie 镜像；install/import/delete/reset 的 port 写入（经 port，但仍无协调器
  admission）。
- 所有 credential reader：`csrf`、`accessKey`、`grpcHeaders`、AccountManager 用途路由、
  `Accounts.account.values/toMap/isEmpty` 页面读取。
- Hive maintenance/close/compact、LoginUtils 的 WK/cache/history 副作用。
- 网络：proxy/retry/pool generation、HTTP1/HTTP2/TLS、timeout（idle vs deadline）、
  真实 raw `Set-Cookie` 字段保存、gzip/Brotli/UTF8、签名/cache、gRPC auth metadata。
  Native capability 层对未验证组合仍返回 unsupported，生产请求继续走 Dart。

## durable / crash / unknown ack / 回退行为

- shadow 发布协议：候选先 decode+encode 并全量 reread，之后才写 manifest；manifest
  写失败通过读回判定，已发布则保留新指针，未发布则删除孤候选。
- unknown acknowledgment：不重放、不删除任何一方；重启以 durable 指针为准。
- cancel：record 写失败或指针发布前取消只删除未引用候选，不改变已发布状态。
- 已发布记录：shadow 替换/discard 保留 record 与 immutable descriptor，authority 可能
  仍引用旧 UUID。安全引用追踪与 namespace GC 尚未实现，不能仅按当前 manifest 清理。
- 回退：authority 从未切换，回退等于 revert 本阶段 commit，Dart/Hive 数据不受影响。
  不存在 Native 写后回退需要恢复完整状态的问题，因为 Native 从未写权威数据。
- 真实账户/设备验收：**未执行**。没有提供测试设备、真实账户或必要输入；CA5/CA6 门禁
  保持关闭，不开放默认 authority，也不删除 Dart fallback。

## 剩余范围（用户 2026-10-10 指定的五块可执行清单）

依赖顺序、逐项盘点要求、兼容约束与保留补测见
[P05_REMAINING_SCOPE_PLAN.md](P05_REMAINING_SCOPE_PLAN.md)。与旧 CA 切片的对应：

1. **全部 reader/writer 与统一屏障（CA3 全量）**：csrf/accessKey/gRPC/header/页面只读；
   install/import/delete/set/selectTemporarily/refresh/clear/匿名 reset/activation、
   构造器 buvid 补值、WK 镜像、LoginUtils 延迟副作用、Hive close/compact；token 不替代
   owner/epoch/generation；嵌套/在途排空不死锁、不假清表。当前 response gate 只是有限组。
2. **Native 账户 durable 事务（CA2 剩余）**：持久用途双账户 type 变更、install/import/
   delete/buvid 补值；durable record identity、账号级排队与结果语义；完整 Cookie 属性/
   顺序/nullable 凭据/临时选择/原副作用保持；unknown ack 不重放、不误判未写。
3. **生产交接/启动恢复/完整回退（CA4 剩余）**：已验收 marker/coordinator、Dart proxy、
   恢复 Vault 接入真实 composition；启动 apply、`completeRevert`、崩溃阶段恢复、非空
   目标政策；legacy Hive 重启丢属性不得绕过；GC 仅在引用安全有证据时。组件/shadow 通过
   不等于生产 authority 已迁移。
4. **Native 登录/签名/网络生产接线**：完整 QR/密码/SMS/Cookie、Geetest/手机验证、退出与
   多账户用途；原生签名/缓存与 HTTP 能力接 Repository/Client；补齐或精确标注 proxy/
   retry/pool/H1/H2/TLS/timeout/raw `Set-Cookie`/gRPC auth metadata 范围；未验证组合显式
   fallback；取消与未知结果不得二次发送写请求。
5. **真实账户设备验收与开放（CA5/CA6）**：登录/换号、四用途隔离、响应 Cookie 属性、
   杀进程/冷启动/重启、网络异常与回退；全门禁满足后才开放；缺真实账户/设备时列出具体
   待验收步骤与阻塞项，不伪造通过、不提前写 P05 完成。

旧 CA 映射（历史定位用）：

1. **CA2 剩余**：持久用途（`Accounts.set` 的 type add/remove 双账户语义）与
   install/import/buvid 补值的 durable 事务；durable commit receipt 与账号级排队。
2. **CA3**：全部 reader/writer 收口到同一 authority；Dart proxy 与只读展示缓存；
   credential reader adapter；在途 writer 屏障。
3. **CA4 剩余**：把已验收的持久化 Vault 接入启动 apply/`completeRevert` 的
   freeze/drain/export/publish 流程；durable record identity registry、安全孤儿清理；
   通过 bridge/proxy 接入生产 composition 的 runtime 调用方（当前 Vault 与 Native
   协调器都还没有生产 caller）。
4. **CA5**：opt-in Native active composition，在测试设备验收 QR/password/SMS/Cookie、
   Geetest/手机验证、多账户用途隔离、实际响应 attrs、杀进程/重启与回退。
5. **网络/登录**：Native login production 安装、proxy/retry/pool/H1/H2/TLS/timeout、
   原始字段保留 transport、gRPC auth metadata；未验证组合继续显式走 Dart。

## 审核者关注风险

- 正样本 envelope 由真实 Dart capture 生成；oracle 独立比较整棵树，但仍是 synthetic
  账户，只证明格式/顺序/账本语义，不证明跨进程授权。
- transaction store 故意不 bump capture revision、不生成 durable identity；把 manifest
  发布误当 authority 会违反本阶段边界。
- `continue-on-error` 步骤的 surface success 不是证据；请以 driver summary、artifact
  与聚合 outcome 复核（本阶段多次由该方式定位真实失败：SameSite、marker 写前错误、
  测试 analyzer）。
- 部分 run 的 build job 曾因 runner 网络或前置错误重跑；以最终同 run 的 success 为准。
- Flutter/Dart/Hive/runtime 与全部旧页面保留，P05/P06–P12 未完成；P05 的完整判定必须
  等待 CA5/CA6 真机验收。

## 回滚

- CA3 响应写回组：`git revert d255506 83c7b20 5c46136 40cbfba 93d95d5 9c84bca
  773f553 a7987e2`（协调器/AccountManager/lease/测试与修复；a7987e2 为计划文档），
  无运行时 authority 接线、无数据迁移。
- R5/R6/C1 组：`git revert 55d6add be17fa7 08a5b59 d1e89c8`
  （owned 快照/弱域注册/oracle 冻结与对应测试；d1e89c8 为计划文档），无运行时接线、
  无数据迁移。
- R1–R4 组：`git revert f1eb57b 6a3107d 7dbf7f7 a6d6980 85d1909`
  （create-only/所有权/共享域 gate/strict JSON 与对应测试；85d1909 为计划文档），
  无运行时接线、无数据迁移。
- 前一组：`git revert 38ee18e b92057b fd692b3 aaed899 ab578c3 5c0465a c863083 9c2a244`
  （持久化恢复 Vault 与其修复；9c2a244 为计划文档），无运行时接线、无数据迁移。
- 历史：`git revert 7159af4`（Dart reverse import）、`52e4471`/`2cb8ce5`（authority marker/
  coordinator）、`33345be`/`d2058d3`（事务扩展）、`eeed9ab`（Cookie 事务）、`2545196`
  （shadow store）、`0aa98b5`/`c2bc5ab`/`f361947`（DTO/codec/producers/driver）；
  `d1c3cd1`（reset port）按需单独回滚。无运行时权威切换，无数据迁移，回滚不需要
  反向导入；本阶段未新增 package 依赖。
