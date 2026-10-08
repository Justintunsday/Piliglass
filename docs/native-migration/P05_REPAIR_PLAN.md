# P05 交接与反向恢复审核修复

2026-10-08（Asia/Hong_Kong）。起点 `7d6766b`，对应
`build/native-migration/review-7d6766b/P05_REVIEW.md` 的12项源码审核问题。
本轮修复聚焦既有有限组件的正确性，不实现完整P05、不启用Native authority，不重写UI。

| 相关切片 | 审核项 | 实现与独立提交边界 | 必需回归 |
|---|---|---|---|
| 候选/authority | R1/R5/R6 | Vault immutable descriptor与精确UUID读取、Coordinator合法起始态、MarkerStore跨await gate；同切片接入vault CAS接口 | 同revision不同候选、missing UUID、已有权威的失败替换、corrupt/newer/transitioning/reverting拒绝且durable不变、clear/publish重入 |
| shadow RMW | R7 | TransactionStore实际携带snapshot UUID进入vault同fence CAS；保持现generation/reducer/全量验证 | 旧snapshot在direct import后拒绝；两个wrapper共用vault的确定性交错；保持原取消/unknown ack等检查 |
| reverse decode/apply | R2/R3/R4/R8–R12 | 纯owned蓝图、strict形状/累计限额、显式恢复构造边界、受验证的empty-target-only安装；保留正常Dart lifecycle | 匿名full jar/type/activated、empty/noDede、owner与stored双顺序、false activated/临时选择零请求、非空目标拒绝、malformed/type/null/order/限额、dormant独立isolate |
| 集成与证据 | 全部 | Root逐文件复核、driver最低检查数与文档状态、分切片commit/push，组末同SHA全CI | release5 + preview4全部成功，真实Dart fatal-infos/test、Swift6严格编译、新旧回归、Runner/FFmpeg/九mandatory outcomes |

## 数据安全边界

- Marker恢复读取确切候选事务，revision不作为内容或授权身份。
- 不因为shadow指针改变就删除仍可能被authority引用的immutable记录。无法证明安全的
  自动垃圾回收暂缓，保留孤儿清理/namespace枚举门禁，不能以清理造成权威记录丢失。
- RMW的expected UUID检查和发布共享vault gate，不能check后释放再无条件写入。
- 反向decoder不触碰Accounts/Hive/Pref/singleton，不调用有buvid副作用的legacy构造器。
- apply本轮只支持验证过的空目标，不以clear-before-import破坏旧状态，不把empty-target
  reader宣传为完整durable reverse replacement。写失败/未知结果不自动重放或回滚新状态。
- 所有capture/receipt能力标志继续false；runtime bridge、Dart权威与Flutter fallback保留。
- 新恢复边界不改变普通install/import/delete/refresh/set的既有默认行为或lazy缓存语义。

## 验证与交付

实际新用例数量以Actions输出为准，不将预计检查数写成通过。禁止降低fatal-infos、
删断言、用sleep/retry隐藏竞态或以本地静态分析代替编译。Windows提交前只做diff、
结构与脚本检查，Swift/Dart以macOS Actions真实结果为准。失败读取具体日志并修复，
重新commit/push后重跑同SHA完整release/preview。

每个相关切片独立可回滚提交，由Root统一审阅共享边界；不stage用户youtube/。
组末记录最终SHA/run URLs、实际新回归及未完成的production authority/真实账户门禁。

## 实施记录（失败轮次与修复）

- `741256b`：精确候选 UUID/digest、发布记录保留、handoff 起始态与 marker gate。
- `ab5ccbb`：shared vault snapshot/CAS 与确定性交错回归。
- `7f3a887`：driver 最低 staging40/transaction35/authority51，并扩大账户测试分析范围。
- `9034dc0`：纯 decoder、匿名全状态、owner/stored 双顺序、空目标 apply、实例 DI 与
  真实 Hive 写后错误/清空后错误/恢复互斥；11 main + 2 dormant 测试，当轮等待实际运行。
- 首轮 release `37773097268` 的实际 raw HTTP 日志报 `accounts.dart` 调用
  `restoreCapturedState` 时 receiver 为 `Account`；`6a434b2` 将已验证匿名 stamp 显式
  收窄为 `AnonymousAccount`。旧 run 不能作为通过证据。
- `da9f6e1` 将账户分析/测试及 envelope 合同提前到依赖准备之后，九个强制 outcome
  与完整 Runner 构建保持。当轮待验收 source 为 `da9f6e14ece3040666a78d6f7f1d213d289b7581`，
  [release 37774095527](https://github.com/Justintunsday/Piliglass/actions/runs/37774095527)
  与 [preview 37774100152](https://github.com/Justintunsday/Piliglass/actions/runs/37774100152)。
  该 SHA 的 Preview20测试全通过，但 release artifact 的 fatal-infos 实际失败9项，
  因此本组不验收。
- `967a4ee` 修正上述9项 lint，保留 fatal-infos、测试断言和九个聚合门禁。实际 envelope
  artifact 已为 `status=passed`：分析无问题，fresh producer8/观察10/goldens2，Native
  oracle108/负例43/staging40/transaction35/authority51，四次 Swift6 complete concurrency
  编译通过；62个相关源码 Git blob SHA256 与 artifact 一致。当轮完整 CI 仍待验收：
  [release 37776206860](https://github.com/Justintunsday/Piliglass/actions/runs/37776206860) 与
  [preview 37777347913](https://github.com/Justintunsday/Piliglass/actions/runs/37777347913)，
  同 source SHA `967a4ee35ce3a4617e17835ef67a743668cff79c`。
- 967a4ee 的完整账户组实际为149项成功、header-transfer setup/teardown两项失败：
  提前账户组时漏移 `check_native_http_transfer.py` 的报告前置，新恢复测试未失败。
  Root 在 `d056014` 将真实 Swift loopback producer 提前，不fabricate报告、不skip
  8项旧header-transfer测试。该组整体未验收，967a4ee Preview在被替代时取消。
  当轮 [release 37778382514](https://github.com/Justintunsday/Piliglass/actions/runs/37778382514)
  验证 `d05601495f8fdaefc34769fefba6696744772dac`；其Preview4/4通过，但账户组失败，
  release被新提交替代取消，不能作为本组整体验收。

- d056014 的 header-transfer 8项恢复通过，完整账户实际156成功/1失败：零网络测试
  捕获到测试准备 `Accounts.clear()` 的未等待 buvid 激活。`e740cac` 仅修测试 fixture：
  四用途临时选择匿名、逐个真实账户 delete、匿名 reset 均 await，不触发 clear 的激活；
  恢复新增网络请求必须0及全树/false activated/临时匿名断言保持。真实clear故障测试不变。
  同提交将账户 artifact 上传紧随该组，便于及时读取真实结果；没有放宽九个门禁。
  新 [release 37781658066](https://github.com/Justintunsday/Piliglass/actions/runs/37781658066)
  与 [preview 37782661482](https://github.com/Justintunsday/Piliglass/actions/runs/37782661482)
  验证 `e740cace879630f8968f5f0733c6af708377cddd`，实际CI于2026-10-08全部成功。

## 本轮最终验收（2026-10-09核对）

- 同上述代码SHA release5/5 + preview4/4，全九jobs成功；实际日志中九强制合同outcome
  全success、0错误，Runner `BUILD SUCCEEDED`、109.1MB，FFmpeg加载顺序通过；raw H1/H2
  对照与iOS16 package job成功。未只依据continue-on-error的surface conclusion。
- 账户artifact：fatal-infos分析无问题、tracker72、`+157: All tests passed!`。零网络断言
  保持0，11项恢复+2项dormant decoder与8项旧header-transfer真实用例均成功。
- envelope `status=passed`：sourceSHA/workflowSHA一致；producer8/观察10/goldens2，
  oracle108/负例43/staging40/transaction35/authority51；四次Swift6 complete concurrency
  编译通过；62个相关源码Git blob SHA256与artifact一致，0差异。
- Preview账户6/图片3/播放器2/导航9共20测试，0失败；压力fixture `failures=[]`。
  单次burst188.41ms仅记录观察，不据此宣称真机性能验收。
- R1–R12对应的有限组件修复与回归已验收；**P05仍未整体完成**。空目标apply仍是内存
  兼容恢复，legacy Hive重启属性丢失尚未修复，不接`completeRevert()`。发布记录安全GC、
  durable reverse replacement、runtime统一读写、真实账户/设备门禁仍在后续计划。
  四能力flag保持false，Flutter/Dart生产fallback与Aether模块边界、现有UI均保留。

验收日志与下载产物本机保存在忽略目录 `build/native-migration/repair-e740cac/`；GitHub
日志与artifacts以上述run链接为准。其后文档提交只更新证据，不改变已编译的代码SHA。
