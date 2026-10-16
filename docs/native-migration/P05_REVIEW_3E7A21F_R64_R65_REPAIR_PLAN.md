# P05 聚焦修复计划（R64/R65）：3e7a21f driver changed-manifest 孤儿指针清理 + mock QA 确定性时钟

2026-10-17（Asia/Hong_Kong）。依据
`build/native-migration/review-3e7a21ff2034df429ac5fb1f408960767c66fd5f-codex/REVIEW.md`
R64/R65（SOURCE PREFLIGHT CHANGES_REQUESTED）。R62 生产修复（capture→检查→解释）与 R63
覆盖被确认为 source-positive；本修复**不改生产语义**、不重开 318、不重做 R62，只修
driver 测试 fixture 与本地 mock QA。本计划在**任何编辑前**保存。

## R64 — changed-manifest-cancel 行的孤儿指针确定性缺陷（driver 测试修复）

现状缺陷（源码可判定）：`remintedManifest` 只把 manifest 的 transactionID 换成新 UUID，
没有为新 UUID 写 record；该行随后在**恢复原 manifest 之前**执行
`staging.loadShadowSnapshot()` → `readRecord` 找不到新 UUID 的 record → 未捕获
`missingRecord` 直接中止 driver（Keychain 产物/最终计数不再执行）。

最小修复（保持 cancel-vs-staleExport 判别与显式 resume 路径）：

1. 行开始时捕获原 fixture 全字节：`originalSnapshot = storedSnapshot()`、
   `manifestBefore`、`recordBefore`。
2. 在任务启动**之前**计算独立期望的变异态：
   `expectedMutated = originalSnapshot; expectedMutated[manifestKey] = moved`
   （`moved = remintedManifest(manifestBefore)`；静态 QA 断言其仅改 transactionID、
   不改 byteCount/sha256）。
3. between 仅安装 `moved`；取消+显式 resume 后断言：
   - 精确 `CancellationError`（非 `staleExport`）（保留）；
   - zero attempted writes/removes（保留）；
   - **全字节** `storedSnapshot() == expectedMutated`（替代 `observed != nil`）；
4. 在**任何有效 cleanup 读/导出之前**恢复原完整 fixture（`manifestKey = manifestBefore`），
   然后：
   - cleanup `exportCurrentShadow` 成功且返回**原始** record 字节与 digest
     （pointer/bytes/digest 全断言 = gate 再进入）；
   - `storedSnapshot() == originalSnapshot`（全字节还原）。
5. 不吞掉任何 `missingRecord`/意外错误，不删除 cleanup 断言。
6. 静态 fixture-一致性 QA（本地）：断言 `remintedManifest` 函数体只设置 `transactionID`；
   行内含期望变异/还原标签（source-presence，非运行时证据）。

## R65 — mock QA 时钟不确定 + 失败原因过早（本地 mock QA 修复）

现状：`write_goldens` 用宿主 `time.time_ns()//1000` 发明 `started+10µs`，与真实 `main()`
的 `producer_started/finished`（宿主时钟）不一致；粗粒度/快时钟/时钟调整可令
`finished > producer_finished` → happy main 断言失败（Codex 两次实跑 14/15）；stale 失败
可能因**更早**的原因通过，未证明命中预期 stale-export 分支。

最小修复（test-only）：

1. 新增确定性 `ProducerClock`（微秒步进；每次调用递增），在 `run_main` 中以
   `module.time` 注入并在 `finally` 还原（生产校验 `fixture()` **不改**；无 sleep/无预算变化）。
2. `FakePipeline.write_goldens` 的 started/finished 一律取该时钟 → 观察时间戳必然落在
   `producer_started < started ≤ finished < producer_finished` 内。
3. happy main：以**两个不同时钟基准**各跑一次，均须 passed/exit 0，并断言 cross-runtime
   导出 driver 命令实际执行（phase 到达）。
4. failure main（main_stale_export）：断言
   - exit 1 / status failed；
   - `reason` == 精确 stale-export 分支文本（"Cross-runtime export metadata is absent,
     stale or mismatched"）；
   - 导出 driver 命令与 producer golden 命令均已执行（早失败不能冒充目标负例）。
5. 保留全部 15 个场景与 main passed/failed 断言；本地重复实跑（多基准、≥2 次）。
6. QA 输出注明：mock 打印的 "126 …" 是 **MOCK** 子进程输出，**不是** Swift 计数；本地
   mock 非 Mac/Swift/Dart 证据。

## 预算/边界

- 不改生产 Swift/Python 阶段/consumer/workflow/断言/预算/aggregate；MINIMUM_EXPORT_CHECKS
  按新真实计数设置（只增不减）；四 flag false；318 与既有失败历史不动。
- 新 code SHA 后 **STOP BEFORE CI** 交 Codex SOURCE PREFLIGHT；实际 Swift/Dart/CI 证据仍
  以 source-positive 后的 dual CI 为准。

## 实施注记（2026-10-17）

- 已按本计划实现（同批 code SHA）：changed-manifest-cancel 行改为孤儿指针的**独立期望全字节
  oracle**（原始 vault 快照 + 仅 manifest 置换；取消+显式 resume 后断言未受任何导出写入
  变异），并在任何有效 cleanup 读/导出**之前**恢复原完整 fixture，断言 cleanup 导出返回
  原始 record 字节与 digest、且全字节还原（`storedSnapshot == originalSnapshot`）；不吞掉
  意外错误、不删除断言、保留 cancel-vs-staleExport 判别。driver 计数 126+2=128
  （MINIMUM_EXPORT_CHECKS 110→120，只增不减）。
- mock QA：注入确定性 `ProducerClock`（`module.time`，finally 还原；无 sleep、无预算变化），
  `write_goldens` 采用受控时钟 → happy main 以两个不同时钟基准（0 与 1.7e15）各跑一次并
  断言 cross-runtime 导出阶段确实到达；failure main 断言**精确** stale-export reason
  （`Cross-runtime export metadata is absent, stale or mismatched`）且 producer 与导出
  阶段均已执行（早失败不能冒充目标负例）；新增 driver fixture 静态一致性 QA
  （`remintedManifest` 仅改 transactionID）。本地实跑 3 次均为 16/16。
- 本地 mock 非 Mac/Swift/Dart 证据；测试输出中的 "126 native …" 为 MOCK 子进程输出。
  未派发 CI：等待 Codex SOURCE PREFLIGHT；实际 Swift/Dart/CI 证据以 source-positive 后的
  dual CI 为准。
