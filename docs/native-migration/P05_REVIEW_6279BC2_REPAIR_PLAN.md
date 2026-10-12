# P05 退修计划：6279bc2 复审 R11（legacy 水位丢失）/ R10（回归证明与 incarnation）

2026-10-12（Asia/Hong_Kong）。Codex 对 `6279bc2`（及 docs HEAD `8cda84d`）独立复审为
**CHANGES_REQUESTED**：CI 证据全部核实通过，但两项源代码级发现未闭合。本计划只处理这两项
及文档过度表述，不进入 B2e/Block 3，不接 authority。依据：
`build/native-migration/review-6279bc23545ceeb91c43a0e223c994df1568bbc1-codex/REVIEW.md`、
`review-8cda84d4fecac70a3fcf5bb845efd3bdd1c6e46d-codex/REVIEW.md`、
`review-deb7b84c33b0b614f7aef108a4a9dea147c49a03-codex/REVIEW.md`。

## R11（P1）：legacy schema-3 省略/null 水位在删除后丢失

- 场景：codec 有意接受 schema-3 省略或 null 的 `generationHighWater`；Domain 有效水位回退为
  当前 live 最大 generation。`applyDelete → replace` 原样复制 `current.generationHighWater`
  （nil），删除最大/最后 login 后有效水位下降；reopen 后 `install(K, G)` 接受被删代际，
  旧 K/G cookie/credential 上下文仍只按 key+generation 匹配新身份 → ABA 复活。
- 修复（声明式、单一构造口）：`PiliAccountEnvelopeTransactionStore.replace` 在
  `version == 3` 时一律解析为
  `resolved = max(carried ?? 0, current.effectiveGenerationHighWater)`，即任何 schema-3
  发布（delete/cookie/credentials/purpose/buvid/install/import/adopt）都会把**变换前**
  的有效水位持久化。schema 2 保持严格 nil（不写字段、不破坏形状）。不再存在“legacy 输入
  经过一次删除后水位丢失”的路径；reopen 后仍是具体值。
- 测试矩阵（driver，真实 Keychain staging + reopen）：
  - legacy 形状 × {省略, 显式 null} × {删除最大 login, 删除最后两个 login}；
  - 删除发布后 `generationHighWater == 变换前 live 最大`；fresh vault/store reopen 后仍相等；
  - reopen 后 `install(K, G)` 实际尝试历史同代际 → `staleGeneration`、指针/envelope 逐字节
    不变（零发布）；
  - 旧 K/G cookie/credential 上下文 → `unknownRecordKey`、零发布；
  - 合法的更大 G（G+1）安装成功且持久为新高水位；随后旧 K/G cookie/credential 仍被
    `staleGeneration` 拒绝（不会命中新身份）；
  - 保留既有非丢失路径回归（未删除前的 effective 回退 + 首次 install 持久化）。
- 说明：`applyInstall` 对 `generation <= 0` 仍分类 `invalidInstall`；`applyImport` 自
  `cb00312` key-first 排序后 `generation <= 0` 分类为 `staleGeneration`（原
  `invalidImport`）。新增两类固定用例并记录该分类变化。

## R10（P2）：负例空转、incarnation 与 direct mirror stamp

- 现状问题：
  1. WK 换主负例用 `UserInfoData.fromJson(const {})` → `isLogin=false`，删除 post-WK guard
     也不会调用 publisher，`published == false` 空转；history cache 为空可能只是
     `_ImmediateAdapter` 返回 `{}`（Error）而非 guard 生效。logout 排序测试同为空转输入。
  2. 缺少同对象 revoke/re-activate 的代际失效证明（只有换对象重装）。
  3. `setWebCookie` 未传 `stamp` 时仅查 `identical(main) + ownsCredentials`；同对象
     reset 后 `ownsCredentials` 重新为 true，不是 incarnation 检查。
- 修复：
  1. `setWebCookie` 在入口强制捕获 incarnation stamp：
     `bound = stamp ?? Accounts.captureRequest(owner)`；`bound == null` 直接返回；
     `isCurrent()` = `identical(Accounts.main, owner) && Accounts.isCurrentRequest(bound)`
     （含 tracker 代际与 ownership）。删除 `ownsCredentials` 回退。FIFO/admission 精确释放不变。
  2. 测试全部改用真正 logged-in 响应（`isLogin: true`、非空 `face`、代表性 MID），并：
     - WK 换主负例断言：publisher 调用数 0、cache 不存在、**history 请求数 0**（受控 adapter
       计数）；
     - history 竞态负例（delete/reinstall）用受控 adapter 完成**成功 data**，断言请求确实发出
       （计数 1）但 cache 不写、publisher 0；
     - 正对照：current owner + logged-in → mirror 1 次、history 请求发出、成功 data 后
       cache 写入、publisher 恰好 1 次、admission 归零；
     - logout FIFO 测试：gate 中换主 + logout clear，释放后顺序为 mirror-end → clear，
       且 publish 0、cache 不存在（stale 负例不再空转）；
     - 同对象 reset：main = `AnonymousAccount()` 单例，gate 中
       `beginAnonymousReset` + `completeAnonymousReset`（同对象重新激活、新代际），断言
       `onLoginMain` 与 direct `setWebCookie()` 都在恢复后判定 stale（旧实现会因
       `ownsCredentials` 重新为 true 而放行）；
     - 保留抛错精确释放、FIFO 排序、admission 归零断言。
- 文档纠正：R10/R11 “完全闭合/全部拒绝”表述改为“CI 已证明子集 + 独立未闭合项
  （legacy 删除丢水位 ABA；R10 空转负例/同对象代际/direct stamp）”。R12 组件证据已
  通过，不重做。

## 执行与验收

- 小提交：计划 → R11 实现+driver → R10 实现+测试 → 文档纠正；同一最终代码 SHA 显式
  dispatch `ios.yml` + `ios-home-preview.yml`；读真实 logs/artifacts（analyze/tests、
  envelope 109/44/40/N/51 只增、九强制 outcome、BUILD SUCCEEDED/109.1MB/FFmpeg、
  preview 20/`failures=[]`）。
- 通过后输出 **P05_READY_FOR_INDEPENDENT_REVIEW** 并等待 Codex；不自行宣称 PASS、
  不进入下一组。四 flag false；不接 authority；不碰 UI/Aether/`youtube/`。
