# P05 B2e-2b-3 bootstrap — focused R73 residual coverage plan (before edits)

2026-10-17（Asia/Hong_Kong）。依据
`build/native-migration/review-4a128580363bea7f8d04abe71f86f31332341e61-codex/REVIEW.md`
（SOURCE PREFLIGHT：R70–R72 source-positive 不重开；仅 R73 两个残余覆盖）。本计划只加
driver fault seam/回归行与静态 mock QA 绑定，不改生产序列化/cleanup/错误类型/owner fence，
不动预算、178 floor、两阶段 helper 与六哈希复核。

## 1. descriptor write commit-then-throw（per-phase before/after 收口）

- fault vault 增加 `descriptorWriteCommitThenThrow`：descriptor 写入先落字节再抛注入错误
  （与既有 record commit-then-throw 对称）；不改任何生产代码。
- 新隔离行（空 vault）：bootstrap 在 descriptor 阶段命中 → 断言
  - 清理验证成功后传播**原始注入错误**（非 verificationFailed）；
  - 完整恢复为空字典（无 pointer/journal/record/descriptor）；
  - 精确 **3 writes / 3 removes**；
  - 随后同一 vault 有效 bootstrap 成功（gate release，全 winner 字节）。
- 明示：record-after-commit 行不能替代 descriptor-after-commit 证据。

## 2. successful-NIL collision-read 取消行

- 两个独立空 vault fixture（与 present-result 行分开保留）：
  1. `record-nil-collision-cancel`：pause record read #1（成功返回 NIL），cancel+显式
     resume → 精确 `CancellationError`；全字典不变；零 write/remove；terminal-safe
     resume/await；随后有效 bootstrap 成功。
  2. `descriptor-nil-collision-cancel`：record read #1 已证明 absence，pause descriptor
     read #1（NIL），同样断言。
- 区分“证明缺席后被取消”与“拒绝结果被取消”，不新增 sleep/yield、不 catch-any、不降断言。

## 3. 静态 mock QA 绑定（如实：MOCK/source-only）

- bootstrap driver 源断言新增：descriptor commit-then-throw seam 存在；两个 NIL
  collision-cancel 行标签存在；保留全部既有断言。
- 运行可用 Python mock QA；计数可增加但保留 178 最低门；不预先声称实际 CI 计数。

## 保持

- R70–R72 已 source-positive，不重做；6b/318 不重开；生产文件零改动。
- 180/90/240 预算、strict Swift 6、两阶段独立 consumer + post-ALL 六哈希、现有断言与
  cancel 行全部保留。commit/push 新 code SHA 后 STOP BEFORE CI 交 Codex SOURCE PREFLIGHT。
