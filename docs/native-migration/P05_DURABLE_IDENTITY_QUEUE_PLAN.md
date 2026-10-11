# P05 Block 2 / B2e：durable identity 消费、receipt/unknown ack 语义与账号级排队边界

2026-10-12（Asia/Hong_Kong）。前置：B2d 已在 `9724ddb` 验收（release 38177658968 /
preview 38177662359；envelope 109/44/40/178/51）。本文件是实施前计划，不改动已验收
结论；四能力 flag 保持 false。按依赖，本组完成后进入 Block 3 生产交接。

## 1. durable identity 消费（shadow 起点）

- receipts 携带身份（additive）：`PiliAccountShadowTransactionReceipt` 增加
  `durableIdentity: PiliCookieUTF16?`（单记录事务：cookie save/delete/deleteAll、
  purpose、credentials、activated）；`PiliAccountShadowBuvidReceipt` 同样增加；
  `PiliAccountShadowImportReceipt` 增加 `identities: [PiliCookieUTF16]`（按输入顺序：
  被替换与新增记录的身份）。identity 是持久记录标签，不是授权身份。
- 只读消费 API（供 Block 3 composition 跨重启寻址，纯读）：
  - `func lookupRecord(durableIdentity:) async throws -> PiliAccountLiveMemoryRecord?`
    —— 从当前已发布 envelope 查找；不存在返回 nil；不 activate/reconcile/写。
  - 连同 `loadShadowSnapshot()` 的 transactionID，Block 3 可按 identity 在 handoff/revert
    前后核对同一记录。
- 测试：各事务 receipt 的身份与 envelope 中一致；replace/install/delete 重编号后身份
  稳定；lookup 命中/未命中；lookup 不改变指针与状态。

## 2. receipt / unknown ack 语义

- `publicationUnknown`（vault 写后读回未知）必须原样传播：不得伪造 receipt、不得重放。
  现有 `transaction()` 已 rethrow；本组补测：
  - `TransactionFaultVault.arm(.pointerReadAfter)` 下运行 `applyBuvidSeed` 与
    `applyImport`：得到 `PiliAccountEnvelopeStagingError.publicationUnknown`；重新以
    新 store 读回，durable 状态与指针一致（写后错误=已发布；写前错误=未发布）；
    buvid 的再次调用为 no-op（不重放）。
- 明确"unknown 不可当未写重放"：任何重试必须先 `loadShadowSnapshot` 读回并按 identity
  判断，语义写入计划与测试名。

## 3. 账号级排队（边界与最小保证）

- 现状：`PiliAccountEnvelopeTransactionStore` actor 的全局 `operationInProgress` fence
  + vault 的单发布 operation fence 已提供"同账号写入串行、无交错发布"；不同记录的真正
  并发需要 vault 支持多记录并行发布，属于 Block 3 composition 的范围。
- 本组不重写并发模型，交付：
  - 同一 key 上的并发事务测试：一个先行、另一个观察到其后状态（无丢失更新）；全局
    fence 下第二个在先行 publish 期间得到 `operationInProgress` 或按新快照成功，二者
    都必须保持 envelope 一致（测试断言最终状态与无交错发布）。
  - 计划/状态矩阵明确：账号级排队的精细实现与 receipt/unknown ack 的顶层语义随
    Block 3 的 composition 提供；当前保证是"单发布者、CAS、无重放"。

## 4. 测试与验收

- driver 新增：receipt 身份（cookie/purpose/credentials/activated/buvid/import）、
  lookup 命中与未命中、unknown ack（seed/import）、同 key 并发一致性；既有 checks
  （envelope 109/44、staging 40、transaction 178、authority 51）只增不减。
- 小 commit + push；同 SHA dispatch `ios.yml` + `ios-home-preview.yml`，读实际
  artifacts（账户计数、envelope、九 outcome、BUILD SUCCEEDED/109.1MB/FFmpeg、
  preview 20 tests）。失败读日志修复→新 SHA 重跑两条。
- 通过后更新 PROGRESS/STATUS_MATRIX/本计划，并进入 Block 3。
- 边界：只做 shadow；不接 authority、不产生生产 caller；不改 Dart authority；四 flag
  false；不碰 UI/Aether/`youtube/`。
