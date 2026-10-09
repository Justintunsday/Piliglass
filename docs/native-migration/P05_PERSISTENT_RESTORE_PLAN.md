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
