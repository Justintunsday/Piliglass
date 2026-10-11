# P05 复审修复计划（codex-review-3b8e821）

2026-10-11（Asia/Hong_Kong）。复审对象：HEAD `f87eb88`（docs-only delta；代码 SHA
`3b8e82171e35fadb8d81ce3e2af5c9dc63932976`）。本文件逐项给出判定、修复与回归测试；
不改变已验收事实（release 38137735191 / preview 38137738208 的绿只说明既有门禁通过）。
Native 仍为 shadow 组件、四能力 flag false、无生产 authority 切换，本计划不宣称安全
状态或 P05 完成。

## 项 1（P1）drain：`syncHistoryStatus` 未 await 真实持久化

- 判定：成立。`request_utils.dart:65` `GStorage.localCache.put(...)` 未 await，
  `finally` 立即释放 admission；freeze/drain 无法覆盖真实写。
- 修复：`await GStorage.localCache.put(...)`。
- 测试：受控 Hive 写（无法注入？用真实 `localCache` + 先写后读核对，并以冻结并发验证
  链未释放）+ frozen 拒绝路径；失败路径（写抛错）仍释放且传播。

## 项 2（P1）maintenance：quiesce 非互斥，存在零计数与微任务间隙

- 判定：成立。`quiesce()` 在 `_admitted == 0` 瞬间完成，之后新 admission 可开始；
  `GStorage.close/compact` 因此可能与新写重叠。
- 修复：coordinator 增加**维护独占 barrier**：
  - `Future<AccountWriteBackMaintenance?> beginMaintenance()`：若已 closed 返回 null；
    同步置 `_maintenance = true`（新 `tryAdmit` 返回 null），若在途 >0 等待排空；返回 token。
  - `endMaintenance(token, {required bool permanent})`：校验 token；`permanent` 置
    `_closed = true`（永不恢复）；否则仅清 `_maintenance`。**不触碰 `_frozen`**（authority
    freeze 不会被意外恢复）。
  - `tryAdmit`：`_frozen || _maintenance || _closed` → null。
  - `GStorage.compact`：`beginMaintenance` → 执行 → `endMaintenance(permanent:false)`；
    `GStorage.close`：`beginMaintenance` → 执行 → `endMaintenance(permanent:true)`。
- 测试：空闲时 begin 后立即 admission 被拒；在途最后一条释放边界处 begin 与新 admission
  互斥；resume 后 admission 恢复；permanent 后永不恢复；已 frozen 的 coordinator
  begin/end 不清除 freeze。

## 项 3（P1）owner race：await 之后未复核 owner

- 判定：成立。`onLoginMain` 捕获 main A，await userInfo 后直接镜像 A/更新共享 UI 与
  cache；`syncHistoryStatus` await 网络后写 stale history。
- 修复：
  - `LoginUtils.onLoginMain` 增加可注入 `userInfo`（默认真实），await 后校验
    `identical(Accounts.main, account) && Accounts.ownsCredentials(account)`；不成立则跳过
    setWebCookie/syncHistoryStatus/UI/cache 副作用（失败分支的 `deleteAll({account})`
    目标保持原 owner 捕获）。
  - `syncHistoryStatus` await 后校验 `identical(Accounts.history, account) &&
    Accounts.ownsCredentials(account)`，不成立则不写 localCache。
- 测试：A→B（`selectTemporarily` 切 main）与 delete/reinstall-while-await 的确定性用例：
  副作用不发生；正常 owner 路径保持既有行为。

## 项 4（P2）drain：`refresh` 的 buvid 链边界

- 判定：需核对。`refresh` 返回 `Future.wait(...).whenComplete(release)`；`set` 的
  `buvidActive` 已 await。补测：gated buvid 网络链（注入 `Request.buvidActive`？改用受控
  Dio adapter）覆盖“最后一个真实 await”，frozen 期间 refresh 自带 admission 的释放语义。
  如有未 await 路径按行号修正并加测试。

## 项 5（P1）shadow generation：import 复用旧 generation

- 判定：成立。`applyImport` 允许 entry generation == 被替换记录旧 generation；旧请求
  key+generation 可命中新凭据。
- 修复：替换路径要求 **genuinely new generation**（≠ 被替换记录当前 generation），否则
  `staleGeneration`；新增回归：替换后旧 key+旧 generation 的 cookie/credentials 事务必须
  被拒绝（staleGeneration），新 generation 可写。
- 另记录：delete/reinstall ABA（删除→重装新 generation 后旧请求被拒）与 durableIdentity
  进入请求上下文的前置条件写入计划/状态，作为生产接线前项；本组只做 shadow API 正确性。

## 项 6（P2）import parity：selections/history/ownerOrder 与 Dart refresh 不一致

- 判定：成立。Dart `importCredentials` 结束于 `refresh()`：清空临时选择、按 owner/types
  重建槽位；替换会 revoke/remove 再 insert，ownerOrder 变为“其余 owner 原序 + 被替换 key
  按输入顺序 + 新 key 按输入顺序”。
- 修复（shadow 内部按 Dart 可观察语义重建）：
  - ownerOrder：移除所有被输入 key 命中的条目，再按输入顺序追加被替换 key 的条目，
    最后按输入顺序追加新 key 条目。
  - selections：从 ownerOrder 迭代重建：对每个 slot(purpose)，取 ownerOrder 中**最后**
    一个 persistedPurposes 含该 purpose 的记录，否则匿名 0（等价 Dart 按 `_owners` 顺序
    逐 value.type 赋值、后写覆盖）。
  - history：按 heartbeat/main 策略重算。
  - 临时选择在 import 后不保留（与 Dart refresh 清空一致）。
- 测试：重写现有“selections/history 不变 / ownerOrder 追加”断言为 Dart parity 断言
  （用被测 envelope 的 ownerOrder+purposes 计算期望值），覆盖替换+新 key 混合、临时选择
  清空、替换 owner 移到结尾。

## 项 7（P2）strict schema：recordFields 与 schema 无关

- 判定：成立。schema 2 带 `durableIdentity: null` 会被现代 key 形状解码并在重编码时丢字段。
- 修复：`recordFields(value, schemaVersion:)`：
  - schema 2 → 仅 legacy 形状；
  - schema 3 → 先现代形状、失败回退 legacy（匿名省略 identity）。
- 测试：schema2+identity（含 null）→ `invalidEnvelope`；schema3+login 缺 identity →
  `invalidEnvelope`；schema3+匿名显式 null 可解码。

## 项 8（P2）B2a purpose primitive：前置与缺失验证

- 判定：`applyPurposeChange` 是“调用者声明 previous”的低层 primitive，不做全局持有者
  扫描；不擅自给旧 capture 施加全局唯一约束。
- 修复：代码/计划明确 exact 语义与前置（previous 必须指向真实持有者；nil 表示无 previous；
  同记录 previous 不清除；不扫描其他持有者），并补测试覆盖：A 持有、选 B、previous
  省略 → B 获得且 A 保留（记录为 primitive 语义）；previous=C（非持有者）→ 不删除任何。
  补 promised 验证：close/reopen 全量读回、purpose 编码字节预算边界（用缩小
  `maximumEncodedBytes` 的 store 触发 `resourceLimit` 零发布）、CAS 指针身份推进。
  （完整 CAS 竞争沿用 staging 级既有用例。）

## 项 9（P2）reader/inventory 缺口

- 判定：`csrfOf/accessKeyOf` 的 fallback 无法区分“未安装兼容”与“已绑定但被 reader 拒绝”；
  仍有直读点。
- 修复：
  - 新增 `Accounts.boundCsrf(owner)`/`boundAccessKey(owner)`：`_requestState.capture` 为
    null → null（未安装）；绑定则返回 reader 结果（revoked → null）。
  - `csrfOf/accessKeyOf` 保留为 legacy 兼容包装并注明语义；accessKey 绑定路径不再用
    `?? owner.accessKey` 掩盖拒绝。
  - 迁移直读点：`ios_native_ui_bridge.dart:2081`、`member_profile/view.dart:348/523`、
    `video_popup_menu.dart:104` 到访问器；相应测试。
  - 文档明确“并非全部 reader 已收口”。

## 执行与验收

- 小提交分组：Dart drain/maintenance/owner/buvid → Swift schema/import/purpose → reader/inventory。
- 每组汇合后在**同一代码 SHA** 显式 dispatch `ios.yml` + `ios-home-preview.yml`；读实际
  artifacts（账户计数、envelope 109/44/40/139/51 只增不减、九强制 outcome、BUILD
  SUCCEEDED/109.1MB/FFmpeg、preview 20 tests）。失败读日志修复→新 SHA→重跑两条。
- 通过后更新 PROGRESS/STATUS_MATRIX/相关计划并给交付报告。
- 边界：不接 authority、不产生生产 caller、不改 Dart authority、四 flag false、不碰
  UI/Aether/`youtube/`；不伪造真机结论。
