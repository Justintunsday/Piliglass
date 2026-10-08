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
