# P05 退修计划：R10 / R11 / R12（codex 53aed63 + 9724ddb 复审）

2026-10-12（Asia/Hong_Kong）。复审结论均为 CHANGES_REQUESTED：CI 通过不构成独立验收。
本计划处理 `build/native-migration/codex-review-53aed63/REVIEW.md`（R10/R11）、
`review-9724ddb-codex/REVIEW.md`（R12 更新）与 `review-d732ec0-codex/REVIEW.md`（补充
覆盖）。四能力 flag 保持 false；不接 authority；不改 Dart authority。

## R10（P1，Dart）：登录 owner 必须活过每一个异步阶段

- 现状：`onLoginMain` 仅在 userInfo 后复核一次；`setWebCookie`/`syncHistoryStatus`
  两个后续 await 之后直接发布 response.face/isLogin/userInfoCache；WK 镜像与
  logout/login 无排序，旧 mirror 可最后完成覆盖新状态。
- 修复：
  1. 捕获 `account + AccountRequestStamp`（generation 语义，覆盖同对象 revoke/re-activate）；
     `_isCurrentMain(account, stamp)` = `identical(Accounts.main, account) &&
     identical(stamp.account, account) && Accounts.isCurrentRequest(stamp)`；在 userInfo、
     WK mirror、history 每个 await 之后、下一个共享效应之前复核，失败即返回。
  2. WK 镜像串行化队列：`setWebCookie` 与 logout 的 `deleteAllCookies` 都进入同一
     static FIFO；队列动作执行时再次复核 owner，逐 cookie 写并在每个 await 前检查
     （stale 立即停止），保证旧 mirror 不可能最后覆盖新状态。
  3. 可注入 seam（测试用，默认生产实现）：
     `LoginUtils.webCookieMirrorWriter(account, cookies, isCurrent)`、
     `LoginUtils.clearWebCookies()`、`LoginUtils.publishLoginMain(response)`；
     测试注入可 gate/记录/抛错的实现并恢复。
  4. token 精确释放：throws/cancel 路径 finally 释放一次；新增断言。
- 测试（owner_revalidation 文件）：
  a. SECOND await（WK mirror）期间换主：mirror 后续 cookie 不写、history/publish 不执行、
     cache 不变；
  b. SECOND await（history 请求）期间 delete/reinstall：publish 不执行、userInfoCache
     不变；
  c. WK 排序：登录 A 的 mirror 被 gate，logout clear 入队其后，释放后最终动作是 clear
     （新状态最后）且 A 的 stale cookie 不残留；
  d. mirror 抛错：错误传播、`liveOperationCount` 归零（精确一次释放）；
  e. 既有正路径（current owner）保持：mirror/publish 正常、cache 写入。

## R11（P1，Swift shadow）：历史 generation 复用（ABA）

- 现状：install/import 只与 current.records 去重；delete(K,G)→install(K,G) 被接受；
  import G1→G2→G1 同样；generic transaction 只查 key+generation。
- 修复：**generation 高水位（monotonic，持久于 schema 3 envelope）**：
  - envelope 增加 `generationHighWater: Int64?`（schema 2 必须 nil；schema 3 允许 nil 以
    兼容旧 schema 3，nil 时按有效值 `max(records.generation, 0)` 参与判定）。
  - 校验：`generationHighWater >= max(login record generations)`（非负）；
    schema 2 必须 nil；encode：schema 3 有值时写出、nil 时省略（保持旧形状可 decode）。
  - codec：envelope key 形状 schema-aware（15-key 现代 / 14-key legacy，各自严格）。
  - `adoptMissingIdentities`：写入 `max(record generations, 0)`；`applyInstall`/
    `applyImport` 要求每个输入 generation `> effectiveHighWater` 且互不相同，且候选
    high-water = `max(effective, 输入最大值)`（**持久化**，重启后仍拒绝历史复用）。
  - 其余事务保留字段；delete 不降 high-water。
  - overflow：`generation == Int64.max` 后继不可再增（安装即拒绝），无回绕；
    cold start：adoption 以现有最大 generation 为水位。
- 测试：delete(K,G)→install(K,G) 拒绝（`staleGeneration`、零发布）；install(K,G+9000)
  后旧 (K,G) cookie/credentials 事务拒绝、新 G 可写；import G1→G2→G1 拒绝；上述在
  fresh Store/Keychain reopen 后同样拒绝；overflow 边界（Int64.max）拒绝；既有
  install/import/purpose 用例改用 > 水位的代际并全过。

## R12（P2，Swift 测试/契约）：buvid 预算与值域

- 修复：
  1. `applyBuvidSeed` 在构造 field 之前做**主动长度校验**：
     `valueUnits.count <= buvidMaximumValueUnits`（= standard `maximumValueUnits` − 64
     头部余量；常量与契约写入计划/code），超过 → `PiliAccountLiveMemoryShadowError.
     resourceLimit`（不再依赖 parser）。
  2. 支持值域明确：可打印 ASCII（0x21…0x7E）且不含 `;`，长度 ≤ 上限；
     逗号/反斜杠/内引号仍按 parser 行为拒绝并记录（不宣称全部 printable 接受）。
  3. driver：
     - 原 70k 用例改为期望主动 `resourceLimit`（保留零发布断言）；
     - 边界：恰好上限值（如 65472）通过并成功；上限+1 → `resourceLimit` 零发布；
     - **真实共享预算回归**：有效普通值（46 字符），当前 envelope 可编码，设置
       `maximumEncodedBytes = 当前编码字节数` 的 store：加值后候选超预算 →
       `PiliAccountLiveMemoryShadowError.resourceLimit`、指针/envelope 逐字节不变；
     - parser 上限拒绝保留在 reducer/raw-field 套件（既有 checks），文档注明 API 已
       在 parser 之前拦截；
     - 非空 jar 顺序：install 一条带既有 cookie 的记录（jar = `saved`），seed 后
       path 顺序为 [既有, buvid3]、既有值不变；
     - map key != Cookie.name：手建 archive，entry key 非 `buvid3` 但 name 为 `buvid3`
       → seed 仍新增 key `buvid3` 条目且保留旧条目；
     - 已存在但 expired 的 buvid3：no-op（seeded=false、指针不变），证明按 map key
       而非有效期判断。
  4. 文档修正：`P05_DURABLE_BUVID_PLAN.md` 的值域/错误类型、53aed63 的"已验收"改为
     "CI 通过、独立审核 CHANGES_REQUESTED"；STATUS/PROGRESS 同步纠正。

## 执行与验收

- 小提交：R12+buvid 补充 → R11 → R10 → 文档纠正；同一最终代码 SHA 显式 dispatch
  `ios.yml` + `ios-home-preview.yml`；读真实 logs/artifacts（账户计数、envelope
  109/44/40/N/51 只增、九强制 outcome、BUILD SUCCEEDED/109.1MB/FFmpeg、preview 20）。
- 通过后输出 **P05_READY_FOR_INDEPENDENT_REVIEW**，等待 Codex 复核；不自行宣称验收、
  不进入下一组。失败按日志修复→新 SHA 重跑两条。
- 边界：不接 authority、无生产 caller、不改 Dart authority；四 flag false；不碰
  UI/Aether/`youtube/`。

## 闭环记录（2026-10-12，最终代码 SHA `6279bc2`）

> **2026-10-12 08:07/08:18 复审更正**：本节的"覆盖/全部拒绝"仅描述 **CI 已证明的组件子集**。
> Codex 独立复审结论为 CHANGES_REQUESTED，明确未闭合：R11 的 legacy 省略/null 水位在
> **删除最大/最后 login 后**丢失（既有用例只在删除前复用，未覆盖丢失序列）；R10 的 WK
> 负例使用 `isLogin=false` 输入（空转）、缺少同对象 revoke/reactivate 代际证明、direct
> `setWebCookie` 未传 stamp 时仅查 `ownsCredentials`。R12 组件（109/44/40/202/51 里的
> 新增用例）已被复审核实通过，不需重做。修复计划见
> [P05_REVIEW_6279BC2_REPAIR_PLAN.md](P05_REVIEW_6279BC2_REPAIR_PLAN.md)。

- R10（CI 证明子集）：`login_utils.dart` 捕获 owner+stamp，userInfo/WK mirror/history 每个
  await 后、下一共享效应前复核；WK mirror 与 logout clear 走同一 FIFO 队列、执行期逐
  cookie 复核；新增 `webCookieMirrorWriter`/`webCookieClearer`/`loginMainPublisher` 测试
  seam。测试：WK 期间换主、history 期间 delete/reinstall、mirror 排序（新 mirror/logout
  clear 最后）、mirror 抛错精确释放、current owner 正路径。账户测试 250→**256**。
- R11（CI 证明子集）：schema 3 envelope 持久 `generationHighWater`（monotonic）；
  install/import 要求 `generation > effectiveGenerationHighWater` 并持久新高水位；覆盖
  delete→同 G install、G1→G2→G1、跨 Keychain reopen、Int64.max 溢出、以及旧 key+G 的
  cookie/credentials 写入拒绝；import 重复 key 先于 generation 判定。**删除前**的
  legacy 省略/null 回退用例通过，但删除丢失序列见上方更正。
- R12（CI 证明，保留）：`applyBuvidSeed` 主动长度上限（`buvidMaximumValueUnits` =
  65536−64）→ `resourceLimit` 先于 field 构造；driver 新增上限+1 拒绝、恰在上限成功、
  真实编码字节预算回归（有效普通值、当前 envelope 可编码、加值超预算 → `resourceLimit`
  零发布）、非空 jar 顺序、map-key≠Cookie.name、expired no-op；parser 上限拒绝保留在
  reducer 套件；计划值域/错误分类已修正。
- 同 SHA 验证：release [38185057809](https://github.com/Justintunsday/Piliglass/actions/runs/38185057809)
  5/5、preview [38185059780](https://github.com/Justintunsday/Piliglass/actions/runs/38185059780)
  4/4；账户 analyze 无问题、`+256`；envelope `status=passed`
  109/44/40/**202**/51、sourceSHA=workflowSHA=6279bc2；九强制 outcome success、
  BUILD SUCCEEDED/109.1MB/FFmpeg、preview 20 tests/`failures=[]`。
- 修复过程：analyze cascade/extra-positional/unnecessary-async/body-might-complete、
  setUpAll 的 `userInfo` late box、codec `try`、import 重复 key 次序、非空 jar fixture；
  每轮失败均取消后在**新 SHA**重跑两条。
- 状态：CI 证据已核实；**独立复审 CHANGES_REQUESTED**，R11 legacy 删除 ABA 与 R10
  回归/incarnation 未闭合，修复后需新 SHA 双 CI 再复审；在 PASS 之前不进入下一组、不写
  "已验收"。四 flag false；不接 authority。
