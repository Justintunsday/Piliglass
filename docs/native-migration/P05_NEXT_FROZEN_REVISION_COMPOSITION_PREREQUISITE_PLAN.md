# P05 下一组契约计划（docs-only，R74–R76 修订版；Codex CONTRACT review）：frozen-revision composition 前置——writer/admission 清单、session barrier 未来契约与 bounded test-only 依赖切片 S1

2026-10-17（Asia/Hong_Kong）。本修订依据两份 Codex review：

- `build/native-migration/review-2970fc5ea23caf7f93a3a4b63c73671027f9c59d-codex/REVIEW.md`
  FINAL DISPOSITION（LIMITED PASS exact `2970fc5`）的 "Next authorized work"；
- `build/native-migration/review-e78560914e22033b9ec2621e25c74ce663077501-codex/REVIEW.md`
  （CHANGES_REQUESTED，R74–R76）：R74 执行路径、R75 非重复的 test-local
  acquisition/capture/restore 用例、R76 未来契约范围/清单/所有权精度，以及记录生产增量更正。

**本文件只保存修订后的契约计划（docs-only，不实现、不派发 CI）**；通过 Codex CONTRACT review
后才实施其中冻结的小切片 S1。297 的 LIMITED PASS 仅覆盖 bounded create-only bootstrap +
两阶段真实消费者，**不重开**；本计划的 §2/§3 是**未来 OPEN 设计要求**（不是已批准的生产协议、
不是 binding 实现承诺）；S1 不由此获得任何生产写协议或 authority 授权。

## 0. 已验收事实与硬边界（297；不重开）

- 已验收：schema2 create-only CURRENT-pointer-ABSENT bootstrap（下层固定 kind 常量 +
  原 enum 字面 case + 真实冷加载识别）、raw ANY / correlated exact-UUID 语义保留、
  isolated bootstrap→adoption→pinned schema3 export、driver-local association、
  **两条独立 retained 的真实 Swift→Dart 消费记录**、post-ALL 六产物 hash 复核、R70–R73
  修复与回归。实际证据：release `38954606514` 5/5 attempt1、preview `38954610956` 4/4
  attempt2（唯一失败 image job 单次重跑；attempt1 orientation timeout 与 artifact 保留）。
- 记录生产增量更正（review 指出）：实际 delta 为 `ef313a1` **引入** bootstrap 生产面；
  `4a12858` 除 driver/QA 外**另含 26 行 staging 生产修复**（R72 bootstrap post-await 取消
  排序 + pre-journal checkpoint；非新 API、无 authority 变更）；`2970fc5` 为 test/driver/QA-only。
  已同步更正 `PROGRESS.md` 首条；不影响 297 的验收范围，无需新 CI。
- 保留边界（binding）：CURRENT-pointer-absent ≠ virgin namespace/ABA/highwater reset 授权；
  staging journal 是 durable namespace fence，**不是**全局生产 writer admission/authority
  fence；不确定移除可实际缺席（非“必然保留”承诺）；同进程 Keychain 新实例 ≠ process kill；
  离线 consumer/test-only association ≠ 真实 frozen-revision Dart→Native→Dart composition；
  无生产 bootstrap caller / authority 激活。

## 1. Writer/admission 现状清单（源码核对，2026-10-17；**分类清单，不声称“全部写者”**）

### 1.1 唯一共享 admission/drain 门

- `AccountWriteBackCoordinator`
  （`lib/services/native_accounts/account_write_back_coordinator.dart`）：
  - `tryAdmit()` :76-82 —— frozen/maintenance/closed 时返回 null；调用方必须零写、不得注册；
  - `freeze()` :87-93 —— 拒新 admission、drain 已 admitted；**无 thaw API（终止性）**；
  - `quiesce()` :100-105 —— 只等待 drained，**允许新 admission**（非排他段）；
  - `beginMaintenance()` :111-128 —— 排他：拒绝后续 admission、先 drain 已 admitted、返回
    一次性 token；已有 holder 时排队等其 end；`closed` 返回 null；
  - `_endMaintenance` :130-139 —— `end(permanent:false)` 仅恢复 admission，
    `end(permanent:true)` 关闭；**不触碰 `_frozen`**（end(false) 不清除既有 freeze）；
  - `_release` :141-151 —— operation token 一次性释放；计数归零后唤醒 drain waiters。
- token 语义：
  - `AccountWriteBackOperation.release()` :19-23 —— 恰一次生效（重复 no-op）；
  - `AccountWriteBackMaintenance.end()` :40-44 —— 恰一次生效；**abandoned（获取后不 end）会
    永久占用 `_maintenance`**，后续 waiter 只能等 holder；closed 也由 holder end 决定；
  - 生产实例 `accountWriteBackCoordinator` :154-157（测试可注入实例）。
  - admission token 只是生命周期凭证：**不是**所有权、**不是** identity、**不是** authorization。

### 1.2 协调器覆盖的真实写链（admission owner）

- `Accounts`（`lib/utils/accounts.dart`）：`refresh` :246-275；install/import 路径
  :347/:377/:419；set/selectTemporarily 等 :465-469/:529/:547（均 `tryAdmit` + finally
  release；frozen 抛 `StateError('Account write-back is frozen')`）。
- `LoginAccount.delete`（`lib/utils/accounts/account.dart` :92-108）与另一写链 :199-203。
- `LoginUtils.setWebCookie`（`lib/utils/login_utils.dart` :119-148，WK/WebView cookie mirror；
  `_runWebCookieExclusive` 内 stale-owner 逐步检查）、`onLoginMain` :150+、第三写链 :208+。
- `request_utils.dart` :50-54。
- `AccountManager.onResponse→_saveCookies`（`lib/utils/accounts/account_manager/account_mgr.dart`
  :145-168，admission 在 :243）与 `onError` :170+（Dio 响应写回）。
- Native HTTP lease `finish`（`lib/services/native_http/native_http_request_lease_service.dart`
  :313-339）：`tryAdmit` 失败 → `revoked` 零写；finally release；lease 表清理独立于 admission。

### 1.3 maintenance owner（经同一协调器 token 制度管理；**不是**未协调 writer）

- `Storage.compact()`（`lib/utils/storage.dart` :112-132，`beginMaintenance` +
  `end(permanent:false)`）与 `Storage.close()` :134-153（`end(permanent:true)`）：
  它们**确实**走 `beginMaintenance`，是 maintenance owner；与任何未来 session 共用同一个
  `_maintenance` 槽位（生产单例），这是既有协调关系，不是 bypass。已覆盖：
  `test/utils/accounts/account_maintenance_gate_test.dart` 'compact waits for the admitted
  write chain before touching Hive'（:148）。

### 1.4 已知公开同步 bypass 面（**非穷尽**；保持 OPEN；不得称“全部写者”）

- `Accounts.notifyCookieMutation` :173-175：公开同步、无 admission 检查；现有 caller
  （`account_mgr.dart` :247/:260、`native_http_request_lease_service.dart` :324）位于已
  admitted 链内，但任何直接调用都可在 admission 之外 bump revision。无独立覆盖，OPEN。
- `Accounts.revokeCredentials` :177-185：公开同步；caller：reconcile :233、`_beginInstall`
  :294、`_failInstall` :331、`deleteAll` :486、`LoginAccount.delete` :102。
  直接外部调用 = 无协调的所有权撤销。OPEN。
- `Accounts.beginAnonymousReset` :187-202 / `completeAnonymousReset` :204-213：公开同步
  建造/完成对；唯一 caller 是 `AnonymousAccount.delete`（`account.dart` :208/:214，admission
  内、pair 内部一致）；直接外部误用可在协调之外 revoke/activate anonymous 所有权。OPEN。
- 可变直接状态：`LoginAccount.activated` 公开可变（`account.dart` :63）；`type` 可变集合；
  `cookieJar` 内容可被 raw 修改（既有 `native_account_live_memory_capture_test.dart` :128
  证明 verifyCurrent 会拒绝，但 writer 本身未协调）；`Accounts.account` 是公开 Box（可绕
  admission 直接 put/delete；capture 的 `invalidStoredOwner` 只检测部分形态）。OPEN。
- `Accounts.ownsCredentials(AnonymousAccount)` :158-161：名义上的读会执行
  `_requestState.activate(value)`——**读带 tracker 副作用**，不得当纯读。OPEN。
- 以上每条均由未来生产契约（§2）负责，S1 不收口、不验证。

### 1.5 初始化与未收口的直接状态路径（保持 OPEN）

- `Accounts.init()`（`lib/utils/accounts.dart` :215-223）：`Hive.openBox('account')` +
  `_reconcileStoredOwners()`——**不经** coordinator；首次可用性（原 53 item8 的
  “初始 Hive await #1”）仍未关闭；默认实例/openBox 顺序保持 OPEN。
- captured restore/recovery 专有窗口（`accounts.dart` :37-39/:596-698）：
  `_capturedRestoreOperation`/`_capturedRecoveryOperation`/`_capturedRestoreFailed` 任一非空时
  窗口 fail closed（`ownsCredentials` false、capture 抛 `busy`，见 §4.3 case H 的 public 复现）。
- WK/WebView cookie 存储本体（flutter_inappwebview `web.CookieManager`，`login_utils.dart`
  :65/:89）与 LinuxCookieManager 在 Hive 之外；仅 `setWebCookie` 写链经 admission。
- 其余 Block1 写者（默认 purpose、全局 high-water、legacy import 等）：本计划不收口。

### 1.6 capture 面（只读、乐观）

- `NativeAccountLiveMemoryCaptureService.capture()`
  （`lib/services/native_accounts/native_account_live_memory_capture.dart` :11-16）=
  `Accounts.captureLiveMemoryShadow()` → checkpoint await → `verifyCurrent()`；
  `verifyCurrent`（`account_live_memory_shadow.dart` :27-38）是 **recapture+compare 的乐观复核**，
  注释明确 “Equal endpoints do not prove writers were frozen during an await”。
  **不是 lease、不冻 writer、不阻止新 admission、不阻止 writer 在 await 后完成。**
- `NativeAccountSnapshotService`（`native_account_snapshot_service.dart`）：`_capture`/`_verify`
  :97-159（typed `snapshotChanged`）、`selectionSnapshot` :47-52、`stagingExport` :56-71；
  `authorityEpoch` :22 与 `_tokens` Expando :25 是**运行时 tracker namespace**（进程生命周期）。
- 错误映射分离（精确，不得互换）：capture 面抛 `AccountLiveMemoryShadowException`
  （`'busy'`/`'snapshotChanged'`/…）；snapshot service 抛
  `NativeAccountSnapshotException`（`'snapshotChanged'`/`'unavailable'`/…）。
- namespace 分离（binding）：runtime tracker（authorityEpoch/ownerToken/revision）≠ durable
  pointer/labels（schema3 durableIdentity、transactionID、generation high-water）≠ authorization；
  三者不得互相替代；capture 复核不得作为 self-oracle。

## 2. 未来 session barrier 契约（**OPEN 设计要求**；不是已批准的生产协议）

未来 production session 序列：capture → P0 bootstrap → P1 adoption/noop → pinned export →
Dart validation。以下是该 future 的 OPEN 设计要求清单（尚未批准、尚未实现、S1 不接线）：

1. **屏障必须在 capture 之前开始**，并在 validation（必要时到 publication）期间保持；
   `capture()` 的 `verifyCurrent()` 只是乐观复核，不是 lease，不提供任何写者保证。
2. 未来契约必须清点并覆盖**全部真实 writer**（含 §1.4 的同步 bypass 面），不能只覆盖
   coordinator admission 路径。
3. **definite failure 的 admission 释放**与 **durable unknown/global retained owner** 是两种
   不同状态：`end(permanent:false)` 只恢复 admission，**绝不**等于 thaw、**绝不**释放
   unknown/journal fence/全局 retained authority。
4. 正常路径绝不 auto resolve/clear/replay unknown；显式 isolated resolution 是单独 review
   过的恢复操作。
5. 每段 await 成功后、解释结果前检查取消/owner（Dart 侧 `isCurrentRequest`/stamp；Swift 侧
   沿用 297 已验收的 `.absent` post-await `checkCancellation` 语义）。

现有 API 的既有边界（源码事实，保持 binding）：`freeze()` 无 thaw（终止性）；`quiesce()`
允许新 admission（非排他）；`beginMaintenance()` 是**现有 API 中唯一排他原语**——这一事实
只说明 S1 测试使用它，**不构成**“maintenance-only 已足够构成生产 frozen-revision session”
的结论；`end(false)` 不清 `_frozen`、不触碰 journal；abandoned acquisition 泄漏 token
（§4.3 case B 的 test-local 复现）。

**S1 的 lifetime 边界（明确）**：S1 只用 test-local coordinator/capture 回调验证 FUTURE
caller 的清理义务；**不声称/不实现** unknown Native retention、全局 frozen revision、真实
bootstrap/handoff、release/resolve authority；§4 的 test-local helper **不是**生产 session
API、不是 lease、不是 authorization。

## 3. 失败/取消/清理状态机（未来契约 OPEN 设计要点；S1 只执行标注的 test-local 子集）

1. **definite failure**（`bootstrapRefused`/`invalidBootstrap`/`staleTransaction`/
   `invalidRecoveryJournal` 等 typed 拒绝）：零持久写（或按 297 已验证的 candidate 清理
   复位），session 中止并向上传递 typed error；不得重试性“修补”。——**未来 OPEN；S1 不涉及**
   （S1 无 Native 回调、无持久写）。
2. **persistent unknown**（`publicationUnknown`，journal 保留）：session fail closed；
   durable evidence 保留；不 replay/不伪造 receipt/不自动 resolve；只有显式 isolated
   resolution 可以分类并清除。——**未来 OPEN；S1 不可测试**（无 Native unknown）。
3. **pre/post-successful-await cancellation**：pre-await 取消零 IO；post-await 取消在结果
   解释前抛出；不得把已完成的成功读结果重新解释为 typed 失败，不得在 verified commit 后
   追溯取消。——生产语义**未来 OPEN**；S1 仅验证 test-local abort 信号在 acquisition 边界的
   行为（§4.3 case A）。
4. **terminal acquisition cleanup**：throw/cancel/dispose 路径都释放 operation token
   （finally、恰一次）；maintenance token 由 holder 恰一次 end；“另一个表被清空”不构成释放。
   ——S1 执行 test-local 子集（case A/C/D 经 helper finally）；**S1 不把该子集推广为生产
   释放协议**，也不覆盖 operation token 的既有生产语义（那由 §1.2 的现有链负责）。
5. **typed zero-effect**：拒绝路径零 effect（capture/busy、freeze 的 StateError、lease 的
   `revoked`、validation mismatch），且不与 unknown 保留语义混淆。——S1 验证其中 capture
   busy 与 frozen writer 两个子集。

## 4. S1（本计划唯一选定实现范围）：test-local session ownership/acquisition harness

### 4.1 文件与执行路径（R74；精确命名，无“如”、无隐含的新测试发现）

- 文件：**`test/utils/accounts/account_composition_session_contract_test.dart`**
  （必须 `_test.dart` 后缀）。
- 执行与证据路径（全部为**既有** wiring，无需新增）：
  - `ios.yml` 的 `group-account-dart` 步骤
    `flutter test --no-pub --reporter expanded test/utils/accounts/`（:330）→
    `build/account-request-state/flutter-test.log`（expanded reporter 逐条列出用例名），
    随 `account-request-state-contracts` artifact 上传——这是该文件的**实际执行证据**。
  - `dart analyze --fatal-infos … test/utils/accounts/`（:328）→
    `build/account-request-state/analyze.log`（fatal-infos 把关）。
  - 触发：workflow path filter `test/utils/accounts/**`（:36/:88）。
- 不改动：production/MethodChannel/Swift/UI/CI 文件；envelope pipeline 的 `PRODUCERS`
  （仅两个 envelope 文件，`tool/check_native_account_envelopes.py` :20-23）与
  `EXPORT_CONSUMER`（仅 services 单文件，:151-155）→
  **export128/bootstrap238/consumer 6+6 与全部预算不变**；S1 文件既不是 producer 也不是
  consumer，不进入六产物 hash ledger。
- account sweep 在 envelope pipeline **之前**运行（:151-152 注释）：S1 必须完全 offline
  自包含（`AccountTestStorage` + 本地 fixture），**不得**依赖 Swift-produced fixture 或
  消费者输入，避免把需要新 fixture 的用例拉进早期 account 阶段。

### 4.2 test-local helper（非生产 API）

- `_SessionAbortSignal`：以 `Completer<void>` 承载；`bool get isAborted` / `void abort()`。
  Dart Future **不可取消**：信号**只在** coordinator 的真实 await 边界返回后检查；绝不
  包装/分离 coordinator 自己的 future、绝不伪造 cancellable Future。
- `_SessionAbort implements Exception`：typed abort 结果。
- `_SessionLease`：一次 maintenance token 的独占所有权句柄。`void end()` 恰一次生效、幂等，
  只调用 `end(permanent:false)`；不触碰 `_frozen`/`_closed`、不触碰 journal/Native 状态。
- `_SessionOwnershipHarness(AccountWriteBackCoordinator coordinator)`：
  - `Future<_SessionLease> acquire({_SessionAbortSignal? abort})`——`await beginMaintenance()`；
    closed → `StateError`；token 授予时若 abort 已触发：**先** `lease.end()`（terminal
    ownership cleanup）**再**抛 `_SessionAbort`；
  - `Future<T> withSession<T>(Future<T> Function(_SessionLease lease) body)`——`try/finally`
    保证 success/throw 路径 `end()` 恰一次。
- 所有权语义：获得 lease = 排他占用 maintenance（拒绝新 admission）；end 后恢复 admission
  （freeze/closed 除外）；**不等待**的 `beginMaintenance()` 会永久泄漏 `isMaintenanceActive`
  （无公开 lever），因此 helper 必须 await 并履行 abort/throw 路径的 end 义务。

### 4.3 判别性 NEW 用例（每条含阶段入口/信号/精确 oracle；全部用真实 coordinator/capture）

- **A. abort while acquisition pending → helper 结束已授予 token → acquire-after-abort 正常**：
  `admitted = coordinator.tryAdmit()!`；`pending = harness.acquire(abort: signal)`（调用后
  **同步**可断言 `isMaintenanceActive == true`、`tryAdmit() == null`，排他性先于 drain）；
  `signal.abort()`（token 尚未授予）；`admitted.release()`（drain 完成 → token 授予）；
  `expectLater(pending, throwsA(isA<_SessionAbort>()))`；断言 `isMaintenanceActive == false`、
  `admittedCount == 0`（无永久泄漏）；随后 `lease = await harness.acquire()` 成功、
  `tryAdmit() == null`，`lease.end()` 后 `tryAdmit() != null`。
- **B. abandoned pending acquisition 泄漏（危险面，有意 confined）**：`admitted =
  coordinator.tryAdmit()!`；`unawaited(coordinator.beginMaintenance())`（放弃等待、不 end）；
  `admitted.release()`；显式微任务边界后断言 `isMaintenanceActive == true`、
  `tryAdmit() == null`、`isClosed == false`；第二个 `beginMaintenance()` 的完成标志保持
  false（无公开 lever 可恢复）。只使用 isolated coordinator 实例；无 timer、无共享静态状态；
  实例随测试丢弃。
- **C1. success 后 queued second acquirer 继续**：`withSession` 的 body 内启动
  `second = harness.acquire()`（`_maintenance` 为 true，waiter 同步注册）；body 正常结束 →
  `lease2 = await second` 获得 token；持有时 `tryAdmit() == null`；`lease2.end()` 后
  `tryAdmit() != null`。
- **C2. throw 后如 C1**：body 抛 `StateError('synthetic session failure')`；
  `expectLater(session, throwsA(same(failure)))`；finally end 使 waiter 继续；后续断言同 C1。
- **D. freeze preserved on cleanup**：`await coordinator.freeze()` 后，分别以 success 与
  throw 两种 `withSession` 结束；每次断言 `isFrozen == true`、`isMaintenanceActive == false`、
  `tryAdmit() == null`（end(false) 不清 freeze；throw 路径也不清）。
- **E. 屏障在 capture 前开始：持会期内真实 admitted mutation 零效果，而乐观 capture 正常
  完成**：先 `await Accounts.installCredentials(_account(940000), coordinator: coordinator)`；
  `lease = await harness.acquire()`；以 gated checkpoint 启动
  `NativeAccountLiveMemoryCaptureService(checkpoint: gate).capture()`；窗口内：
  `await expectLater(Accounts.installCredentials(_account(940001), coordinator: coordinator),
  throwsA(isA<StateError>().having((e) => e.message, 'message', 'Account write-back is frozen')))`，
  `expect(() => Accounts.selectTemporarily(AccountType.video, _account(940002),
  coordinator: coordinator), throwsA(isA<StateError>()))`；独立 oracle：`Accounts.account.get('940001')
  == null`、`identical(Accounts.get(AccountType.video), AnonymousAccount())`、`requestRevision`
  不变；放行 checkpoint 后 capture 正常返回且 `storedOrder` 长度为 1；`lease.end()`。
  （精度：只证明 coordinator 路径被屏障覆盖；**不**证明 §1.4 bypass 面被覆盖。）
- **F. capture 乐观：checkpoint 内合法 admitted install 使 verifyCurrent 抛
  snapshotChanged**：install `940010`；`candidate = Accounts.captureLiveMemoryShadow()`；
  gated checkpoint 启动 `capture()`；窗口内 `await Accounts.installCredentials(_account(940011),
  coordinator: coordinator)`（合法 admission；断言 `coordinator.isFrozen == false`）；
  独立 source-state oracle：`Accounts.account.get('940011')` 非 null、`requestRevision` 增长、
  candidate 的 `storedOrder` 长度仍为 1（captured bytes 未被伪改）；放行后
  `expectLater(pending, throwsA(isA<AccountLiveMemoryShadowException>()
  .having((e) => e.code, 'code', 'snapshotChanged')))`。
- **G. capture 乐观：checkpoint 内合法 admitted selection 变化（无 Hive 字节写）**：
  install `940012`；candidate；`Accounts.selectTemporarily(AccountType.video, account,
  coordinator: coordinator)`；独立 oracle：`identical(Accounts.get(AccountType.video), account)`
  为 true，而 candidate `['selections'][AccountType.video.index]` 仍为 0；放行后同 F 的精确
  `AccountLiveMemoryShadowException('snapshotChanged')`。
- **H. public restore 窗口（R75 row8 修正）**：镜像
  `account_bound_reader_capture_test.dart` 的已验收 recipe——`_prepareEmptyTarget()` +
  `AnonymousAccount().type.clear()`；`restoreEmptyCaptured(...)` 配 gated
  `AccountInstallPersistencePort`（`started`/`release` Completer）；`await port.started.future`
  后窗口打开：
  - `expect(Accounts.captureLiveMemoryShadow, throwsA(isA<AccountLiveMemoryShadowException>()
    .having((e) => e.code, 'code', 'busy')))`；
  - `await expectLater(NativeAccountLiveMemoryCaptureService().capture(),
    throwsA(isA<AccountLiveMemoryShadowException>().having((e) => e.code, 'code', 'busy')))`；
  - `await expectLater(NativeAccountSnapshotService().selectionSnapshot(),
    throwsA(isA<NativeAccountSnapshotException>().having((e) => e.code, 'code',
    'snapshotChanged')))`——两个服务的错误映射不同，不可互换；
  - 零效果：`requestRevision` 不变、`port.release.isCompleted == false`（窗口保持打开）；
  - `finally` 中（若未完成）`port.release.complete()` 并 `await restore`——失败断言路径也必须
    关闭窗口；窗口关闭后 `Accounts.captureLiveMemoryShadow().verifyCurrent()` 成功（busy
    终止性清除）。
- **错误类型（精确，不得互换）**：capture = `AccountLiveMemoryShadowException`
  （`'snapshotChanged'`/`'busy'`）；snapshot service = `NativeAccountSnapshotException`
  （`'snapshotChanged'`）；frozen writer = `StateError('Account write-back is frozen')`。

### 4.4 已覆盖基线映射（**不重复实现、不假装新增**）

| 旧草案行 | 已覆盖处（既有已验收测试） |
| --- | --- |
| freeze 拒绝新 admission / terminal | `account_write_back_coordinator_test.dart` 'admission is one-shot idempotent and freeze rejects new operations'（:55） |
| freeze 全链 drain / 多重 waiter 恰一次 | 同上 'freeze waits for every admitted chain and each waiter completes once'（:72） |
| throw 链 finally release | 同上 'a throwing chain releases exactly once in finally'（:98） |
| quiesce 允许新链 / 延长等待 | `account_maintenance_gate_test.dart`（:67/:78） |
| maintenance 排他 + end(false) 恢复 + last-release 边界 | `account_maintenance_gate_test.dart`（:96/:111） |
| permanent close | 同上（:130） |
| maintenance 不清 freeze | 同上（:138） |
| capture busy（pending install / anonymous reset） | `native_account_live_memory_capture_test.dart`（:111） |
| raw cookie mutation + gated checkpoint 拒绝 | 同上（:128） |
| frozen SET/selectTemporarily/refresh/install/delete 零效果 | `account_write_barrier_test.dart`（:162/:178/:194/:209/:223/:325/:339/:356） |
| already-granted holder 不 end 时后续 waiter 等 holder | `account_maintenance_gate_test.dart`（:111 的 last-release 边界）；泄漏文本见 §2 |

S1 新增的只有：pending acquisition 被 abort 的清理（A）、pending acquisition 被放弃的泄漏
危险面（B）、helper 的 success/throw + queued second（C1/C2）、freeze 在清理路径保持（D）、
屏障覆盖真实 admitted mutation（E）、乐观 capture vs 合法 admitted mutation 的独立 oracle
（F/G）、public restore 窗口的 busy/snapshotChanged 映射与终止性清理（H）。

### 4.5 清理纪律与本地验证

- 每个 lease 在 `finally` end；每个 gated checkpoint/port 在 `finally` 放行并 drain
  （**包括失败断言路径**）；case B 的有意泄漏只限 isolated coordinator 实例，无 timer、
  无共享静态状态。
- 判别只允许显式 Completer/微任务边界（沿用既有 `await Future<void>.value()` 风格）；
  **禁止** sleep/elapsed-time 非完成 oracle、禁止扩大任何 timeout。
- 本地验证：无本地 Dart SDK，仅静态审阅 + 逐条核对 API/错误类型；mock/静态不得替代 CI。

### 4.6 验收流程（获批后）

1. 实现 S1 → commit/push 新 code SHA → **STOP BEFORE CI for Codex SOURCE PREFLIGHT**；
2. 通过后同 SHA 各派发 `ios.yml`/`ios-home-preview.yml` 一次；
3. release 的 `build/account-request-state/flutter-test.log` 实际含新用例（实际计数以 CI
   观察为准，不预写）；Codex 独立实际证据复审 → 有限验收。
- **明确不含**：任何 production caller、Dart→Native session、MethodChannel、Swift 改动、
  global freeze caller、authority 激活；test-local helper **不是**生产 session API/authorization。

## 5. 后续依赖（保持 OPEN，未获实现授权）

- S2（未来）：Swift 侧 session-prerequisite 只读组合 fence（session 级 preflight：原子读
  pointer+schema+journal 状态、unknown retain 契约），需独立 REVIEW 批准后才设计实现。
- S3（未来）：真实 frozen-revision Dart→Native→Dart composition（MethodChannel/binding，
  capture→P0→P1→export→Dart validation 全链，typed zero-effect mismatch）。
- §2 的未来生产 session barrier 契约本身仍待独立 review 后才可设计/实现；S1 不预设其结论。
- 与全量 production composition 一起保持 OPEN：startup apply、nonempty-target reverse/revert、
  GC、handoff/authority 激活、process-kill/设备清单、Block3/4/5 其余项。

## 6. 验收顺序

1. 本 docs-only 修订先经 Codex CONTRACT review（返回本文 SHA；未获批前不实现 S1）。
2. 获批后：实现 S1 → 本地可为者仅静态/如实标注 → commit/push 新 code SHA → STOP BEFORE CI
   for Codex SOURCE PREFLIGHT → 通过后双 workflow 各一次 → Codex 独立实际证据复审 → 有限验收。
3. 全程保留：原 P05_BRIEF 范围、四 flag false、Flutter/Dart fallback、Aether 独立、
   no YouTube（含读取）、no UI visual、no auth/captcha/真实账户写、no unknown replay/fake device、
   不弱化断言/预算/门；不重开 R70–R73/297/6b/318。
