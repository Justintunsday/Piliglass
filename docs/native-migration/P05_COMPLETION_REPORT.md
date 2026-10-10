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
