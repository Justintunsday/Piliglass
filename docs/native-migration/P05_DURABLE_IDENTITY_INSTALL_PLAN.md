# P05 Block 2 / B2b：durable record identity 起点 + install durable transaction（shadow）

2026-10-11（Asia/Hong_Kong）。前置：B1d 已在 `98e6f9b` 验收（release 38132428469 /
preview 38132430663，账户 +239）；B2a `applyPurposeChange` 已在 `de2223a` 验收
（transaction 58）。本文件是实施前计划，不改动已验收结论。本组只做 shadow 组件：
不接 authority、不产生生产 caller、不做 import/delete/buvid durable transaction、不做
账号级队列；四能力 flag 保持 false。

## 分片与顺序

1. **B2b-1 durable record identity 起点**：记录级稳定 ID 的格式/校验/升级路径。
2. **B2b-2 install durable transaction**：原子 append 一个完整 login record（含新
   identity）。依赖 B2b-1 的字段与校验。

## B2b-1：durable record identity

- 存储位置/格式：形如 `PiliAccountLiveMemoryRecord.durableIdentity` 的可选字段，
  持久化在 shadow envelope 的 record 内（Keychain vault 的已发布候选）。格式为
  canonical lowercase UUID（36 UTF-16 units，8-4-4-4-12）；未赋值 = legacy record。
- 生命周期：仅由显式事务铸发一次并持久化；对既有记录永不重新生成；不来自 MID、
  raw storageKey、runtime generation/epoch/ownerToken，也不作为授权身份。codec 严格
  接受缺失（legacy 可读）但拒绝 malformed/重复；匿名 record 必须为 nil。
- 升级路径：新增 `adoptMissingIdentities` 事务，为所有缺少 identity 的 login record
  铸发唯一 UUID 并单次 CAS 发布；无可升级记录时返回 adopted=0 且**不发布**（指针身份
  不变）；重复调用幂等。
- 预算：identity 固定 36 units，先格式校验再计入共享累计 ledger。
- 编码兼容：字段缺失时 encode 省略（不写 null），保证 legacy envelope 的既有
  解码/重编码与 108 项比较不受影响。

## B2b-2：install durable transaction

- 输入结构（新）：`PiliAccountShadowInstall`：storageKeyUnits、mid、generation、
  accessKeyUnits?、refreshTokenUnits?、persistedPurposes、activated、jar。
- 语义：在 envelope 末尾原子追加 record（`record == records.count`），同步追加
  `storedOrder`/`ownerOrder` 条目（keyUnits 与 record 匹配），selections/history 不变，
  匿名与既有记录逐字段不变，revision 不重编号；record 携带新铸发的 identity。
- 验证：key 非空且未出现（重复 → 新错误 `duplicateRecordKey`）、shape/重复 purpose
  → `invalidInstall`、generation 非正或已用 → `staleGeneration`、records 上限与共享
  累计 ledger（越界 → `resourceLimit`）、CAS（`expectedTransactionID`）、
  `beginOperation` 重入拒绝；receipt 的 `nativeWritesAllowed`/`authoritySwitchAllowed`
  恒 false。
- 失败/拒绝零发布：transactionID/envelope 与调用前逐字节相同。

## 文件边界

- `ios/Runner/Native/Domain/Accounts/PiliAccountLiveMemoryShadow.swift`：record 字段、
  encode、`validateContents` 的 identity/预算/匿名检查。
- `ios/Runner/Native/Data/Accounts/PiliAccountLiveMemoryShadowCodec.swift`：recordKeys
  增加字段；严格可选 string 解码。
- `ios/Runner/Native/Persistence/Accounts/PiliAccountEnvelopeTransactionStore.swift`：
  `adoptMissingIdentities`、`applyInstall`、identity 铸发与唯一性校验。
- `tool/check_native_account_envelope_transaction.swift`：分片测试；保留既有全部检查。
- 不改 Dart 生产/测试；不新增 Swift 依赖；不触碰 `youtube/`。

## 测试矩阵（driver，计数只增不减）

B2b-1：
1. legacy golden 全部 login record identity 为 nil（旧记录可读）。
2. adopt：所有 login record 获得 canonical 唯一 identity；匿名仍 nil；receipt gates
   false；真实 Keychain close/reopen 后 identity 不变。
3. adopt 幂等：第二次 adopted=0 且发布指针不变。
4. 既有 cookie/purpose 事务后 identity 不变（跨 shadow 替换稳定）。
5. malformed（长度/字符/大写）、重复 identity、匿名携带 identity → 显式失败；
   带未知 identity 变体字段 → 严格失败；零发布。

B2b-2：
6. install 成功：record==3 连续、storedOrder/ownerOrder 正确、selections/history/
   匿名/既有记录不变、jar 相等、identity canonical 且唯一、receipt record=3、
   gates false；close/reopen 后 identity/记录不变。
7. 重复 key（`duplicateRecordKey`）、重复/非法 generation（`staleGeneration`）、空 key
   与重复 purpose（`invalidInstall`）、超预算 credentials（`resourceLimit`）全部拒绝
   且零发布。
8. install 与 CAS：发布指针身份每次推进；staging 级 stale CAS 拒绝沿用既有用例；
   paused vault 下重入 → `operationInProgress`。
9. 保留既有全部 transaction checks（当前 58）与 envelope/staging/authority 计数。

## 验收与停止边界

- 小 commit + push；组末同 SHA 显式 dispatch `ios.yml` + `ios-home-preview.yml`；读实际
  artifacts：账户测试实际计数、envelope 108/43/40/58/51（只增不减）、九强制 outcome、
  BUILD SUCCEEDED/109.1MB/FFmpeg、preview 20 tests。失败读日志修复→提交推送→重跑；
  preview 慢 runner 阶段超时先区分代码回归与 runner 超时，不放宽断言、不跳过阶段。
- 通过后更新 PROGRESS/STATUS_MATRIX/本计划并交交付报告。
- 本组不接 authority、不产生生产 caller、不做 import/delete/buvid durable transaction、
  不做账号级队列、不产生 durable identity 消费方；不改 Dart authority。
