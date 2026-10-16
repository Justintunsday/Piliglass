# P05 下一组计划：B2e-2b-1 revert 方向 schema-3 durable-identity 严格解码（carriage 契约）

2026-10-16（Asia/Hong_Kong）。依据 TOP handoff：先记录 75d829c/b73efec 有限 PASS（已随
`dd95f0e` docs-only commit 完成），再按依赖读计划并保存本组计划后才实施；本组是
**B2e-2b identity-consumer alignment 的第一个可独立执行切片**，不伪装 Block3 composition、
不扩大 authority。依据：`P05_B2E2_PERSISTENT_RECOVERY_PLAN.md` §3、`P05_BRIEF.md`、
`P05_TAGGED_BOUND_READER_PLAN.md` carry-forward、`P05_DURABLE_IDENTITY_QUEUE_PLAN.md` §1。

## 现状（精确源码）

- Swift 侧 shadow wire 已是 **schema 3**：`PiliAccountLiveMemoryShadowCodec` 现代 key set =
  legacy + `generationHighWater`；record key set = legacy + `durableIdentity`；schema 3 每条
  login record **必须**携带 `durableIdentity`（canonical 小写 UUID 文本，恰 36 UTF-16 units，
  8/13/18/23 为连字符、其余小写 hex），跨 record 唯一；anonymous record 必须为 null；
  `generationHighWater` 为 null 或 ≥ max(login generations) 的 int；`durableIdentityConfigured/
  durabilityVerified/authoritySwitchAllowed/nativeWritesAllowed` **即使 schema 3 也恒 false**
  （identity 只是持久 record label，绝不授权）；schema 2 的 record 出现 `durableIdentity`
  （含 null）被拒。`lookupRecord(durableIdentity:)`/`loadPublishedCandidate` 是上游只读消费面。
- Dart 侧 `NativeAccountReverseImport`（`lib/services/native_accounts/
  native_account_reverse_import.dart`）只接受 **schema 2** 且硬性要求四个 flag false；
  record 形状不含 `durableIdentity`。Block3 revert/handoff 路径将把 Swift schema-3 信封喂给
  该 decoder——当前会整体拒绝，identity 无法进入 Dart 消费面。Dart 现有
  `durableIdentity*` 零实现。
- **命名空间纪律**：bridge `stagingExport` 的 `identity:{ownerToken,generation}` 是 tracker
  token（`_tokens` Expando），与 durable identity（36 units 文本）**不得混用**；snapshot
  service 自带 owner/generation + checkpoint，本组不改。

## 本组范围（可独立执行、shadow-only、零 authority）

**B2e-2b-1：revert 方向 schema-3 durable-identity 严格解码 + 供 Block3 消费的只读暴露。**

1. `NativeAccountReverseImportResult` 新增 `recordDurableIdentities`（unmodifiable、
   与 records 同序；schema 2 与 anonymous 位置为 null），供后续 Block3/启动对齐消费；
   `apply()` 行为不变（Dart 账号不携带 identity；apply 侧对齐仍属 Block3，不在本组伪装）。
2. `_EnvelopeReader` schema-aware 化，严格镜像 Swift 语义：
   - schema 2：exact legacy key set（含 record 无 `durableIdentity`、顶层无
     `generationHighWater`），任何出现（含 null）→ typed 拒绝；
   - schema 3：顶层 legacy + `generationHighWater`（null 或 int ≥ 0 且 ≥
     max(login generations)）；login record 必须携带 canonical 36-unit 小写 UUID 文本
     （hyphen 位置 8/13/18/23、其余小写 hex），跨 record 唯一；anonymous 必须 null；
   - 四 flag 恒 false（`durableIdentityConfigured: true` → 拒绝；identity 绝不授权）；
   - 类型严格：`durableIdentity` 只允许 null 或 units 数组；字符串/map（如 tracker
     `{ownerToken,generation}`）→ 拒绝（命名空间不混用）；
   - 既有全部校验（顺序、预算、selections/history、jar）不变；拒绝仍是 typed
     `NativeAccountReverseImportException`，decode 纯函数零写。
3. 新 Dart 回归（扩展 `native_account_reverse_import_test.dart`，只增不减）：
   1. 由真实 schema-2 capture 构造 schema-3 信封（补 canonical identities +
      generationHighWater=max）→ decode 成功、identities 按序暴露、经 gated port apply
      后 normalized 内容仍往返一致；
   2. login record 缺 identity → 拒绝；
   3. 重复 identity → 拒绝；
   4. 非 canonical（大写/长度 35/37/hyphen 位移/非 hex）→ 拒绝；
   5. anonymous 带 identity → 拒绝；
   6. schema 2 混入 `durableIdentity`（null 或值）或 `generationHighWater` → 拒绝；
   7. `generationHighWater` 负数或低于 max → 拒绝；恰等于 max → 接受；
   8. tracker-map 假冒 durable identity → 拒绝；
   9. `durableIdentityConfigured: true` → 拒绝。
4. 文档：本计划 + B2E2 计划 §3 的 2b 进度注记（部分实施：revert 方向 carriage；
   bridge export 方向与 frozen-revision composition 仍属 Block3，不得声称完成）。

## 边界与验收

- 不改 authority/flag、不碰 UI/`youtube/`、不真实账户；不降 264 account/245 transaction/
  292 queue 基线、180/90 预算或断言/门禁；Dart 测试只增。
- 小 commit/push；新最终代码 SHA 显式 dispatch BOTH `ios.yml`+`ios-home-preview.yml`；
  读实际 artifacts（account 计数只增、envelope 109/44/40/245/292/51、九 outcome、
  BUILD/FFmpeg、preview 20/压力）；docs 证据与代码 SHA 分离；交 Codex 独立复审。
- 明确未做（不得声称）：bridge export 携带 durable identity、frozen-revision handoff/
  启动 apply、revert 幂等映射、GC、Block3 production composition、CA5/CA6 真机。

## 状态注记（2026-10-16）：本组切片获 Codex 有限 PASS

- B2e-2b-1（schema-3 strict decode + `recordDurableIdentities` 只读 correlation +
  R38 预投影记账）在代码 SHA `ea60931` 获 Codex 有限 PASS（详见 `PROGRESS.md`/
  `P05_COMPLETION_REPORT.md` §16；docs 记录与测试 SHA 分离）。
- 明确仍开放（继承上文边界不变）：`apply()` 不向已安装 Dart Accounts 携带 durable
  labels；schema-3 测试输入为 actual Dart capture 增补，非 Swift 产出端到端 handoff；
  bridge export 携带 identity、frozen-revision handoff/startup apply、revert 幂等映射、
  GC、Block3 production composition 均未实施。
