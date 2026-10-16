# P05 修复计划：5d3bf43 R52 driver 词法/DI 缺陷 + R53 watcher 全终态通知（依据 review-5d3bf43…-codex）

2026-10-16（Asia/Hong_Kong）。依据
`build/native-migration/review-5d3bf43fdb3a19033c9b849d357ecfd68da8d7a3-codex/REVIEW.md`
TOP TERMINAL DISPOSITION + R52/R53 与 actual inner transaction-compile.log。**本计划在修复
edits 之前保存**；只修 driver/test 工具缺陷，不需要生产 seam 变更。

## 实际证据（保留，不回退/不弱化）

- 5d release [38899503762](https://github.com/Justintunsday/Piliglass/actions/runs/38899503762)
  FAILURE（4 success + main failure）；preview
  [38899513896](https://github.com/Justintunsday/Piliglass/actions/runs/38899513896)
  SUCCESS4/4（均首次尝试）。actual account 322/runtime72/strict clean；八个 outcome SUCCESS +
  ACCOUNT_ENVELOPE_OUTCOME FAIL → aggregate exit1；BUILD 109.1MB/executed FFmpeg；20 UI/
  11 owned reports/22 streams/pressure[]/MacQA45；91 raw 89+2/current goldens。
- actual Swift6 `-strict-concurrency=complete` 编译错误：C1 inner `do` 内的 `winnerReceipt`
  与独立期望 `expectedWinner`（816/817/839）在 cancel/merge 引用时**不在词法作用域** → 新
  Native C1/C4/cancel/merge 未执行；245/292/51 为前代计数，不得冒充本 SHA 结果。
- R53 为源码推导（非观测挂起）：3 个 watcher 仅在 catch 通知，任务**早成功**会让
  `waitUntilPaused` 永久挂起。

## R52 修复（词法/DI 携带；无 force unwrap、无假 receipt、不删断言）

- C1 阶段在 inner `do` 之前声明 `var winnerReceipt: PiliAccountEnvelopeStagingReceipt?` 与
  `var expectedWinner: PiliAccountLiveMemoryShadow?`；inner `do` 内用本地
  `winnerReceiptValue`/`expectedWinnerValue` 赋值并完成 do 内全部断言；do/catch 之后
  `guard let confirmedWinnerReceipt = winnerReceipt, let confirmedWinner = expectedWinner
  else { throw TransactionFixtureError.failed("C1 race produced no verified winner") }`，
  cancel/merge 使用 confirmed 绑定。禁止 force unwrap、默认/伪造 receipt、把 winner 读回当
  oracle。

## R53 修复（共享 helper；全部终态都必须通知）

- 新增共享 `completionWatcher(pauser:task:)`（`Task<Success, any Error>`）：**成功**也通知
  `completedBeforePause("transaction succeeded before the pause")`；失败通知
  `String(describing: error)`。race/cancel/temp 三处 watcher 全部改用它。
- 早成功（未触达 hook 而任务已完成）必须使 `waitUntilPaused` 返回 `.completedBeforePause`
  → 用例 throw（失败退出），绝不永久等待；正常 pause/resume 后（`reached == true`）通知为
  no-op，不改变既有语义。无 sleep/`Task.yield`。

## 新增直接回归（pauser/helper 语义；真实 store 任务 + 确定性 gate）

1. 早成功、complete-before-register：await 任务/watcher 后再 `waitUntilPaused` →
   `.completedBeforePause` 且消息含 "succeeded"，真实发布落地；
2. 早失败、complete-before-register：unknown key → 消息含 `unknownRecordKey`；
3. 早失败、reg-before-complete（`CompletionGate` + `waitForObserverRegistration()`）→
   观察者先注册后通知 → 精确错误消息；
4. 早成功、reg-before-complete：同上 → 消息含 "succeeded"；
5. 正常 pause/resume：hook 触发 `.paused` → `resume()`（含幂等二次 resume）→ 任务成功
   发布；resume 后 pauser 保持 `.paused` 状态。
- 清理：gate 总在可能抛出的检查之前打开；所有 task/watcher 被 await；回归命名空间最后
  discard；预算不变（180/90），无 sleep/Task.yield。

## 保留与边界

- 不改生产 seam/CAS/vault 语义；保留同 vault 实际 Keychain C1/C4/cancel/merge/reopen、
  winner 完整状态、零 durable 写、无新 unknown fence、显式 resume、previous/temporary
  语义与全部既有 checks。
- 新最终 code SHA → BOTH workflows 各一次 + Codex 独立复审；不重跑 5d；不自我验收/不升级
  authority；四 flag false；历史失败与证据边界保留；若出现真实编译预算问题则按矩阵保留
  拆分诊断，不扩大 180/90。
