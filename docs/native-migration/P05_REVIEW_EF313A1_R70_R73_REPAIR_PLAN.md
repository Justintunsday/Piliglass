# P05 B2e-2b-3 first-publication — focused R70–R73 repair plan (before edits)

2026-10-17（Asia/Hong_Kong）。依据
`build/native-migration/review-ef313a118818ae1b5cc489d42c8e229f157d6c63-codex/REVIEW.md`
（SOURCE PREFLIGHT CHANGES_REQUESTED R70–R73；无 CI 授权）。本计划在编辑前保存，只修
bootstrap staging 排序与既有 bootstrap driver/QA，不重开已验收 6b/318，不改生产 manifest
wire、cleanup、owner fence 或预算。

## R70 —— driver 独立 manifest 字节 oracle + happy remove 计数

- 根因（源码核对）：staging 用 `JSONEncoder(.sortedKeys)` 编码 Codable `Manifest`，`UUID`
  Codable 输出**大写** `uuidString`；driver 的 `manifestBytes` 小写拼接，hex-letters UUID
  下字节必然不等。clean bootstrap 的验证提交会执行一次 journal remove（`removeAttempts`
  计 1），driver 却断言 0。
- 修法（仅 driver）：
  1. 新增 driver-local `FixtureManifest: Codable { schemaVersion: Int, transactionID: UUID,
     byteCount: Int, sha256: String }`，用与 staging 相同的 `JSONEncoder + .sortedKeys`
     编码（不改生产序列化/wire）。
  2. 固定含 hex letters 的测试 ID（如 `0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d`、
     `deadbeef-…`），happy/unknown/contention/recovered 行使用它们，使大小写差异可判别。
  3. 保留 record/descriptor/pointer 全字节相等断言；clean happy 与 recovered ack 两分支
     都断言 `writeAttempts == 4 && removeAttempts == 1`。

## R71 —— fresh/initialized owner fence 两个独立用例

- 根因（源码核对）：adoption 先 `loadRecoveryOnce`（识别 `.bootstrap` 并 arm `unresolved`）
  再 `beginOperation` → `requireResolvedPublication` 抛
  `PiliAccountShadowTransactionError.unresolvedPublication`，根本到不了 staging；旧行只
  catch staging `unresolvedRecovery`，是必然失败路径。
- 修法（driver 两个独立行，禁 catch-any）：
  1. **cold owner**：安装有效 bootstrap journal → 新 TransactionStore
     `adoptMissingIdentities()` → 精确 `unresolvedPublication`；pending 字段（ID/kind/预期
     前一 pointer/digest）与 journal 一致；全持久字节不变；零 write/remove 尝试；journal
     不被自动清除。
  2. **initialized owner + 真实 staging unknown**：先 `loadPersistentRecovery()` 得到 clean
     初始化；再经真实 staging bootstrap 路径产生 unknown（pointer commit-then-throw + ack
     不可读 → pointer 已提交、journal 保留）；owner 后续真实写入
     （`adoptMissingIdentities`）→ staging 精确 `unresolvedRecovery` + 真实 arm 出 pending
     `.bootstrap`；全字节不变、零**新增** write/remove、journal 原样。

## R72 —— bootstrap-only post-await 取消排序

- 根因：`.absent` 在 journal/manifest/collision 三个 await 成功后**先解释结果**再检查取消，
  取消被 resumed 的“有效但拒绝性”结果掩盖（nil-only 行侥幸通过）。
- 修法（仅 `.absent`，raw/correlated 行为与错误优先级不变）：
  1. journal do/catch 之后、`guard journal == nil` 之前 `try Task.checkCancellation()`。
  2. `let previous = try await manifest()` 之后、expectation 解释之前（absent 分支）。
  3. collision 读取：先捕获 `existingRecord` → checkCancellation → 捕获
     `existingDescriptor` → checkCancellation → 之后才判 `bootstrapRefused`；随后增加
     **pre-journal checkpoint**（collision 之后、journal 写入之前）。
  4. 不动 verified-commit 之后（禁止追溯取消）；IO 抛错仍按原类型传播，不重分类为取消。
- driver 判别回归（显式 resume + 终态清理 + gate release + 后续有效操作）：
  journal-present、pointer-present、record-present、descriptor-present 取消各自断言精确
  `CancellationError`（不是 `unresolvedRecovery`/`bootstrapRefused`）、全字节、零 write/remove；
  结束后恢复 fixture 并执行有效 bootstrap/correlated（label 明示 out-of-band changed-byte
  fixture 非合法并发 writer）。

## R73 —— 缺口 fault matrix / winner oracle / negative

- driver/fault-vault 补：record write **commit-then-throw** 行；descriptor read IO-throw 行
  （`failDescriptorReadAt(2)`）；descriptor-mismatch 行补精确计数；descriptor read-back
  checkpoint 取消（finally pre-pointer，cleanup 复位全字节）；verified-commit
  **no-retroactive-cancel**（pause pointer ack read #2，cancel+resume → nextBytes → receipt）。
  新增 bounded pause 钩子：pointer/record/descriptor read ordinal pause + resume，全部并入
  terminal 报告与显式 resume 路径。
- 强化合法同 vault contention：contention 期间全字典（journal 未写、无 record/descriptor/
  pointer）与零 write/remove；完成后全 winner 字典（pointer/descriptor/record 全字节）+
  精确 `4 writes/1 remove`。
- 真实 publicationUnknown：新 owner 精确 `unresolvedPublication`、staging bootstrap/export
  精确 `unresolvedRecovery`、journal/record/descriptor 字节不变、零新增 write/remove、
  不自动 resolve/clear/replay。
- association：新增 **generation mismatch** typed-negative；non-canonical 用例改为固定
  canonical UUID 大写变换（确定性无效大小写）；全部负例用 driver-local 精确 reason 匹配
  （`BootstrapFixtureError.failed(reason)`），不再 catch-any。

## 保持与不变量

- STAGING/AUTHORITY 闭包、180/90/240 预算、strict Swift 6、两阶段独立 consumer + post-ALL
  six-hash、goldens/HEAD/source 证明、178 minimum floor（计数只增）不变；mock 计数≠实际。
- raw ANY + correlated UUID 行为、accepted journal/ack/cleanup helpers、owner fence 语义、
  单 shared-vault fence、无 authority/composition/device 主张。
- 本地只跑真实 Python mock QA（如实标注 mock）；commit/push 新 code SHA 后 STOP BEFORE CI
  交 Codex SOURCE PREFLIGHT。
