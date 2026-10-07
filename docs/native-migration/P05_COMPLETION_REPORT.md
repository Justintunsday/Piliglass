# P05 完成报告（独立审查版）

2026-10-07（Asia/Hong_Kong），分支 `codex/native-migration`，已验证代码 SHA
`7159af42e4dd942f989467d8c5a9eb77fb2a42e7`。

## 结论摘要

- 本阶段把 P05 的**账户格式、严格 codec、隔离 Keychain 持久化、shadow 单账户事务、
  durable authority marker/handoff/revert 与 Dart reverse import** 实现并全部通过同 SHA
  release5 + preview4 实际 CI。
- **P05 仍未整体完成**：Native authority 的运行时 Dart proxy/切换组合、持久用途与
  install/buvid 事务、Native 登录/签名的 production 安装、proxy/retry/pool/H1/H2/TLS/
  timeout/raw fields 的 transport parity，以及真实账户/设备验收（CA5/CA6）尚未交付。
  这些不是本报告的口头保留，而是本环境无法安全验证的范围；门禁继续保持关闭。
- 所有完成项均由真实 Actions 日志、artifacts、独立 oracle 与聚合门禁证明；没有使用
  `continue-on-error` 的外观 success 或本地静态检查作为验收。

## 1. 同 SHA CI 证据（7159af4）

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
| Cookie 格式与 mutation | strict 有序 jar2、累计 ledger、纯 reducer、shadow durable transaction（含 selection/credentials/activated） | 108/43/36/29 checks | 生产 store 事务运行时接入、持久用途/install/buvid |
| 签名 | Native signer/body codec 合同通过；运行时未安装 | 既有签字/正文合同 | production 调用装配 |
| 四用途账户状态 | 只读 snapshot/selection 合同；完整 capture；临时 selection/history shadow 事务 | 账户 146 tests、72 tracker、24 authority checks | 运行时 proxy、持久用途、真实账户切换 |
| 账户持久化 | 完整账户 Keychain shadow + 唯一 manifest + 真实重启；durable authority marker/handoff/revert；Dart reverse import 重建完整 jar/attrs/顺序/选择 | staging 36、transaction 29、authority 24、reverse 测试 | durable record identity registry、孤儿清理、运行时切换 |
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
  -> Dart reverse import（重建 LoginAccount、jar、顺序与选择）
```

四能力标志（`durableIdentityConfigured`、`durabilityVerified`、`authoritySwitchAllowed`、
`nativeWritesAllowed`）在 capture、候选与 receipt 中全部保持 false。

## 5. reader/writer 覆盖与旁路

已收口端口（默认 Dart 同步转发，行为不变）：response Cookie mutation、install/import、
登录账户删除、匿名 reset + Hive clear。

仍未收口：`Accounts.set/selectTemporarily` 的持久用途双账户语义、install/buvid 补值、
`refresh` 对账、`AccountManager._saveCookies` 的 redirect/403 写回、Native HTTP lease
finish 写回、WK Cookie 镜像、全部 credential reader（csrf/accessKey/grpcHeaders/用途路由/
`account.values/toMap` 页面读取）、Hive compaction/close、LoginUtils 副作用。

## 6. 持久化、崩溃与回退

- shadow：候选先 decode+encode+全量 reread，后写 manifest；写失败按读回判定；unknown
  ack 保留双方；cancel 只删除未引用候选。
- authority marker：写前错误且读回为旧值 = 确定未发布；读回为新值 = 已发布；否则
  `publicationUnknown`，由下次 `resume()` 的 durable 读回决定，不重放 handoff。
- 崩溃恢复：无 marker = Dart authority；corrupt/未知 schema/transitioning/reverting
  fail closed；nativeActive 但候选缺失 fail closed；从不静默回退旧 Hive。
- 回退：`reverseExport()` 幂等返回完整 schema2 envelope；Dart 反导入完成后
  `completeRevert()` 以读回证明清除 marker；marker 未能清除时保持 Native authority。
- 孤儿：只按 manifest 引用清理；不假设可枚举 secret store 做 namespace 扫描，孤儿
  清理与 durable record identity 一起作为后续门禁。

## 7. 未完成项与原因

1. **CA3 统一 reader/writer 与运行时 proxy**：需要把 Accounts 全部 reader/writer 与
   在途 writer 屏障切到同一 authority，并实现 Dart proxy；在无真机/真实账户验证的情况下
   强行启用会违反“未验证不开放默认 authority”，因此保持关闭。
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
