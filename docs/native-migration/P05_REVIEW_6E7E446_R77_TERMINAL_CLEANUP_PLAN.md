# P05 focused repair plan（R77；依据 6e7e446 source-preflight review）：S1 harness terminal cleanup 与 early-terminal wait 修复

2026-10-17（Asia/Hong_Kong）。依据
`build/native-migration/review-6e7e446559975688f8581cf95c09121f1eb73286-codex/REVIEW.md`
（SOURCE PREFLIGHT，CHANGES_REQUESTED，R77）。本文件在编辑前保存：只做 test-only 的 minimal
repair + 受控回归；不改生产/Swift/MethodChannel/UI/workflow/Python；不重开 297/R70–R76；
无本地 Dart SDK（仅静态审阅，不声称实际运行）。

## 0. 保留的正面方向（不改）

- 唯一 authorized 新测试文件与 plan clarification；account sweep/fatal-infos/source ledger/trigger
  路径；helper await 真实 terminal grant、abort 时先 end 再抛 typed abort、withSession finally 保留
  failure identity；case B 双 retained future 的 first/second end；真实 install/selection 投影、
  capture busy vs snapshot service `snapshotChanged`、public restore fixture；无
  unknown/Native/authority/global-freeze 声明。
- 既有 10 个用例、断言与独立 oracle 全部保留；新增用例数只在未来 CI 实际观测。

## 1. R77 三个控制流漏洞（源码可见；非未运行的 Mac 失败、非生产 bug）

1. **queued grant cleanup 安装过晚（C1）**：`await harness.withSession(...)`（271–278）先于外层
   try/finally（279/287）。body 注册第二个获取后再 `expect(isMaintenanceActive, true)`；若该断言
   或早期 body 错误抛出，withSession 先 end FIRST → SECOND 被授予，而测试在 cleanup 安装之前
   退出。第一个测试的 verification lease（185–188）同样在任何 finally 之前断言。
2. **capture 失败阻止 held lease 释放（E）**：finally（374–381）`await captured; lease.end();`——
   若 capture 以 terminal error（unexpected codec/busy/stale/checkpoint 失败）结束，await 抛出并
   跳过 `lease.end`；且 `captured` 在 writer 断言期间没有即时错误观察者。
3. **restore phase 等待在 early terminal error 后挂起（H）**：只 `await port.started.future`（458）；
   若 restore 在 `writeLegacyImport` 之前被拒绝（invalid target/candidate/fixture regression），
   `started` 永不完成，finally（477）永不可达——cleanup finally 无法解决一个到不了的 await。

文件头部与实现的 "every-failed-assertion cleanup" 声明在这些漏洞修复前不受支持；修复后由 §3 的
受控回归支撑。

## 2. Minimal test-only 修复

- **owning scopes（R77-1）**：把 `withSession` 的 await 与全部 verification 包进 try/finally；
  直接获取的 verification lease（A 的复获取、A2 的 closed token、C1 的 queued second）在 `finally`
  中 end（`queued != null` 守护，避免 masking 原始失败）。C2/a1/a2 同构。
- **immediate handled observer + nested try/finally（R77-2）**：新增 `_observeTerminal<T>`（`then`
  即时挂接、terminal error 即时 handled、返回的 future 可 await 且不抛，成功路径仍直接 await 原
  future，terminal error 绝不按 success 报）。在 capture 创建处立即挂接；E 的 finally 使用 nested
  `try { await captured; } finally { lease.end(); }`（token 与 capture outcome 独立；真实 capture 的
  error identity 保留）。预期失败的 e2 用 observer drain，不把已断言的预期错误重新抛出为失败。
- **phase-or-terminal（R77-3）**：新增 `_awaitStartedOrTerminal({started, terminal})`——只观察真实
  future：`started` 先完成 → 正常返回；`terminal` 先以错误完成 → 以 `Error.throwWithStackTrace`
  抛出**同一错误对象**与原始 stack；`terminal` 先以成功完成 → 抛 phase violation。不伪造 started、
  不静默接受 early 失败、不增加 timeout/sleep。H 的 try 使用该 helper；finally 无条件补
  `port.release.complete()` 并 await observer drain；成功路径仍直接 `await restore`。
- 头部注释按上述语义精确化。

## 3. 受控回归（forcing 曾被跳过的路径；exact identity/type）

- **a1 early callback failure**：第二个获取注册后、session await 完成前同步抛出；断言
  `same(failure)`，queued SECOND 在 finally 中 end；idle/`admittedCount == 0`/后续 admission 正常。
- **a2 failing verification**：第二个获取注册后、barrier 持有期间受控失败的 `expect`；断言
  `TestFailure` 浮出，cleanup 同 a1（不吞为 pass）。
- **e2 capture checkpoint terminal failure while maintenance held**：checkpoint 返回
  `Future.error(checkpointFailure)`；断言 `same(checkpointFailure)`、lease 正常 end、idle/
  `admittedCount == 0`/后续 admission；无 gate/observer 残留。
- **h2 real public restore pre-port rejection**：public fixture 提供同一 candidate 两次 → 真实
  API 在写阶段前以 `ArgumentError('Captured restore requires fresh unique candidates')` 拒绝
  （无私有状态改动）；断言 exact type/message、`port.started` 未完成、无 window 残留、target 仍
  可用（capture verify 成功）。
- 全部 cleanup 在 finally；无 timer/sleep/timeout；不吞失败断言为 pass。

## 4. 边界与验收

- 无生产/Swift/MethodChannel/UI/workflow/Python 改动；account sweep/fatal-infos/trigger/source
  ledger/export128/bootstrap238/6+6/180-90-240/四 flag 不变；297/R70–R76 不重开。
- 流程：实现 → 静态审阅（无本地 Dart SDK）→ commit/push NEW code SHA → **STOP BEFORE CI**
  → Codex SOURCE PREFLIGHT → 通过后同 SHA 双 workflow 各一次 → 实际证据独立复审（仅有限验收）。
