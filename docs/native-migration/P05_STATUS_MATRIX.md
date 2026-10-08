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
| reverse import | `native_account_reverse_import.dart` | 纯 immutable 蓝图、strict 累计限额、显式 captured identity 构造、空目标内存安装；匿名完整状态与 owner/stored 双顺序；账户157测试通过 | legacy Hive 属性重启仍丢失，durable replacement 未做 |
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

仍直接读写、未进入统一 barrier 的路径：

- `Accounts.set/selectTemporarily/temporary` 选择；`Accounts.refresh` 的 Hive 对账与
  buvid 激活；`LoginAccount` 构造函数 / `BiliCookieJar.setBuvid3` 补值。
- `AccountManager._saveCookies` 的 normal/403/redirect 写回（经 mutation port，但仍是
  Dart jar/Hive）；Native HTTP lease `finish` 的 owner 写回；WK Cookie 镜像。
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

## 剩余缺口（后续切片）

1. **CA2 剩余**：持久用途（`Accounts.set` 的 type add/remove 双账户语义）与
   install/import/buvid 补值的 durable 事务；durable commit receipt 与账号级排队。
2. **CA3**：全部 reader/writer 收口到同一 authority；Dart proxy 与只读展示缓存；
   credential reader adapter；在途 writer 屏障。
3. **CA4 剩余**：durable Dart reverse replacement、record identity registry、安全孤儿清理；
   把经修复与重新验收的 marker/coordinator 通过 bridge/proxy 接入生产 composition 的
   freeze/drain/export/publish 流程（当前只有 Native 协调器，没有 runtime 调用方）。
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

- `git revert 7159af4`（Dart reverse import）、`52e4471`/`2cb8ce5`（authority marker/
  coordinator）、`33345be`/`d2058d3`（事务扩展）、`eeed9ab`（Cookie 事务）、`2545196`
  （shadow store）、`0aa98b5`/`c2bc5ab`/`f361947`（DTO/codec/producers/driver）；
  `d1c3cd1`（reset port）按需单独回滚。无运行时权威切换，无数据迁移，回滚不需要
  反向导入；本阶段未新增 package 依赖。
