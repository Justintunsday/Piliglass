# P05 修复计划：0303747 R54 driver 收据标注类型错误（依据 review-0303747…-codex）

2026-10-16（Asia/Hong_Kong）。依据
`build/native-migration/review-0303747b2e8daa7a47832d2257288bfdb03e16bc-codex/REVIEW.md`
TOP TERMINAL DISPOSITION/R54 与 actual inner transaction-compile.log。**本计划在修复 edit
之前保存**；isolated 类型标注修正，无生产改动。

## 实际证据（保留；不回退/不弱化）

- 030 release [38904450413](https://github.com/Justintunsday/Piliglass/actions/runs/38904450413)
  FAILURE（main failure + 4 success）；preview
  [38904460681](https://github.com/Justintunsday/Piliglass/actions/runs/38904460681)
  SUCCESS4/4（均首次尝试）。actual strict analyze No issues/runtime72/account322 All passed；
  八个 outcome SUCCESS + ACCOUNT_ENVELOPE_OUTCOME FAIL（正确 exit1）；BUILD SUCCEEDED/
  109.1MB/executed FFmpeg；20 UI（nav293.296+image105.447+account269.051+player41.216s）/
  11 owned reports/22 streams/pressure[]/MacQA45；91 raw 89+2/current goldens。
- actual Swift6 `-strict-concurrency=complete` 编译错误 794：`cannot assign
  PiliAccountShadowTransactionReceipt to PiliAccountEnvelopeStagingReceipt`。5d 的三个
  in-scope 错误已消失，但编译仍失败；新 Native C1/C4/cancel/merge/R53 回归**未执行**，
  245/292/51 不得借用；R53 runtime 未验证。

## 根因与修正（isolated）

- 两个收据契约不同：staging `PiliAccountEnvelopeStagingReceipt`（StagingStore:9-13，仅
  transactionID/recoveredWriteAcknowledgment）；transaction
  `PiliAccountShadowTransactionReceipt`（TransactionStore:125-132，transactionID/record/
  durableIdentity/nativeWritesAllowed/authoritySwitchAllowed）。`applyPurposeChange`
  （:686+）与 `applyTemporarySelection`（:657+）实际返回 transaction 收据；两者只共享
  transactionID，不可互赋。
- driver:782 的 R52 hoist 标注误写为 staging 收据；修正为
  `var winnerReceipt: PiliAccountShadowTransactionReceipt?`（与真实 API 返回一致）。
  不做 cast、不伪造 staging 收据、不用默认值；保留 guard 绑定/verified B receipt/独立
  expected winner/全部断言与错误清理。
- 收据 producer/consumer 复核（全部新绑定）：`winnerReceiptValue`（推断）/`mergeReceipt`
  （推断）/`tempWinnerReceipt`（推断）及各 Task 类型均来自真实 API（ShadowTransactionReceipt），
  全文件仅 782 一处显式标注，修正后一致；cancel/merge 仅消费 `transactionID`（两契约皆有的
  字段）与 winner envelope。

## 保留与边界

- 不改生产 seam/CAS/vault；不重跑 030；不自我验收；新最终 code SHA → BOTH workflows 各一次
  + Codex 独立复审；预算不变（180/90）；历史失败（5d 词法、030 类型）与证据边界保留；
  四 flag false；eb58 Dart7 limitedPASS/830 plan-only 不复重开。

## 结果（2026-10-16）

- `3818948`：标注修正后实际 Swift6 strict 编译通过（六个 inner compile/result 日志由 Codex
  亲读），C1/C4/cancel/merge/R53 五 helper 实际执行；双 CI 首尝试 5/5 + 4/4；**LIMITED
  PASS**（`review-3818948…-codex`），仅该组范围；`030` 类型失败历史保留。
