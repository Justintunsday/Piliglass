# P05 Block 2 / B2d：buvid 补值 durable transaction（shadow）

2026-10-12（Asia/Hong_Kong）。前置：复审修复组已在 `53aed63` 验收（release
38150244501 / preview 38150247302；账户 +250；envelope 109/44/40/157/51）。本文件是
实施前计划。本组只做 shadow 组件：不接 authority、不产生生产 caller、不做账号级队列；
四能力 flag 保持 false。

## Dart 语义对照（`BiliCookieJar.setBuvid3`）

- 位置：`domainCookies['bilibili.com']['/']['buvid3'] ??= Cookie('buvid3', value)`
  （`setBiliDomain`：domain `.bilibili.com`、path `/`、httpOnly=false）。
- 仅缺失时补值；已存在时不改动（幂等）。
- 值由 `IdUtils.genBuvid3()` 生成（UUIDv4 大写 + 5 位随机 + `infoc`，ASCII），由调用方
  提供；shadow 不生成凭据值。
- 构造器补值（每个新 jar）与匿名 reset 的 buvid 补值都属于该语义；本切片提供事务。

## 契约（`applyBuvidSeed`）

输入：`recordKeyUnits`、`expectedGeneration`、`valueUnits`（ASCII 值）、
`nowMicroseconds`。

- 仅 schema 3；仅 login record；key 未知 → `unknownRecordKey`；generation 不匹配 →
  `staleGeneration`。
- **支持值域**：可打印 ASCII（0x21…0x7E）且不含 `;`，长度 ≤
  `PiliAccountEnvelopeTransactionStore.buvidMaximumValueUnits`
  （= standard `maximumValueUnits` 65536 − 64 头部余量 = 65472）。逗号/反斜杠/内引号
  属于 parser 进一步拒绝的子集，不在本 API 的承诺值域内。
- **错误分类**：空值/非 ASCII/含 `;` → `invalidBuvid`；超过 API 长度上限 →
  `PiliAccountLiveMemoryShadowError.resourceLimit`（在构造 field 之前主动校验）；
  有效普通值导致最终 candidate 超过共享累计/编码字节预算 → 同样 `resourceLimit`
  （codec ledger）；reducer/parser 的 65536 字段上限仍由既有 reducer/raw-field 套件
  覆盖，本 API 不再依赖 parser 报错。
- 存在性按 jar 的 map key 判断（domain 桶 `bilibili.com`、path `/`、entry key
  `buvid3`），与 Dart `??=` 的 map key 语义一致。
- 缺失：用共享 `PiliNativeOrderedCookieReducer.save` 以
  `buvid3=<value>; Domain=.bilibili.com; Path=/`、location `bilibili.com`/`/` 追加
  （新 cookie 追加在 path 末尾，保持 Dart map 插入顺序），替换该记录 jar，整包
  `validated(limits:)` 后 CAS 发布；receipt `seeded=true`、两门恒 false。
- 已存在：**no-op**（`seeded=false`、`transactionID=nil`、不发布、指针身份不变）。
- 拒绝路径零发布（transactionID/envelope 逐字节不变）；`beginOperation` 重入拒绝。
- 除目标记录 jar 外不改任何字段（identity/orders/selections/history/revision 不变）。

## 测试矩阵（driver，计数只增不减）

1. 缺失补值：seeded=true、指针推进、buvid3 值正确、仅新增一个 cookie、其余记录与
   orders/selections/history/revision/identity 不变；真实 Keychain close/reopen 后保留。
2. 幂等：二次补值 seeded=false、transactionID=nil、指针不变。
3. 拒绝：unknown key、stale generation、空值、非 ASCII、含 `;`、超长值（`resourceLimit`）、
   schema 2（`invalidBuvid`）、paused 重入（`operationInProgress`）；全部零发布。
4. 保留既有 checks（envelope 109/44、staging 40、transaction 157、authority 51），
   只增不减。

## 验收与边界

- 小 commit + push；同 SHA 显式 dispatch `ios.yml` + `ios-home-preview.yml`；读实际
  artifacts（账户计数、envelope 109/44/40/N/51、九强制 outcome、BUILD
  SUCCEEDED/109.1MB/FFmpeg、preview 20 tests）。失败读日志修复→新 SHA 重跑两条。
- 通过后更新 PROGRESS/STATUS_MATRIX/本计划并交交付报告。
- 后续（不在本组）：durable identity 消费/恢复语义、账号级队列与 receipt/unknown ack、
  Block 3/4/5。四 flag false。

**已实现（2026-10-12）；同 SHA CI 通过；独立审核 CHANGES_REQUESTED（R12 等），退修见
[P05_REVIEW_53AED63_R12_REPAIR_PLAN.md](P05_REVIEW_53AED63_R12_REPAIR_PLAN.md)**：计划
`6cfdb1e`、实现 `82e3ffe`、driver `399760b`、超长值用例修复 `d732ec0`/`9724ddb`；同 SHA
[release 38177658968](https://github.com/Justintunsday/Piliglass/actions/runs/38177658968)
5/5、[preview 38177662359](https://github.com/Justintunsday/Piliglass/actions/runs/38177662359)
4/4；envelope `status=passed` 109/44/40/**178**/51、sourceSHA=9724ddb；账户 +250
（无 Dart 变更）、九 outcome success、BUILD SUCCEEDED/109.1MB/FFmpeg、preview 20
tests/`failures=[]`。**注意**：9724ddb 的 70k 用例证明的是 parser 上限拒绝
（`PiliNativeCookieError.invalidField`），不构成共享 ledger 预算验证；R12 退修新增
API 主动长度校验、边界值、真实预算回归、非空 jar 顺序、map-key≠Cookie.name 与
expired no-op 覆盖。此组与 53aed63 修复组均**未获独立审核 PASS**。
