# P05 计划：B1h 真实 `Accounts.set` purpose read-transform-publish 干扰（原 53aed63 开放行）+ 真实消费者清单核对

2026-10-16（Asia/Hong_Kong）。依据 TOP handoff（`c9adf9b` 有限 PASS 已随 docs-only
`8a57197` 记录）与 `review-53aed63`（原始开放行）+ 各 R48/R49 复审口径。**在实现之前保存。**

## 依据与范围

- 原 53aed63 开放行："Purpose CAS test remains generic/staging-level rather than actual
  read-transform-publish interference. Plan may explicitly narrow verification, but cannot
  mark that promised coverage proven without a targeted case."
- 本组按 TOP 要求：驱动**真实** `Accounts.set`/purpose/lifecycle 的 after-await 并发
  selection/replacement/replacement-revoke 契约，验证 owner/epoch/generation 检查
  （**admission 只是 drain 记账，不是独占所有权**，不得把 token/admission 当成足够条件）；
  先读实际 Dart 语义再写测试，不复制 resolver、不 relabel preset、不做 generic shadow-only
  覆盖、不宣称 all 120 csrf/18 access 全量闭合。

## 实际 Dart 语义（源码核对，先于任何改动）

- `Accounts.set(key, value)`（lib/utils/accounts.dart:541-591）：
  1. `tryAdmit()`；frozen → 抛 `StateError('Account write-back is frozen')`（已由
     `account_write_barrier_test` :325/:339/:356 覆盖，**本组不重复**）；
  2. `_resolveSelection(value)` → `captureRequest(selected)!`（stamp）；
  3. 同步（publish #1）：`oldAccount = _accountMode[key]` → `oldAccount.type.remove(key)`；
     `_accountMode[key] = selected..type.add(key)`；`_requestState.changed()`；
  4. `await Future.wait([selected.onChange(), oldAccount.onChange()])`
     （`LoginAccount.onChange` = `persistLegacyAccount`，真实 Hive 写入）；
  5. **revalidate #1**：`identical(_accountMode[key], selected) && isCurrentRequest(stamp)`，
     失败即 return（不产生后续效果）；
  6. `if (!selected.activated) await Request.buvidActive(selected)`：`activated` 先被同步置
     true，然后 POST `Api.activateBuvidApi` 经 `Request.dio` —— **可被受控 adapter 暂停的
     确定性干扰窗口**；
  7. **revalidate #2**（同上）；
  8. purpose 效果：`main` → `LoginUtils.onLoginMain/onLogoutMain`（其内部对 userInfo、
     setWebCookie、syncHistoryStatus、publisher 各自再验证 owner/一致性；
     `LoginUtils` 已有测试 seam `webCookieMirrorWriter`/`webCookieClearer`/
     `loginMainPublisher`）；`heartbeat` → `MineController.anonymity.value = !selected.isLogin`；
     其他 → 无后续效果；
  9. `finally admission.release()`。
- 语义结论（不是缺陷，写测试时按此断言）：同步阶段（3）的 type/slot 修改**不**回滚
  （last-writer-wins；T4 中后写者的 `oldAccount.type.remove` 会覆盖前者的 add，回滚会破坏
  后写者结果）；after-await 效果由 revalidate #1/#2 守卫。观测点：
  - `main` 路径若通过 revalidate #2，会再产生 `UserHttp.userInfo`（请求 #2）与
    `UserHttp.historyStatus`（请求 #3，`{"code":0,"data":true}`）经受控 adapter；
  - 若 revalidate #2 失败，则**没有** #2/#3、没有 mirror/publisher（admission 仍被持有）。
- 已有覆盖（不得重复/不得重开）：write-barrier frozen set/select/refresh 零效应；
  `account_request_lifecycle_test` 的顺序替换 type 保留；`account_owner_revalidation_test`
  对 `onLoginMain/onLogoutMain/syncHistoryStatus` 的直接 seam 驱动；R48/R49 消费者/fixture。
- **缺失（本组闭合）**：`Accounts.set` 在真实 await 窗口内遭遇并发 selection switch、
  same-MID replacement、deleteAll、并发 set 的 targeted read-transform-publish 干扰行为。

## 本组实现（新文件 `test/utils/accounts/account_purpose_set_interference_test.dart`）

真实 Hive（`AccountTestStorage`）+ 受控 adapter（`Request.dio`，无 interceptor——本组只测
`Accounts.set` 语义）+ `LoginUtils` 三个 seam（setUp 替换、tearDown 复原，记录
mirror/publish 调用）+ 可注入干扰：

1. **T1 对照（证明 harness 能到达 publish 链）**：`A.activated=false`；
   `Accounts.set(main, A)` → 暂停于 `activateBuvidApi`（#1，`A.activated` 已同步为 true）→
   完成 #1 → #2 `userInfo`（`{"code":0,"data":{"isLogin":true,"mid":4242,"face":…}}`）→
   #3 `historyStatus`（`{"code":0,"data":true}`）→ `await setFuture`；断言 slot==A、
   `mirrorCalls==1`、`publishCalls==1`、`GStorage.localCache[historyPause]==true`。
2. **T2 selection switch 干扰**：暂停后 `selectTemporarily(main, B)` → 完成 #1 →
   revalidate #2 失败：**零** #2/#3（`issued==1`）、无 mirror/publish；slot==B；
   `B.type` 不含 main；`Accounts.isCurrentRequest(stampA)` 仍为 true —— 证明 slot 检查是
   判别性的（stamp 单独不足）。
3. **T3 same-MID replacement 干扰**：暂停后 `await Accounts.installCredentials(A')` →
   完成 #1 → stamp 失效：零 #2/#3；`captureRequest(A)==null`；slot==A'；`A'.type` 含 main
   （preserveTypes 继承被中断 set 的持久意图）；无 publish/mirror。
4. **T4 并发完整 set（last-writer-wins）**：A 暂停于 #1 后发起 `set(main, B)`
   （B.activated=true）：B 流程完成 #2/#3、mirror/publish 各 1 次；随后完成 A 的 #1 →
   A 的 revalidate #2 失败（slot==B）。断言：slot==B；`B.type`{main}；`A.type` 不再含 main
   （由 B 的 `oldAccount.type.remove` 移除，说明不回滚是正确语义）；`issued==3`；
   publish 总数仍为 1（A 无 stale 发布）；两个 future 都正常完成。全程两者 admission 并存
   —— 证明"admission 不是独占锁，owner/stamp 才是判定"。
5. **T5 deleteAll 干扰**：暂停后 `await Accounts.deleteAll({A})` → 完成 #1 →
   revalidate 失败（stamp 撤销 + slot 匿名）：零 #2/#3；slots 全匿名；`captureRequest(A)`
   为 null。
6. **T6 heartbeat purpose 后置效果**：`MineController.anonymity.value = true`（显式初值）；
   对照：`set(heartbeat, A)`（A.activated=false）暂停→完成 #1→revalidate 通过→
   `anonymity == false`；干扰变体：暂停后 `selectTemporarily(heartbeat, B)`→完成 #1→
   revalidate 失败→`anonymity` 保持 true。证明 heartbeat 后置效果同样受 revalidate #2 守卫。

## 生产改动

本组以源码语义为准编写回归；仅当测试暴露**实际**缺陷时在同组做聚焦修复（不弱化断言、
不发明 rollback、不改 authority）。当前源码预期全部通过（revalidate #1/#2 已存在）。

## 真实消费者清单（如实核对；本组只闭合 `set`/purpose 干扰行为面）

- `csrfOf`：raw 124 匹配/18 文件 = 1 定义 + 3 注释 + **120 live 调用**（17 文件）；
- `accessKeyOf`：raw 19/9 文件 = 1 定义 + **18 live 调用**（8 文件，含 member_profile/
  video_popup_menu）；
- refresh/导出消费者、gRPC `grpcHeaders`（`account_mgr.dart:89` 单一请求消费）、
  lease/`captureRequest`、snapshot bridge、WK mirror（LoginUtils seam）、LoginUtils 延迟
  副作用、Hive maintenance/GC —— 均**本组不闭合**。
- 本组只覆盖 `Accounts.set`（main/heartbeat/默认 purpose）在 await 窗口的
  selection/replacement/deleteAll/并发 set 干扰；其他 purpose 组合与所有 writer 仍开放。

## 边界与验收

- 新最终代码 SHA 显式 BOTH workflows（各一次）；读实际 evidence（account 计数只增、
  315 基线不降、strict analyze、native/hash/goldens、九 outcome、BUILD/FFmpeg、preview
  20/11/压力）→ docs-only 证据（与代码 SHA 分列）→ Codex 独立复审。
- 不重跑 unchanged `c9adf9b`；不自我验收、不推进 authority/下一组；四 flag false、
  Flutter/Dart fallback、Aether 独立、不读/改 `youtube/`、无 UI visual/真实账户写/auth/
  captcha/设备伪造；本地无 Dart/Flutter SDK（不声称本地运行）。
- B2e-2b bridge/frozen revision、Block3 composition/handoff/revert/startup/GC、Block4/
  Block5 仍按依赖后续；保留全部历史失败（127 六红、8d 两失败、R48/R49 实际记录）。
