# P05 下一小切片：持久化反向恢复 Vault

2026-10-09（Asia/Hong_Kong）。实施前保存的计划，不是实现或验收证明。前置为
`28adc60` 的 P05 审核修复组；当前 `NativeAccountReverseImport` 只支持**空目标内存
恢复**，legacy Hive adapter（type8/type9）在重启后丢失完整 Cookie 属性、activated 与
临时选择，因此不能把它接到 `completeRevert()` 并宣称 durable Dart 回退完成。
本切片只交付一个可独立验收的 **Dart 持久化恢复 Vault**，不接生产 `completeRevert`、
不开启 Native authority、不改 legacy account box、不改普通 install/import 行为。

## 1. 完整账户状态的持久化与重启语义盘点

| 信息 | 现有 legacy 行为 | 恢复 Vault 处理 |
|---|---|---|
| raw storage key / MID 缓存 | `LoginAccount` 构造时从 DedeUserID 派生（`late final` 缓存），重启后重新派生 | 属于持久身份：以原始 UTF16 key 保存在 envelope；不从旧缺失数据或可变 DedeUserID 重推 |
| credentials（accessKey/refresh） | type9 字段 1/2，直接持久 | 持久 |
| persisted purposes | type9 字段 3（`Set<AccountType>`） | 持久；仍由 `refresh` 决定 effective slots |
| 完整有序 jar（domain/host buckets、path/cookie 顺序、name/value、domain/path、secure/httpOnly/SameSite/expires/maxAge、createdSeconds、ignoreExpires、空 bucket） | type8 只写根域 `/` name/value；重启丢失属性并重建 creation | 持久（schema2 envelope 原样） |
| stored order（Hive String key 顺序） | 重启由 Hive key 排序重建 | envelope 已含 `storedOrder`，持久 |
| owner order（私有 owner Map 顺序） | 不持久，重启变为 stored order | 作为 capture 元数据持久保存；是否用于恢复由后续 apply 政策决定 |
| `activated` | 不持久，重启恒 false | **session 状态**：Vault 原样保存 envelope 但不强制改变现有 session 政策；本切片不做启动 apply |
| 临时 selection / effective slots / history | 不持久；`refresh` 按持久用途重建，history 由 heartbeat/main 派生 | 同上，session 政策；不得为持久化而改变普通启动行为 |
| 匿名 singleton 状态 | 生命周期重建 | 同 envelope 记录，不改变普通匿名政策 |

结论：Vault 保存**完整 schema2 envelope**（含 session 字段的 capture 值）作为候选数据；
真正的“哪些字段在启动时恢复、哪些维持原 session 政策”属于后续 apply/authority 切片，
本切片不实现、不改变默认行为。

## 2. 恢复格式（新 box，明确版本/身份/来源）

不注册新 TypeAdapter、不重解释 typeId 8/9；使用新的 `Box<String>`（名称
`account_reverse_restore`），value 为严格 JSON 字符串，只含 map/list/int/string/bool/null。

- record（候选，key `restore-record.<transactionID>`）：
  `{formatVersion:1, source:'nativeAccountReverseExport', transactionID:<uuid>,
    authorityEpoch:<1..128 printable ASCII>, createdAtMicroseconds:<int>=0, envelope:<schema2>}`。
- manifest（唯一发布指针，key `restore-manifest`，≤4096 bytes）：
  `{formatVersion:1, source, transactionID, byteCount, sha256}`；`sha256` 为 record JSON
  UTF-8 bytes 的 SHA-256（小写 hex），`byteCount` 为同一 bytes 长度。
- identity：Dart 生成的 transaction UUID，绑定 record 与 manifest；authorityEpoch 只作
  来源标注，不参与授权判断。envelope 的 runtime generation/revision 不是跨进程身份。

## 3. 发布协议（候选→持久→完整读回→发布）

`importRestore`：operation gate → 纯 `NativeAccountReverseImport.decode` 严格验证候选 →
读取并严格校验当前 manifest（作为 CAS 基线）→ 写候选 record → 读回并比较字符串与 digest
→ **CAS 复核** manifest 仍等于基线（否则删除未发布候选并返回 staleSnapshot）→ 写 manifest
→ 读回判定：等于新 bytes 即发布；写失败但读回等于基线则删除候选并抛出真实写错误；
其余为 `publicationUnknown`。不重放、不自动删除任何仍可能被引用的已发布 record。
`loadRestore`：严格 manifest → record → 校验 byteCount/digest/版本/身份 → 纯 decode 返回
owned 结果；`publicationUnknown` 后设置恢复 fence，先经一次成功的 `loadRestore` 才允许
再次 `importRestore`。取消在候选写前与指针发布前检查，取消只删除未发布候选。
安全 GC 继续暂缓：已发布 record 一律保留，无法证明引用关系时不删除。

## 4. 测试矩阵（真实覆盖，不维持旧数量）

- 真实 Hive：import→load 全等；`close()` 后真正 `openBox` 重开再 load；legacy
  `account` box 键与对象不变。
- 进程中断：真实 Hive 中只写候选 record、无 manifest 后重开，load 为 null，随后
  import 正常发布；孤儿候选不被误认为已发布。
- fault vault：写前失败（基线保留、候选清理）、写后错误（读回判定 recovered）、
  unknown readback（双方保留、重启/新实例按 durable pointer 解析、恢复 fence）、
  staleSnapshot CAS、corrupt manifest/record、invalid candidate 零写入、取消与并发重入
  （operationInProgress / cancelled）、load 清除 fence 后才可再次 import。

## 5. 边界与验收

- 不改 `Accounts`、legacy box、普通 install/import/delete/refresh/set 与 lazy 语义；
  不新增 package 依赖；能力 flag 继续 false；不接 `completeRevert`。
- 新测试文件独立提交，随账户组真实 `flutter test test/utils/accounts/` 执行；组末同 SHA
  完整 release5 + preview4，读取实际日志/artifacts；失败按日志修复重跑。
- 交付后仍需：apply/启动恢复政策、全部 reader/writer 屏障、跨重启验证、CA4 运行时
  交接、CA2 剩余、Native 登录/签名与网络兼容、CA5/CA6 真实设备验收。

## 6. Codex 审核 R1–R4 修复计划（2026-10-09）

依据 `build/native-migration/review-e1054b3/P05_REVIEW.md`（审核不通过：R1/R2 P1，
R3/R4 P2）。本轮只修该有限 Vault 组件，不接 `completeRevert`/启动 apply、不开启
Native authority，四 flag 继续 false。

- **R1 create-only 身份**：生成 transactionID 后，在共享 gate 内先读 record key；
  已存在（durable 记录或本轮预留）即拒绝 `duplicateTransaction`，绝不覆写不可变记录。
  预留集与 gate 同属物理 vault domain；配同 ID 重用/读回失败/发布前取消回归，断言旧
  record/manifest 原字节不变且原状态仍可 load。
- **R2 本轮所有权清理**：只有“本轮独占新建 `recordCreated=true` 且未发布”的候选才允许
  清理；仅生成 ID 不取得删除权限。历史已发布 ID 冲突、写前取消、写前错误时 remove
  调用必须为 0，历史 A/T 原字节与 B/U 可 load 保持。
- **R3 物理域共享 owner/gate/CAS**：新增按 `vault.coordinationDomain`（Hive 用 Box
  实例，fault vault 用实例身份）注册的共享 domain，持有 operation gate、recovery fence、
  ID 预留；基线读取、ID 预留、候选发布、清理、recovery 全部在同一 gate 内。CAS 读与
  manifest 写不再被另一 Store 插入。补双 Store/双 Hive wrapper 受控交错、共享 unknown
  recovery、清理/发布交错；用 Completer 控制，不用 sleep/retry。
- **R4 严格持久 JSON 入口**：新增有界 strict parser（拒绝重复/转义重复字段、仅整数
  number token、深度/节点/字节预算），manifest 与 record/envelope 都走该入口；
  `formatVersion:1.0`、重复字段、配套正确 digest/byteCount 的嵌套负例必须拒绝。
- **补测**：真实 close/reopen 使用 rich Cookie attrs、host/domain/空 bucket、raw UTF16、
  nullable credentials、匿名完整状态、owner/stored 分歧与四用途实值；unknown ack 新实例
  恢复、已有基线取消、完整可 load 的竞争候选、legacy 对象 identity/content。
- 保留普通 Dart 生命周期、全部既有断言、fatal-infos 与九个强制门禁；分小 commit，
  组末同 SHA release5+preview4 实际日志/artifacts 通过后交给 Codex 复审。

### R1–R4 实施与验收（2026-10-09）

代码 SHA `f1eb57ba91d87810b04b9aff8300042e2364aed5`（计划 `85d1909`、生产
`a6d6980`、测试 `7dbf7f7`、analyzer 修复 `6a3107d`、preview 测试修复 `f1eb57b`）：

- [release 37889641481](https://github.com/Justintunsday/Piliglass/actions/runs/37889641481)
  5/5、[preview 37889644334](https://github.com/Justintunsday/Piliglass/actions/runs/37889644334)
  4/4 jobs 全 success；九个强制 outcome 全 success、0 contract error；Runner
  `BUILD SUCCEEDED`、109.1MB、FFmpeg 顺序实际通过。
- 账户 artifact：`dart analyze --fatal-infos` No issues found，真实 `+176: All tests
  passed!`（上轮 157 旧 + 19 Vault；本轮新增 8 项 R1–R4 回归：重复事务 ID、读回失败、
  历史 ID 冲突/写前取消、清理交错、双 Store、双 Hive wrapper、rich reopen、strict JSON）。
- envelope artifact `status=passed`：108/43/40/35/51 与上轮一致。
- 真实失败与修复：首轮 analyze 报 `prefer_initializing_formals` 与
  `prefer_interpolation_to_compose_strings`（`6a3107d`）；同 SHA preview 的
  account-pages `testMineServiceAndToolbarActions` 在慢 runner 下单次 `swipeUp`
  未滚出“切换账号”，改为最多三次、按钮已存在即跳过的条件滚动，保留全部断言、未加
  sleep/retry、未改生产 UI（`f1eb57b`），同 SHA 重跑后 preview 4/4。
- 证据边界（审核报告要求）：真实 Hive 只验证 close/openBox 与内容保真；`box.get`
  内存读不构成真实后端故障下的 durable-readback/缓存回滚证明；本轮没有制造盘上
  unknown，不把可能数据丢失写成已复现。仍不接 `completeRevert`/启动 apply，不启用
  Native authority，四 flag 继续 false；P05 未整体完成。

## 6b. Codex 复审 R5/R6/C1 修复计划（2026-10-09）

依据 `build/native-migration/review-f4219f3/P05_REVIEW.md` 与
`restore-vault-followup.md`（R1–R4 已确认修复；新 R5 P1、R6 P2、C1 测试校准）。
以下触发均由源码/async 边界证明，本机未运行新负例，不写成已实测失败。
仍只修该有限 Vault 组件，不接 `completeRevert`/启动 apply、不启用 Native authority。

- **R5 owned 快照**：`NativeAccountReverseImport.decode(envelope)` 的返回值必须保留；
  create-only read 之后只 `jsonEncode(validated.value)`，不得再读 caller 可变对象。
  配受控 create-only read 暂停回归：暂停期间修改顶层（schemaVersion/nativeWritesAllowed）
  与嵌套（jar 字段/raw UTF16 list）；发布与真实 close/reopen 后内容必须等于调用前
  完整快照，并覆盖“在途 snapshot 不会被改成不可 load 数据”。
- **R6 域生命周期**：改为弱生命周期注册（Expando 对象域），明确 `coordinationDomain`
  必须是非 `String`/`num`/`bool`/`Record` 的稳定对象身份，primitive 明确拒绝；不得清空
  全局 map 或恢复每 Store 锁；保留同 Box 双 wrapper 共享 gate 与 shared recovery 回归。
  以对象域隔离、reopen 新域、primitive 拒绝做确定性命中，不写 GC 时序测试。
- **C1 oracle 冻结**：legacy 内容断言改为在 import 前保存不可变 JSON 快照，再与
  after 比较；对象 identity 断言单独保留，避免 in-place mutation 同时改变两侧。
- **补测**：已有 published 基线下，候选写完、指针发布前取消（受控 record-readback
  暂停）后基线字节不变；CAS 竞争对象改为完整可 load 候选（独立 vault 先发布，
  注入其 record+manifest），拒绝后 `loadRestore` 仍能加载该候选。strict parser 直接
  覆盖 depth/node/code-unit 预算与非法 escape；文档同步真实覆盖与“写入尝试 cleanup”
  政策（write-before 仅 best-effort 清理本轮预留的空 key，历史 ID 在预留前拒绝）。
- 分小 commit、组末同 SHA release5+preview4 实际日志/artifacts 全绿后交 Codex 复审。

## 7. 实施与验收记录（2026-10-09）

代码 SHA `38ee18eb20785ecc521535b3dc4fad24da3a6dd1`（计划 `9c2a244`、store
`c863083`、tests `5c0465a`、analyzer/JSON/CAS 修复 `ab578c3`/`aaed899`/`fd692b3`/
`b92057b`/`38ee18e`）：

- [release 37872430200](https://github.com/Justintunsday/Piliglass/actions/runs/37872430200)
  5/5 jobs、[preview 37872432577](https://github.com/Justintunsday/Piliglass/actions/runs/37872432577)
  4/4 jobs；九个强制 outcome 全 success、0 contract error；Runner `BUILD SUCCEEDED`、
  109.1MB、实际 FFmpeg 加载顺序通过。
- 账户 artifact：fatal-infos 分析无问题，真实 `+168: All tests passed!`（157 旧 + 11 新
  Vault 测试），tracker 72 不变。
- envelope artifact `status=passed`：108 oracle/43 负例/40 staging/35 transaction/
  51 authority，与上一验收组一致。
- 真实轮次发现并修复的缺陷（不是测试表面问题）：
  1. `UuidV4` 导入自错误 library、两处 analyzer 规则首轮未过（`fd692b3`）；
  2. manifest 读回失败被作为原始 vault 错误抛出而非 `publicationUnknown`；
  3. candidate 清理在事务 ID 冲突时可能删除仍被 manifest 引用的记录 —— 现在清理前
     必须先读 durable manifest，无法证明未引用则保留（`b92057b`）。
- 未交付/未接线：`completeRevert` 生产接入、启动时 apply 政策、跨重启的完整账户
  恢复、全部 reader/writer 屏障、CA4 运行时交接；安全 GC 继续暂缓，能力 flag 全 false。
