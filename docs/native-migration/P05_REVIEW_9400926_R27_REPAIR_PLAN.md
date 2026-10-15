# P05 退修计划：9400926 复审 R27（冷恢复争用 fixture 使用独立 vault fence）

2026-10-15（Asia/Hong_Kong）。Codex 对 `94009269bf2e2c122388630b53c70831d7290545`
独立复审 CHANGES_REQUESTED：R27（P1 validation blocker）。依据：
`build/native-migration/review-94009269bf2e2c122388630b53c70831d7290545-codex/REVIEW.md`。
R23–R25 与 R26 修复被认定为实质正面/暂定正面，本轮不重做；只修 R27 fixture 与
"未证实的覆盖声明"。边界不变：shadow-only、四 flag false、不接 authority、不真实
账户/设备、不碰 `youtube/`、不改 UI、不降 264/245/148 基线、180/90 预算、断言/门禁；
不引入 actor-per-writer 生产组合、不预热冷 store、不放大预算。

## R27 精确现状（源码级，Codex 已证）

- `checkColdRecoveryContention` 中：
  - 约 994–1001 行：被暂停的 raw publisher 运行在 `vault4`，而冷 transaction store
    建在**另一个** `reopenedVault4` actor 上，然后等待 `reopened4.retrySleepCount >= 1`。
  - 约 1054–1063 行：corrupt 分支同样在 `vault5` 被暂停时用**新** vault 建冷 store。
- `PiliAccountEnvelopeStagingStore.operationInProgress` 是 **实例属性**（约 127 行）；
  `loadRecoveryJournal` 调该实例的 `beginOperation`（约 271–275 行）。契约本身要求同
  namespace 的活跃 composer 共用**一个** vault actor（约 146 行）。
- `QueueFaultVault.write` 在 continuation 上挂起时释放 actor executor，且其 `read`
  在别人 write 挂起期间**照常返回**。因此新 vault 的 fence 是空的：冷 preflight
  的 journal 读立即成功 → pending 立即抛 `.unresolvedPublication`、corrupt 立即抛
  `.invalidRecoveryJournal`，**都不会**抛 `operationInProgress`、不产生重试事件 →
  `waitForRetrySleep` 400 次轮询后确定性失败。这是 fixture 错误，不是 runner flake，
  不能靠更长 sleep/预算掩盖。
- 另外 catch 清理在未 resume/settle 被暂停任务的情况下对仍忙的 vault 调
  `discardShadow`，无法建立干净的终态。
- 未证实项（须精确化、不得夸大）：并发首次使用 fixture 只等待**聚合**一次重试，未证明
  **两个**冷提交都到达 preflight；两个效果用不同 key，不能独立证明冷态同 key 串行；
  "同一数值配置 = 一份共享 attempt 预算"的说法不成立（冷加载重试与发布重试各自从
  头计数），不得声称端到端统一预算。

## 修复（测试/fixture 面；生产修复 dbb6a87 保持不动）

1. **共享 vault actor 的真实争用**（R27 核心）：
   - pending 分支：被暂停的 raw publisher 与冷 transaction store **共用 `vault4`**
     （同一 actor，符合契约）；冷 store 在 preflight 阶段真实遭遇
     `operationInProgress` → 显式 retry barrier；resume+settle 后同一 store 读回
     pending journal → arm fence → `.unresolvedPublication`（typed）、journal 保留、
     默认 `.ambiguousRecovery`、显式 `allowAmbiguous:true` 清除、follower 精确一次。
   - corrupt 分支：同样共用 `vault5`；争用解除后严格解码 → `.invalidRecoveryJournal`
     立即 fail closed（不被重试吞掉）、journal 保留、零发布。
   - **fresh-vault/client reopen 证据**：在 publisher settle **之后**单独做一段非争用
     的 fresh vault 重开（同一 secret store、新 vault actor → 同一 pending evidence →
     fenced），并与 R25 真实 Keychain reinterpret 证据互为独立；争用阶段绝不使用
     独立 fence 冒充争用。
2. **失败也要 resume/settle**：所有注入暂停任务的块（含 `checkQueueContention` 第一段
   与 CAS 段）改为：任务变量在 do 外声明；成功路径 resume 后 await settle；catch 路径
   先 `resume`（/`resumeManifestRead`）再 `try? await` settle，然后才
   `discardShadow` 并重抛。任何退出路径不遗留挂起的 continuation。
3. **并发首次使用 fixture 精确化**（不夸大）：
   - 两个冷提交改为**同 key**：A=`cookieDeleteAll(key, gen)`、B=`credentials(key, gen,
     "cold-b")`，串行可见链：后发布者候选**同时**带两效果（jar==cleared 且
     accessKey=="cold-b"），先发布者候选只带一个效果 → 证明无丢失更新、后写者基于
     前写者串行。
   - 归因 barrier：先启动 A，用 `waitForRetrySleep(cold1, 1)`（此时仅 A 一个任务，
     归因无歧义）；提交 B 后用窗口受限的 `waitForRetrySleepWithin(cold1, 2,
     attempts: 30)`（< A 的 400ms back-off，窗口内不可能来自 A）证明 B 确实在
     preflight 争用中重试。若 B 未在窗口内到达 → 测试失败（不会假通过）。
   - 断言按"发布顺序由最终 pointer 判定"的顺序无关方式编写：最后候选含两效果、
     先候选只含其一、receipt 互异、exact count、最终快照两效果齐全。
   - 精确声明：冷态并发同 key 提交按**到达 admission 的顺序**串行（fixture 用 barrier
     构造确定性），不声称 store 保证"提交顺序"；已准入写入者的 FIFO 提交顺序（b7f6692
     已接受语义）不变。
4. **文档精确化**：R26 计划与 B2E2 计划中"同一共享预算"改为"使用同一 store 实例配置的
   有界 attempt/back-off 数值与同一 typed 耗尽策略；冷加载重试与发布重试各自独立计数，
   不构成一份共享预算"；补充 reentrant 冷加载语义（单槽幂等重读，不做 single-flight
   声明）与上述串行界限。

## 回归矩阵（保持既有断言/预算/门禁，只增不减）

- `checkQueueContention` 第一段：冷 storeB 的显式 retry barrier、两个 typed receipt、
  exact 4 发布；失败路径 resume+settle。
- `checkColdRecoveryContention`：
  1. 同 store 两个冷提交（同 key、barrier 归因、串行链、exact 4）。
  2. 有界耗尽：typed `publicationConflict`、`retrySleepCount==2`、零发布、无 fence、
     随后 follower 成功且精确一次。
  3. 冷 preflight 等待中取消：`CancellationError`、零发布、FIFO idle、随后写成功。
  4. pending journal + **共享 vault** 争用：retry barrier → typed
     `.unresolvedPublication`、journal 保留、默认 ambiguity 保留、显式确认清除、
     follower 精确一次；随后（settled 后）fresh vault 非争用重开仍 fenced、journal 保留。
  5. corrupt journal + 共享 vault 争用：retry barrier → 争用解除后
     `.invalidRecoveryJournal`、journal 保留、零发布；清理显式移除并 discard。
- 不重开已接受 b7f6692/e3ea5ae 组；R25 真实 Keychain helper 不动。

## 验收

- 小 commit/push；reconcile Actions（predecessor 29b release COMPLETED FAILURE /
  preview COMPLETED SUCCESS 已有结论，保留旧证据，不重跑）；新最终代码 SHA 显式
  dispatch `ios.yml`(release5) + `ios-home-preview.yml`(preview4)；读实际九 outcome/
  artifacts/source hashes/计数/strict analysis/BUILD/FFmpeg/preview 压力；交 Codex
  独立复审。自查不作为接受；B2e-2b/3/whole P05/authority 未接受。
