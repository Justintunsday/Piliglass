# P05 计划（R50 收窄后）：B1h 真实 Dart `Accounts.set` post-activation revalidate#2 干扰（main/heartbeat）

2026-10-16（Asia/Hong_Kong）。**R50 收窄版本**：依据
`review-eb58d5cdfbd709c73db727a4c25c61e9c1666894-codex/REVIEW.md`（R50 scope
correction 与该组 FINAL DISPOSITION）与
`review-44a9818482baad28d9864579f8324091de54d1a8-codex/REVIEW.md`（plan review），
修正先前把本组映射为"原 53 开放行闭合"的错误口径。**本文件在实现之前保存（已实现部分保留，
见下）；R50 收窄已获独立接受，测试代码 SHA `eb58d5c` 获 LIMITED PASS（仅 7 用例范围）；
docs-only 收窄提交 `b4ea200` 非测试 SHA。Native purpose CAS 保持 OPEN，其 proposed plan
已按 R51（`review-b4ea200…`）修正，处于计划复核门。**

## 范围修正（R50）

- 原 3b8e821 item8 / 53aed63 "purpose CAS read-transform-publish" 实指 **Native
  `PiliAccountEnvelopeTransactionStore.applyPurposeChange`** 的
  load→transform→publish `expectedTransactionID` 边界（当前实现 line 686 委托
  `transaction(...)`：`loadShadowSnapshot → transform → publishCandidate(expectedTransactionID:
  snapshot.transactionID)`；wrapper gate 不能栅栏其它 shared-vault 调用者，源码注释
  line 1166-1168）。**本 B1h Dart 组不调用该 Native API，不能闭合该行。**
- 本组实际闭合的仅有：真实 Dart `Accounts.set`（`main`/`heartbeat`）在
  **post-activation（revalidate #2）** 窗口遭遇并发 selection switch / same-MID
  replacement / deleteAll / 并发 set 的可观察干扰行为（7 个用例，已实现并实际执行）。
- 明确保持 OPEN（不得声称闭合）：
  1. **Native `applyPurposeChange` read-transform-publish CAS（原 53 item8）** —— 见
     [proposed plan](P05_B2E2B_NATIVE_APPLY_PURPOSE_CHANGE_CAS_PLAN.md)；
  2. `Accounts.set` 的**初始 Hive `onChange` await / revalidate #1** 边界；
  3. **default purpose 分支**（本组只有 main/heartbeat 直接用例）；
  4. 其它 await 边界与全部 writer/async closure；
  5. 全部 120 csrf/18 access 消费者、gRPC purpose binding、B2e-2b bridge/frozen
     revision、Block3 composition/handoff/revert/startup/GC、Block4/5、authority。

## 实际 Dart 语义（源码核对，先于改动；本组未改生产）

- `Accounts.set(key, value)`（lib/utils/accounts.dart:541-591）：
  1. `tryAdmit()`；frozen → 抛 `StateError`（已由 `account_write_barrier_test`
     :325/:339/:356 覆盖，本组不重复）；
  2. `_resolveSelection(value)` → `captureRequest(selected)!`（stamp）；
  3. 同步：`oldAccount.type.remove(key)`；`_accountMode[key] = selected..type.add(key)`；
     `_requestState.changed()`；
  4. `await Future.wait([selected.onChange(), oldAccount.onChange()])`；
  5. revalidate #1（slot 身份 + stamp）；
  6. `if (!selected.activated) await Request.buvidActive(selected)`（activated 同步置位，
     POST 经受控 adapter → **本组使用的确定性暂停点**）；
  7. revalidate #2；main → `LoginUtils.onLoginMain/onLogoutMain`；heartbeat →
     `MineController.anonymity.value = !selected.isLogin`；default → 无。
- 语义结论：同步 type/slot 修改不回滚（last-writer-wins）；after-await 效果由
  revalidate #1/#2 守卫；admission 只是 drain 记账，owner/stamp 才是判定。

## 已实现回归（保留，不改生产）

`test/utils/accounts/account_purpose_set_interference_test.dart`（7 用例，真实 Hive +
受控 adapter + LoginUtils 文档化 seam）：
1. 对照：`set(main)` 完整到达 publish 链（activateBuvidApi → userInfo → historyStatus →
   mirror/publish；issued==3）；
2. 暂停中 selection switch → revalidate #2 失败：零后续请求/零 publish，stamp 仍 current
   （slot 检查是判别性）；
3. 暂停中 same-MID replacement → stamp 失效：零 publish，replacement 继承 types；
4. 暂停中并发完整 `set(main, B)` → last-writer-wins 一致，publish 恰一次，两个 admission
   并存（证明 admission 非独占锁）；
5. 暂停中 `deleteAll` → 零 publish，slots 匿名；
6. `set(heartbeat)` 对照 → anonymity 翻转；
7. 暂停中 heartbeat slot switch → anonymity 不被 stale 效果覆盖。

## 实际证据与 Codex 有限 PASS（测试代码 SHA `eb58d5c`；docs-only SHA `b4ea200`，非测试 SHA）

- **Codex FINAL DISPOSITION（`review-eb58d5c…-codex/REVIEW.md`）：LIMITED PASS，仅上述 7 个
  Dart 用例范围 + 声明的 offline/seam 限制**；明确不闭合 initial Hive await/revalidate #1、
  default purpose 分支、全部 writer/consumer/admission-drain 组合、Native purpose CAS、
  B2e-2b bridge/frozen revision、Block3/4/5、生产 authority 与 whole P05。R50 收窄口径
  （docs-only `b4ea200`）同时获接受；`b4ea200` 非测试代码 SHA，实际测试 SHA 为 `eb58d5c`。
- `sourceSHA=workflowSHA=eb58d5c`：release
  [38891705943](https://github.com/Justintunsday/Piliglass/actions/runs/38891705943)
  SUCCESS5/5 与 preview
  [38891709617](https://github.com/Justintunsday/Piliglass/actions/runs/38891709617)
  SUCCESS4/4（均首次尝试、无 job 重跑）。
- 实际 account strict analyze No issues/runtime 72/**322** All tests passed（全部 7 个新
  `Accounts.set` 用例实际执行 157→164）；九强制 outcome 全 success、BUILD SUCCEEDED、
  Runner.app 109.1MB、执行 Aether FFmpeg 先于 media-kit 验证；native 109/44 负例/
  1 synthetic/40 staging/245(68+177)/292/51；producer 8/10/2；91 raw Git blob 89 match+
  2 声明 pubspec；golden live `5c30f83b…`/hive `71ed239c…`；preview 20 passed
  （nav 441.056s + image 169.513s + account 206.278s + player 101.689s）；home 11/11
  token/PID、22 streams、last-row 4395==bottom、压力 `failures[]`；Mac QA 45/45（1.65s）。
- 精度（R50 保留）：该组测试证明的是 writer/state-machine 时序；不证明 headers/Cookie/
  auth pipeline、Native CAS、真实 WK/浏览器副作用或真实账户；mirror/publisher 为既有
  seam（计数 admission→effect），historyPause 用真实 cache；adapter issued 计数证明
  "未发起外部调用"；并发未决 future 只说明重叠，未直接断言 2 个 live admission/token
  释放/drain；main/heartbeat 已测、default purpose 未测；只覆盖 post-activation/#2，
  未覆盖初始 `onChange` await/#1。

## 边界与验收

- 本组（收窄后）已获 **Codex 有限 PASS**（仅 Dart 7 用例范围；`review-eb58d5c…` FINAL
  DISPOSITION）；不得以本组声称 Native purpose CAS 或 whole Block1/P05 闭合。
- Native `applyPurposeChange` CAS 行维持 OPEN；其 proposed plan 已按 R51 修正（真实窗口 +
  最小 seam），处于计划复核门；实现为单独的新代码 SHA，需 BOTH workflows + Codex 独立复审；
  本 docs-only 轮不实现、不派发 CI、不改生产/测试。
- 四 flag false、Flutter/Dart fallback、Aether 独立、不读/改 `youtube/`、无 UI visual/
  真实账户写/auth/captcha/设备伪造；保留全部历史失败（127 六红、8d 两失败、R48/R49 实际
  记录）与 c9/a50 已接受 limited 组。
