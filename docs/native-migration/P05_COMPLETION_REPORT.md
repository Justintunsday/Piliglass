# P05 完成报告（独立审查版）

2026-10-09（Asia/Hong_Kong），分支 `codex/native-migration`，本轮审核修复已验证代码 SHA
`e740cace879630f8968f5f0733c6af708377cddd`。7159af4证据保留为历史记录。

## 结论摘要

2026-10-08 审核更正：7159af4 的编译与测试结果有效，但旧测试未覆盖随后发现的
12 项正确性问题，不能据此认定交接与反向恢复组件已满足完整合同。修复按
[P05_REPAIR_PLAN.md](P05_REPAIR_PLAN.md) 实施，已通过下列同 SHA 完整CI。
反向 apply 仅支持空目标的内存恢复；legacy Hive 适配器仍会在重启后丢失属性，
因此不能将它接到 `completeRevert()` 并宣称已完成 durable Dart 回退。

- 本阶段把 P05 的**账户格式、严格 codec、隔离 Keychain 持久化、shadow 单账户事务、
  durable authority marker/handoff/revert 与 Dart reverse import** 实现并全部通过同 SHA
  release5 + preview4 实际 CI。
- **P05 仍未整体完成**：Native authority 的运行时 Dart proxy/切换组合、持久用途与
  install/buvid 事务、Native 登录/签名的 production 安装、proxy/retry/pool/H1/H2/TLS/
  timeout/raw fields 的 transport parity，以及真实账户/设备验收（CA5/CA6）尚未交付。
  这些不是本报告的口头保留，而是本环境无法安全验证的范围；门禁继续保持关闭。
- 所有完成项均由真实 Actions 日志、artifacts、独立 oracle 与聚合门禁证明；没有使用
  `continue-on-error` 的外观 success 或本地静态检查作为验收。

## 1. 本轮审核修复证据（e740cac）

- 同代码 SHA 的 release [37781658066](https://github.com/Justintunsday/Piliglass/actions/runs/37781658066)
  5/5 jobs 与 preview [37782661482](https://github.com/Justintunsday/Piliglass/actions/runs/37782661482)
  4/4 jobs success；实际日志中九个强制 outcome 全success、0 contract errors；Runner
  `BUILD SUCCEEDED`、109.1MB，Aether FFmpeg先于media-kit FFmpeg加载。
- 账户完整测试实际 `+157: All tests passed!`、tracker72、fatal-infos分析无问题。
  新11项恢复测试与2项无存储初始化的纯decoder测试通过，保留所有旧回归。
- 新鲜Dart producer8/观察10/goldens2；Native oracle108/精确负例43、真实Security
  Keychain staging40、transaction35、authority51；四次Swift6严格并发编译通过。
  envelope `status=passed` 的sourceSHA/workflowSHA与代码SHA一致；62个相关Git blob
  SHA256全部匹配；没有将Windows CRLF工作副本字节当作Git源文件。
- Preview实际账户6/图片3/播放器2/导航9共20测试、0失败；压力fixture `failures=[]`。
  burst单次188.41ms仅为fixture观察，不代表真机性能验收。
- 已处理12项审核问题：精确候选身份与记录保留、合法handoff与marker互斥、vault CAS、
  匿名全状态、cached MID/raw key与空jar、拒绝非空合并、owner顺序、零激活请求、严格
  类型/历史/累计资源限额、无副作用decode。写后错误仍failclosed；失败clear不能解锁。
  普通Dart构造与生命周期默认行为保持，所有runtime能力门禁仍关闭。
- 失败轮次及修复提交见 [P05_REPAIR_PLAN.md](P05_REPAIR_PLAN.md)。实际CI于2026-10-08
  结束，本报告于2026-10-09核对；后续仅文档提交不代表新的编译SHA。

### 历史同 SHA CI 证据（7159af4，旧覆盖范围）

- release [37701163766](https://github.com/Justintunsday/Piliglass/actions/runs/37701163766)
  5/5 jobs success；聚合门禁 9 个 outcome（含 `ACCOUNT_ENVELOPE_OUTCOME`）全部 success，
  0 个 contract error；Runner `BUILD SUCCEEDED`、Runner.app 109.1MB、实际
  `Verified Aether FFmpeg precedes media-kit FFmpeg in Mach-O load order`。
- preview [37701168438](https://github.com/Justintunsday/Piliglass/actions/runs/37701168438)
  4/4 jobs success（player-controls、account-pages、image-preview、preview）。
- envelope driver artifact `status=passed`：
  - 8 个真实 Dart producer tests、10 个 actual Dart 观察、2 个 fresh goldens；
  - 108 项 Native strict oracle checks、43 个精确负例；
  - 36 项真实 Security Keychain staging checks；
  - 29 项 durable 单账户 transaction checks；
  - 24 项 durable authority handoff/revert/crash-recovery checks。
- 账户组 artifact：定向 `dart analyze --fatal-infos` **No issues found!**；
  `flutter test test/utils/accounts/` 实际 **`+146: All tests passed!`**（含 2 项新增
  reverse-import 测试与 reset port 回归）；tracker 72 checks。
- fresh golden 在 Swift 编译前、运行前、运行后三次 SHA256 复核；source-clean 只要求
  本合同源文件与 HEAD 一致，记录实际 build patch diff；失败或 skip 一律 fail。

## 2. 本阶段提交

| Commit | 内容 |
|---|---|
| `0aa98b5` | 共享 strict parser/`decodeValue`/累计 jar budget；capture-local DTO+codec，一次 parse + resource preflight + 共享 ledger |
| `c2bc5ab` | 7 live + 1 cold 真实 Dart producer goldens |
| `f361947`/`d1ef763` | 独立 oracle、driver、第九强制 outcome；fixture `SameSite` 修复 |
| `2545196` | 隔离 Keychain shadow store（唯一 manifest 指针、reread、写后错误读回、unknown ack 双保留、operation gate） |
| `eeed9ab` | shadow 单账户 Cookie durable transaction（save/delete/deleteAll） |
| `33345be`/`d2058d3` | 扩展临时 selection+history、credentials、activated；Swift enum `.index` 修复 |
| `52e4471`/`2cb8ce5` | durable authority marker + 两阶段 handoff/revert/reverseExport + 崩溃恢复；marker 写前错误读回判定 |
| `e3aedcc`/`4ad0970`/`6c6d615`/`7159af4` | Dart reverse-import reader + 真实测试；analyzer 修复（SameSite 已在前、`Object?` 提升、tearoff、cascade、unused） |
| `2af4c98`/`8c079f9`/`1ff64a0` + 本报告 | 验收记录、状态矩阵与报告 |

## 3. P05 目标覆盖矩阵

| P05 目标 | 当前 Native 状态 | CI 证据 | 剩余 |
|---|---|---|---|
| 认证（QR/密码/SMS/Cookie/Geetest/手机验证、刷新、退出） | 独立 Native 状态机/协议与 synthetic 合同此前通过；production 执行器未安装 | 既有 bundle 合同 | production 安装 + 真实账户验收 |
| Cookie 格式与 mutation | strict 有序 jar2、累计 ledger、纯 reducer、shadow durable transaction（含 selection/credentials/activated） | 本轮108/43/40/35 checks | 生产 store 事务运行时接入、持久用途/install/buvid |
| 签名 | Native signer/body codec 合同通过；运行时未安装 | 既有签字/正文合同 | production 调用装配 |
| 四用途账户状态 | 只读 snapshot/selection 合同；完整 capture；临时 selection/history shadow 事务 | 账户157 tests、72 tracker、51 authority checks | 运行时 proxy、持久用途、真实账户切换 |
| 账户持久化 | 完整账户 Keychain shadow + 唯一 manifest + 真实重启；authority 组件；Dart 空目标内存恢复（持久回退未完成） | 本轮staging40、transaction35、authority51实际通过 | durable reverse replacement、record identity registry、安全孤儿清理、运行时切换 |
| 统一读写权威 | 未完成；Dart 仍是默认读写者 | — | CA3 全部 |
| 原生网络兼容边界 | policy 描述/lease/capability 合同此前通过；transport 未 parity | 既有 HTTP/transport 合同 | proxy/retry/pool/H1/H2/TLS/timeout/raw Set-Cookie/gRPC metadata |
| 真实账户/设备（CA5/CA6） | 未执行 | — | 测试设备与账户输入 |

## 4. 数据流与边界

生产运行时仍是：

```text
SwiftUI/UIKit -> MainActor State/ViewModel -> Domain Repository
  -> Data adapter（Dart 转发）-> FlutterMethodChannel -> Dart Accounts/AccountManager/Dio/Hive
```

新增 Native 能力是**已验证但未安装为运行时权威**的路径：

```text
Dart live registry -> capture service（checkpoint+全量复核）-> strict codec
  -> 隔离 Keychain shadow（单 manifest 指针）
  -> 单账户 durable transaction（ordered reducer / 临时 selection / credentials / activated）
  -> authority marker + coordinator（handoff / resume / reverseExport / completeRevert）
  -> Dart 空目标内存恢复（完整 jar、双顺序、选择；不是 durable rollback）
```

四能力标志（`durableIdentityConfigured`、`durabilityVerified`、`authoritySwitchAllowed`、
`nativeWritesAllowed`）在 capture、候选与 receipt 中全部保持 false。

## 5. reader/writer 覆盖与旁路

已收口端口（默认 Dart 同步转发，行为不变）：response Cookie mutation、install/import、
登录账户删除、匿名 reset + Hive clear。响应写回链（`AccountManager._saveCookies`
normal/403/redirect + Hive persistence、Native HTTP lease `finish`）已接入共享
admission/drain 协调器（`d255506`），但只是局部 gate：没有生产 freeze caller，写入
时序与 Dart writer 不变。

仍未收口：`Accounts.set/selectTemporarily` 的持久用途双账户语义、install/buvid 补值、
`refresh` 对账、install/import/delete/reset 的协调器 admission、WK Cookie 镜像、
credential reader 的其余读取（csrf/accessKey/grpcHeaders/用途路由/`account.values/toMap`
页面读取；`AccountManager.onRequest` 与 lease `_captureInput` 两个请求路径已接入只读
adapter，见 §10）、Hive compaction/close、LoginUtils 副作用。

## 6. 持久化、崩溃与回退

- shadow：候选先 decode+encode+全量 reread，后写 manifest；写失败按读回判定；unknown
  ack 保留双方；cancel 只删除未引用候选。
- authority marker：写前错误且读回为旧值 = 确定未发布；读回为新值 = 已发布；否则
  `publicationUnknown`，由下次 `resume()` 的 durable 读回决定，不重放 handoff。
- 崩溃恢复：无 marker = Dart authority；corrupt/未知 schema/transitioning/reverting
  fail closed；nativeActive 但候选缺失 fail closed；从不静默回退旧 Hive。
- 回退：`reverseExport()` 返回完整 schema2 envelope。`completeRevert()` 要求调用方先
  完成 durable Dart 消费；当前空目标 apply 不满足该前提，运行时不得将两者连接。
  marker 未能清除时按 durable 读回决定 authority，未知结果不自动重放。
- 持久化恢复 Vault（2026-10-09 新增）：`native_account_reverse_restore_store.dart`
  在独立 `Box<String>` 保存版本化候选与唯一 manifest，协议为纯候选验证→候选写入→
  精确读回→CAS→单指针发布→读回；写前/写后错误、unknown ack、取消、重入、corrupt
  manifest/record、missing record 与真实 Hive close/reopen 均通过。Codex 审核 R1–R4
  已在 `f1eb57b` 修复：create-only 事务 ID 拒绝覆写、按本轮所有权清理、gate/fence/ID
  预留按物理 vault domain 共享、有界 strict JSON 入口；账户 176 tests（19 Vault）。
  复审 R5/R6/C1 已在 `55d6add` 修复：只序列化 strict decode 的 owned 快照、弱键
  Expando 域注册并拒绝 primitive domain、legacy 内容 oracle 预冻结；账户 182 tests
  （25 Vault）。
  它只解决“durable 消费目标”组件；启动 apply、`completeRevert` 接线与跨重启完整账户
  恢复仍未实现，legacy Hive 重启属性丢失仍未修复，`box.get` 内存读不等于后端故障
  下的 durable-readback 证明。
- 修复后的 marker 按确切 UUID 与 immutable digest descriptor 读取候选，shadow 的
  替换/discard 保留已发布记录。仅未发布候选允许清理；跨 authority/shadow 的引用安全
  GC 尚未实现，因此已发布记录暂时保留，不能按当前 manifest 单独删除旧候选。

## 7. 未完成项与原因

1. **CA3 统一 reader/writer 与运行时 proxy**：需要把 Accounts 全部 reader/writer 与
   在途 writer 屏障切到同一 authority，并实现 Dart proxy；在无真机/真实账户验证的情况下
   强行启用会违反“未验证不开放默认 authority”，因此保持关闭。持久化恢复 Vault 已提供
   组件，但尚未接入启动 apply 或 `completeRevert`。
2. **持久用途/install/buvid durable 事务**：`Accounts.set` 的双账户 type 变更与
   install/import 的凭据写入需要账号级原子事务与 durable identity；未实现。
3. **Native 登录/签名 production 安装**：协议与 synthetic 合同已存在，但 production
   执行器未安装，无法在 CI 中证明真实登录路径。
4. **网络 transport parity**：proxy/retry/pool/H1/H2/TLS/timeout/raw Set-Cookie/gRPC
   metadata 未被 Native 完整支持；未验证组合继续显式走 Dart。
5. **CA5/CA6 真实账户/设备验收**：本环境没有测试设备与账户输入，未执行；不伪造结论。

## 8. 回滚

按提交 `git revert` 即可；运行时权威从未切换，回滚不涉及数据迁移。必要的依赖提交：
本阶段未新增任何 package 依赖。

## 9. 审核建议

- 复核路径：先读 driver `summary.json` 与 `*-result.log`，再核对 release 的聚合门禁
  outcome 与 Runner 构建日志；不要以 continue-on-error step 的 surface conclusion 作为
  证据。
- 重点检查：marker 的写前/写后/unknown 三分支、`resume()` 的 fail-closed 条件、
  reverse import 的 raw key 缓存与 jar 逐字节保真、transaction 的累计 ledger 重验。
- 已知限制：本阶段所有账户数据均为 synthetic；正样本来自真实 Dart capture，但未做
  真机登录/切号/重启验证。P05 的“完成”判定必须等待 CA5/CA6 在测试设备上完成。

## 10. 2026-10-10 CA3 credential reader 只读组验收（9dc8e04）

- 同代码 SHA `9dc8e041597ce1397e4ca228f9ea8c630d5b0583` 的
  release [38004792296](https://github.com/Justintunsday/Piliglass/actions/runs/38004792296)
  5/5 与 preview [38004795029](https://github.com/Justintunsday/Piliglass/actions/runs/38004795029)
  4/4 jobs success；九个强制 outcome 全 success、0 contract error；Runner
  `BUILD SUCCEEDED`、109.1MB、Aether FFmpeg 先于 media-kit FFmpeg。
- 新增 `lib/services/native_accounts/account_credential_reader.dart`：不可变 owned 快照、
  `csrfFor`、`visibleAccounts`；纯读（不改 revision、不 activate 匿名、不写 jar/Hive/
  网络）；`AccountManager.onRequest` 与 Native lease `_captureInput` 默认共享
  `accountCredentialReader`，null 时保持既有 revoked 路径；owner/generation 检查不变，
  默认 Dart 行为等价。计划见 [P05_CREDENTIAL_READER_PLAN.md](P05_CREDENTIAL_READER_PLAN.md)。
- 账户 artifact：analyze 无问题、实际 `+208: All tests passed!`（196→208，+12：reader
  契约 6、lease 接线 2、manager 接线 2、真实 save/Hive 抛错 2；frozen/redirect 断言按
  补测要求重写）。
- envelope `status=passed`：108 oracle/10 观察/43 负例/40 staging/35 transaction/
  51 authority；跑后源码零 diff、sourceSHA/workflowSHA 与代码 SHA 一致；preview 20
  tests 0 failures、压力 `failures=[]`。
- 上一组补测 1–3 同组完成；补测 4 记录：image-preview 就绪等待是 ready deadline 从 6s
  放宽到 16s 的稳定性调整（`83c7b20`），不宣称维持原 6 秒性能门槛。
- 失败轮次：`a16a318` 修复 hostCookies 三层 map 展开 analyzer；`9dc8e04` 修复 successor
  SESSDATA 断言字符串；旧 run 取消后同 SHA 重跑通过，无跳过、无放宽。
- 范围与边界：只读 adapter 与两个请求路径接线；csrf/100+ endpoint、accessKey/页面读取、
  生命周期 writer barrier、WK 镜像、LoginUtils 延迟副作用、Hive close/compact 仍待后续
  切片（[P05_REMAINING_SCOPE_PLAN.md](P05_REMAINING_SCOPE_PLAN.md)、
  [P05_WRITE_BARRIER_PLAN.md](P05_WRITE_BARRIER_PLAN.md)）。四 flag false，P05 未整体完成。

## 11. 2026-10-12 Block 2 / B2e-1 队列与 unknown 语义退修（`0ea82b1`；等待 Codex 独立复审）

- 同代码 SHA `0ea82b138b5e2ad63f867e7466fb31a08a42cbef` 的 release
  [38263993936](https://github.com/Justintunsday/Piliglass/actions/runs/38263993936)
  5/5 与 preview
  [38264008966](https://github.com/Justintunsday/Piliglass/actions/runs/38264008966)
  4/4 jobs success；九个强制 outcome 全 success、Runner `BUILD SUCCEEDED`、Runner.app
  109.1MB、Aether FFmpeg 先于 media-kit FFmpeg；preview 20 tests 0 failures、压力
  `"failures": []`（含 `returned-top-dark` 报告）。
- envelope `status=passed`：109 oracle/10 观察/44 负例/40 staging/**245**（core 68 +
  identity 177）/queue **104**/51 authority；sourceSHA=workflowSHA=`0ea82b1`、87 源码
  hash、7 项声明 build-preparation diff、golden `a9e6…`/`57e5…`；账户
  `+258: All tests passed!`、runtime 72、analyze `No issues found!`。
- 内容：R13 fail-closed unknown fence + `resolveUnresolvedPublication` 读回；R14
  unknownA/B admission 屏障；R15 queued 预算/竞争耗尽释放→合法 follower、真实 queued
  purpose 竞争与 previous-holder 失效拒绝、purpose/temporarySelection/activated/buvid
  receipt identity；R16 入口协调策略；R17 实际 activated 基线的取反溢出证明；R18
  A/B/C receipt→candidate 关联。transaction phase 因三次 180s 纯编译超时，按逐行内容
  不变拆成两个编译单元（预算/严格性/断言不变）。
- 边界：仍 shadow、无生产 caller/authority；B2e-2（unknown 持久恢复面/启动 recovery）
  与 B2e-3（生产 composition 接线）未做；四 flag false。**本组尚未获 Codex 独立
  PASS，不构成 P05 完成或账号级队列生产接入。**

## 12. 2026-10-15 Block 2 / B2e-1 R19–R22 退修（`b7f6692`；Codex 有限 PASS，仅该 shadow 组件）

- 同代码 SHA `b7f66928cbe9a02cb78d0be83bdc40b7319c4b20`：
  - release [38746975413](https://github.com/Justintunsday/Piliglass/actions/runs/38746975413)
    success 5/5（attempt1）：九强制 outcome 全 success、`BUILD SUCCEEDED`、Runner.app
    109.1MB、Aether FFmpeg 先于 media-kit；envelope `status=passed`
    109/44/40/**245**(68+177)/**148**/51；87 源码 hash（85 匹配 + 2 声明 pubspec 构建
    准备差异）；golden `bff67a…`/`2337a9…`；账户 `+258: All tests passed!`、runtime 72、
    analyze `No issues found!`。
  - preview [38746988047](https://github.com/Justintunsday/Piliglass/actions/runs/38746988047)：
    attempt1 仅 `preview` job 失败（`last-row` 30s poll 无 layout report；其余 3 jobs
    11 tests 通过；原因未被证明为 flake，也无源码缺陷证据，preview 输入不在该退修
    delta 内）；保留 attempt1 证据、仅对失败 job 同 SHA 单次重试 → attempt2 success
    4/4：navigation 9 tests 0 failures + attempt1 同 SHA 的 account6/image3/player2
    （不重复计入重试执行），合计 20 tests 0 failures；`last-row`/`returned-top-dark`
    JSON 齐全、压力 `failures=[]`（100000 danmaku/1000 comments）。
- 内容：R19 以 caller-minted `candidateTransactionID`（无碰撞）把 unknown 关联到
  attempted operation ID，resolution 三态 + 内容旁证字段（非操作证明）；R20 单飞 +
  post-await token 复核 + 取消不释放 fence；R21 取消回归改用非覆盖式 jar witness +
  精确计数；R22 修正 raw retained candidate 与 published pointer 混淆（真实基线 +
  retained `loadPublishedCandidate` + 精确 ±计数）。未删断言、未放宽预算/门禁、
  未过早清理未知候选。
- Codex FINAL DISPOSITION：**PASS 仅限 B2e-1 in-process queue/receipt/
  unknown-resolution R13–R22 组件**。明确不是 Block1/2/P05 完成、不是跨重启持久恢复
  （B2e-2）、不是生产接线（B2e-3/Block3）、不是真机/账户验收、不授权 authority；
  53aed63 tagged-bound-reader 保留项仍开放。四 flag false。

## 13. 2026-10-15 tagged-bound credential reader（`e3ea5ae`；Codex 有限 PASS）

- 同代码 SHA `e3ea5ae7eec4ce7847577dd5347a2d73d97d823d`：release
  [38756024676](https://github.com/Justintunsday/Piliglass/actions/runs/38756024676)
  success5/5 与 preview
  [38756042155](https://github.com/Justintunsday/Piliglass/actions/runs/38756042155)
  success4/4（均首轮尝试、无 job 重跑）；九强制 outcome 全 success、`BUILD SUCCEEDED`、
  Runner.app 109.1MB、Aether FFmpeg 先于 media-kit；envelope `status=passed`
  109/44/40/**245**(68+177)/**148**/51；87 源 hash（85 匹配 + 2 声明 pubspec）、golden
  `8d3742…`/`fd1b38…`；账户 **264** tests（258+6）/runtime 72/analyze 无问题；preview
  20 tests 0 failures、11 layout reports、压力 `failures=[]`。
- 内容：`AccountCredentialBinding`/`AccountBoundCredential<T>` 三态；reader 新增
  `boundCsrfFor`/`boundAccessKeyFor` 并保留 legacy nullable wrapper；`Accounts.boundCsrf/
  boundAccessKey` 返回 tagged；`csrfOf` 对 rejected stamp 抛 `StateError`（不回退 raw
  csrf），no-stamp legacy 直读保留；`accessKeyOf` retired/rejected → null、合法 nullable
  accessKey 属 bound(null)；消费者盘点（AccountManager/lease 已 fail closed、100+ csrfOf
  endpoints 继承 wrapper 语义、15 处 accessKeyOf、snapshot service 自带
  owner/generation + checkpoint）。
- Codex FINAL DISPOSITION：**PASS 仅限该只读 adapter/wrapper 与消费者盘点范围**。
  Carry-forward：no-stamp legacy csrf 仍可能读到 retired 旧字段（明确文档化，不构成
  全部 reader 收口）；计划中 `restoreEmptyCaptured` captured-window 定向回归本组未执行，
  恢复组必须补做并报告实际执行；100+ endpoint 显式 tagged 消费、refresh/grpc/snapshot
  残余直读仍属 Block1；B2e-2 持久恢复、B2e-3/Block3 composition、CA5/CA6 与 authority
  均未闭合；四 flag false，P05 未完成。

## 14. 2026-10-16 B2e-2a/2c 持久 recovery journal + R23–R35（`75d829c`；Codex 有限 PASS）

- 同代码 SHA `75d829c2d99f5eccc62da57d4cf3e33876222aee`：release
  [38810974696](https://github.com/Justintunsday/Piliglass/actions/runs/38810974696)
  success5/5 与 preview
  [38810980896](https://github.com/Justintunsday/Piliglass/actions/runs/38810980896)
  success4/4（均首次尝试、无 job 重跑）；九强制 outcome 全 success、`BUILD SUCCEEDED`、
  109.1MB、Aether FFmpeg 先于 media-kit；native 109/44/40/**245**(68+177)/**292**/51、
  producer 8/10/2、账户 265/runtime 72/analyze 无问题；88 raw source hash（86 匹配 +
  2 声明 pubspec）、golden `933df5…`/`915f69…`；preview 20 tests、11 reports、
  压力 `failures=[]`；Swift 6 strict-concurrency complete（未声称 warnings-as-errors）。
- 内容：单槽 vault recovery journal（canonical 严格解码/4096B、写 journal 先于候选/指针、
  期望前置指针 + attempted ID 持久化）、R23 成功 nil 读 ≠ 读错误、R24 默认歧义保留 +
  显式 `allowAmbiguous` 确认、R25 真实 Keychain 隔离 namespace 四崩溃前缀 client reopen、
  R26–R33 冷加载协调化、R28 post-await 重验证、R31/R32 task-local 队列所有权 + 冷窗口
  outsider 拒绝、R34 无 IO 计数记账、R35 clear pre-commit 取消边界 + commit/point-of-
  no-return 语义；实际 Dart `restoreEmptyCaptured` captured-window 回归执行。
- 边界：**不构成 whole Block2/P05**；无 process-kill/断电/真机/账户证据；B2e-2b identity
  消费者对齐、B2e-3/Block3 生产 composition/handoff/revert/启动/GC、Block1/4 残余
  reader、Block5 真机清单未闭合；raw uncorrelated import 仍 out-of-contract；四 flag false。

## 15. 2026-10-16 R36/R37 preview-harness 诊断/owned-report 门（`b73efec`；Codex 有限 PASS）

- 同代码 SHA `b73efec39e68aac3a941abc3df313072042bb4c7`：release
  [38820520873](https://github.com/Justintunsday/Piliglass/actions/runs/38820520873)
  success5/5 与 preview
  [38820524983](https://github.com/Justintunsday/Piliglass/actions/runs/38820524983)
  success4/4（均首次尝试）；九强制 outcome/BUILD/FFmpeg；native 109/44/40/245/**292**/51、
  producer 8/10/2、账户 265/72、88 源 hash（86+2）、golden `462110…`/`2264d5…`；preview
  20 tests、11 reports（每个 modeToken==launch-trace token 且 launchPID==解析 PID、
  streamsSupported=true、22 stream 文件）、压力 `failures=[]`。
- 内容：launch 失败硬保留（先写有界证据再 re-raise，绝不进入接受路径）；唯一 token +
  `launchPID` + mtime≥launchStart 的 owned 报告接受；纯本地负例自测；launchctl 20s 有界
  distinct status；runner `simctl help` 判定的 stdout/stderr 捕获；app 侧 pre/post-scroll
  实际 offset、取消与 encode/write 阶段证据；30s/25min 预算、layout 断言/截图/UI 未变。
- 边界：**不证明此前 last-row 缺失报告的根因**（成功 instrumented run ≠ 因果证明）；
  诊断文件与成功报告分离；本地 3 项 mock 控制流 QA 不是 CI 计数或模拟器/设备执行；
  前驱 8cf6629/085d883 preview failure 保留；无真机/authority 结论；四 flag false。
- 记录为 docs-only commit，不代表 code CI SHA；实际测试 SC SHA 为上述两个代码 SHA。

## 18. 2026-10-16 B1f purpose path-routing + R43 矩阵 + harness R44–R47（`a50ea69`；Codex 有限 PASS）

- 同代码 SHA `a50ea693c2d4b7d410fff9e29c40ad437af941ac`：release
  [38864047457](https://github.com/Justintunsday/Piliglass/actions/runs/38864047457)
  success5/5 与 preview
  [38864051135](https://github.com/Justintunsday/Piliglass/actions/runs/38864051135)
  success4/4（均首次尝试、无 job 重跑）；九强制 outcome 全 success、`BUILD SUCCEEDED`、
  Runner.app 109.1MB、实际执行 Aether FFmpeg 先于 media-kit 的 Mach-O 验证；账户
  **293** tests/runtime 72/strict analyze clean；envelope 109/44 负例/1 synthetic/40
  staging/**245**(68+177)/**292**/51；producer 8/10/2；89 raw Git blob 87 match+2 声明
  pubspec；golden `be8600df…`（live memory）/`b7a6bf49…`（Hive reopen）；Mac QA 45/45
  （EOF-shortchild race/integration/ready SIG_IGN/no alive/bounded elapsed 1.45s；
  synthetic 进程 QA ≠ 模拟器/设备证据）；navigation streamed phases launch 07:13:11Z/
  exit0 07:20:33Z/export0 07:20:38Z；UI 20 tests：navigation 345.291s + image 120.287s
  （comment 30.413s/dynamic 23.654s/failed-single 66.220s，均在**恢复后的定时 XCTest
  gate**下实际执行）+ account 173.057s + player 115.890s；home 11 accepted reports
  各自 token/PID 匹配 + 22 stream 文件；压力 `failures[]`。
- 内容：B1f real Dio+AccountManager 9 项 path-routing 回归（video/HB 匿名负例/real HB
  表/recommend/login 匿名/unmatched main/preset precedence/slot 切换后 boundA/reader
  context consumption）；R43 discriminating purpose 矩阵 + header/cookie owner
  provenance；R44–R47 harness（非掩蔽生命周期诊断/有界清理、迭代独立检查 + EOF 流状态 +
  owned PGID 清理、post-wait 重验证 + POSIX readiness + `run_navigation` 集成负例、
  恢复 `XCTNSPredicateExpectation`+`XCTWaiter`，最多 5s，`completed` 之外一律失败，
  无循环后 fresh predicate）。
- 前驱失败/拒绝保留（不追溯改判）：`ced3b19` void-await（`use_of_void_result` ERROR +
  `await_only_futures` INFO 阻塞实际执行）；`d5f9d0c` preview 25m 硬取消 + account-pages
  `testGuestDoesNotShowAccountData` 在 app.launch 的 terminate 失败；`f84314a` image
  comment-gallery zoom 5s 失败 + navigation Settings tap 失败 + pressure SKIPPED；
  `ea4c609`/`cb71a52` 双绿但 reviewer 以 R45/R47 拒绝（green ≠ gate 接受）。
- 精度：R47 source comment 的 "exactly 5 seconds" 按**最多 5s waiter 上界**理解（满足即
  提前完成）；`openMine()` 为 8s 存在 THEN 另加 8s 选中（两次顺序上界，非共享单 8s）；
  本次绿色不是历史 gesture/AX/app termination/hang 的因果证明；real GitHub hard cancel
  仍可能跳过上传。
- 边界：有限 PASS 仅上述已测试路径；不构成 whole Block1（120 csrf/18 access 全量消费、
  whole writer async closure、gRPC purpose binding、generic purpose CAS read-transform-
  publish 干扰）、B2e-2b bridge/frozen revision、Block3 composition/handoff/revert/startup/
  GC、Block4、CA5/CA6 设备授权、whole P05 或生产 authority；四 flag false；本记录为
  docs-only commit，不代表 code CI SHA（实际测试 SHA 为 `a50ea69`）。

## 17. 2026-10-16 B1e refresh/export reader seam + R39–R42（`c6eb327`；Codex 有限 PASS）

- 同代码 SHA `c6eb32769b69290a8991281db295c54e14bb6fb0`：release
  [38843199175](https://github.com/Justintunsday/Piliglass/actions/runs/38843199175)
  success5/5 与 preview
  [38843202056](https://github.com/Justintunsday/Piliglass/actions/runs/38843202056)
  success4/4（均首次尝试、无 job 重跑）；九强制 outcome 全 success、`BUILD SUCCEEDED`、
  Runner.app 109.1MB、Aether FFmpeg 先于 media-kit；账户 **284** tests/runtime 72/
  strict analyze clean；envelope 109/44/40/**245**(68+177)/**292**/51；producer
  8/10/2；89 raw Git blob 87 match+2 声明 pubspec；golden `cd7b0d…`/`044f33…`；preview
  9+3+6+2=20 tests 0 failure（**两个 player 用例实际通过**：embedded 19.6s、landscape
  17.6s）、11 owned reports/22 stream files/layout flags/压力 `failures[]`。
- 内容：refresh tagged nullable binding（no-stamp legacy/rejected 不回退 raw/bound(null)
  合法）；snapshot descriptor/secret-entry 与 shadow export 同一 reader seam fail closed、
  同一注入 reader 的 post-checkpoint/`verifyCurrent` 复验；R39 文本清单修正；R40/R41
  定向负例与精确 3/3 计数；R42 fixture 8.0（生产支持值）+ configured-vs-effective 断言。
- 前驱保留：`3658406`/`209885f` strict-analysis fatal + aggregate 失败；`ae73dcf`
  release 绿但 preview 19/20（player-controls landscape）。
- 精度：AX 树 chrome/720P **缺失**为观察；alpha=0 为生产代码支持的推断而非直接遥测；
  本次绿色不是历史 tap/AX/timer 因果证明（H1–H4 未证）。
- 边界：**不构成 whole Block1/P05**；endpoint csrfOf/accessKeyOf tagged 迁移、writer 边界
  审计、B2e-2b durable bridge/frozen revision、Block3 composition/handoff/revert/startup/
  GC、Block4/5 与 authority 未闭合；四 flag false；本记录为 docs-only commit，不代表
  code CI SHA（实际测试 SHA 为 `c6eb327`）。

## 16. 2026-10-16 B2e-2b-1 schema-3 reverse-import 严格解码 + R38 预投影记账（`ea60931`；Codex 有限 PASS）

- 同代码 SHA `ea609317e499a200b1d1fcc55d5a9127aba9e44d`：release
  [38829392361](https://github.com/Justintunsday/Piliglass/actions/runs/38829392361)
  success5/5 与 preview
  [38829396589](https://github.com/Justintunsday/Piliglass/actions/runs/38829396589)
  success4/4（均首次尝试、无 job 重跑）；九强制 outcome 全 success、`BUILD SUCCEEDED`、
  Runner.app 109.1MB、Aether FFmpeg 先于 media-kit；账户 `+269: All tests passed!`
  （含 R38 unit-budget 边界实际执行）/runtime 72/strict analyze `No issues found!`；
  envelope 109（obs=10/negative=44/synthetic=1/runtimeEnabled=false）/staging 40/
  transactions **245**(68+177)/queue **292**/authority 51；producer 8 tests/10
  observations/2 goldens；golden `041724…`/`ae2e5f…`；88 raw blob 86 匹配 + 2 声明
  pubspec（Codex 独立复核）；source-clean before/after、sourceRevision 前后=ea60931；
  preview 20 tests（9+3+6+2）0 failures、11 reports（8 home + 3 settings，每个唯一
  modeToken==trace token、launchPID==解析 PID）、压力 `"failures": []`。
- 内容：schema-3 durable-identity strict decode（canonical 36-unit 小写 UUID/唯一/
  anonymous null-or-omitted/high-water/tracker namespace 拒绝）+ immutable
  `recordDurableIdentities`（correlation-only）+ R38：`durableIdentity` units 并入
  `_preflight` 同一累计账本、删除晚计费（无双重计费）；新增 exact-budget/+1/预投影
  37-unit `resourceLimit` 边界与 37-unit/null-high-water/anonymous-omitted 用例。
- 前驱保留：`ed89e9f` 绿色但 R38 open；`a0e76ed` 因 test70:33 strict-analysis info
  致下游 ACCOUNT_DART/NATIVE/COOKIES/ENVELOPE_OUTCOME 被 aggregate 正确拒绝（preview
  4/4 不替代），修复仅包块且未改 lint/options/fatal-infos/断言/caps。
- 边界：**不构成 whole B2e-2b/Block2/P05**；`apply()` 不携带 durable labels、非
  Swift→Dart 端到端 handoff/revert 证据；bridge export/frozen-revision/startup/revert/
  GC/production composition、authority/process-kill/真机未闭合；四 flag false；本记录为
  docs-only commit，不代表 code CI SHA（实际测试 SHA 为 `ea60931`）。
