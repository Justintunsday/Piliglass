# P05 下一组契约计划（docs-only；Codex CONTRACT review）：frozen-revision composition 前置——writer/admission 清单、session barrier 生命周期与 bounded 测试依赖切片

2026-10-17（Asia/Hong_Kong）。依据
`build/native-migration/review-2970fc5ea23caf7f93a3a4b63c73671027f9c59d-codex/REVIEW.md`
FINAL DISPOSITION（LIMITED PASS exact `2970fc5`）的 "Next authorized work"。
**本文件只保存下一组契约计划（docs-only，不实现、不派发 CI）**；通过 Codex CONTRACT review
后才实施其中冻结的小切片 S1。297 的 LIMITED PASS 仅覆盖 bounded create-only bootstrap +
两阶段真实消费者；本计划中的任何新 API/协议都**未**因该 PASS 获得实现授权，也不得从该
PASS 推导任何全局写协议或全局保证。

## 0. 已验收事实与硬边界（297；不重开）

- 已验收：schema2 create-only CURRENT-pointer-ABSENT bootstrap（下层固定 kind 常量 +
  原 enum 字面 case + 真实冷加载识别）、raw ANY / correlated exact-UUID 语义保留、
  isolated bootstrap→adoption→pinned schema3 export、driver-local association、
  **两条独立 retained 的真实 Swift→Dart 消费记录**、post-ALL 六产物 hash 复核、R70–R73
  修复与回归。实际证据：release `38954606514` 5/5 attempt1、preview `38954610956` 4/4
  attempt2（唯一失败 image job 单次重跑；attempt1 orientation timeout 与 artifact 保留）。
- 保留边界（binding）：CURRENT-pointer-absent ≠ virgin namespace/ABA/highwater reset 授权；
  staging journal 是 durable namespace fence，**不是**全局生产 writer admission/authority
  fence；不确定移除可实际缺席（非“必然保留”承诺）；同进程 Keychain 新实例 ≠ process kill；
  离线 consumer/test-only association ≠ 真实 frozen-revision Dart→Native→Dart composition；
  无生产 bootstrap caller / authority 激活。

## 1. Writer/admission 现状清单（源码核对，2026-10-17）

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

### 1.3 协调器之外的写入/门（未收口，保持 OPEN）

- `Accounts.init()`（`lib/utils/accounts.dart` :215-223）：`Hive.openBox('account')` +
  `_reconcileStoredOwners()`——**不经** coordinator；首次可用性（原 53 item8 的
  “初始 Hive await #1”）仍未关闭。
- `Storage.compact()`（`lib/utils/storage.dart` :112-132，`beginMaintenance` +
  `end(permanent:false)`）与 `Storage.close()` :134-153（`end(permanent:true)`）。
- captured restore/recovery 专有状态（`accounts.dart` :37-38/:597-661/:696）：
  `_pendingInstalls`/`_capturedRestoreOperation`/`_capturedRecoveryOperation`/
  `_capturedRestoreFailed` 非空时 capture 抛 `busy`（`account_live_memory_shadow.dart` :58-61）。
- WK/WebView cookie 存储本体（flutter_inappwebview `web.CookieManager`，`login_utils.dart`
  :65/:89）与 LinuxCookieManager 在 Hive 之外；仅 `setWebCookie` 写链经 admission。
- 其余 Block1 写者（默认 purpose、全局 high-water、legacy import 等）：未在本计划收口。

### 1.4 capture 面（只读、乐观）

- `NativeAccountLiveMemoryCaptureService.capture()`
  （`lib/services/native_accounts/native_account_live_memory_capture.dart` :11-16）=
  `Accounts.captureLiveMemoryShadow()` → checkpoint await → `verifyCurrent()`；
  `verifyCurrent`（`account_live_memory_shadow.dart` :25-38）是 **recapture+compare 的乐观复核**，
  注释明确 “Equal endpoints do not prove writers were frozen during an await”。
  **不是 lease、不冻 writer、不阻止新 admission、不阻止 writer 在 await 后完成。**
- `NativeAccountSnapshotService`（`native_account_snapshot_service.dart`）：`_capture`/`_verify`
  :97-159（typed `snapshotChanged`）、`selectionSnapshot` :47-52、`stagingExport` :56-71；
  `authorityEpoch` :22 与 `_tokens` Expando :25 是**运行时 tracker namespace**（进程生命周期）。
- namespace 分离（binding）：runtime tracker（authorityEpoch/ownerToken/revision）≠ durable
  pointer/labels（schema3 durableIdentity、transactionID、generation high-water）≠ authorization；
  三者不得互相替代；capture 复核不得作为 self-oracle。

## 2. Session barrier 生命周期契约（未来 composition 用；本计划只定义设计，不接线）

未来 session 序列：capture → P0 bootstrap → P1 adoption/noop → pinned export → Dart validation。

- **capture() 前后**：capture 本身不提供任何写者保证；checkpoint 期间合法 writer 完成 ⇒
  后续 `verifyCurrent()` typed `snapshotChanged`（零副作用拒绝），这是**预期语义**而非缺陷。
- **session 排他段**：唯一可选 `beginMaintenance()`（拒绝新 admission + drain 已 admitted）。
  - 不得用 `freeze()` 充当 session 屏障：freeze 无 thaw，session 结束后无法恢复 admission；
  - 不得用 `quiesce()`：它允许新写者，不构成排他；
  - 不得把 `end(permanent:false)` 解释为“清除 freeze / 释放 unknown-retained authority”：
    `_endMaintenance` 不触碰 `_frozen`，也不触碰 staging journal/fence；
  - session 在 journal 存在/`publicationUnknown` 时必须 fail closed；**正常路径绝不
    auto resolve/clear/replay**；显式 isolated resolution 是单独 review 过的恢复操作；
  - abandoned acquisition（异常/取消不 end/不 release）永久占用 `_maintenance`/泄漏 admitted
    计数：session 必须 `try/finally`、恰一次 end/release；取消不自动清理；
  - 每段 await 成功后、解释结果前检查取消/owner（Dart 侧 `isCurrentRequest`/stamp；Swift 侧
    沿用 297 已验收的 `.absent` post-await `checkCancellation` 语义）。
- **屏障跨度与证据上限**：maintenance 只覆盖 session 的 Native 调用窗口；它**不**证明
  “全局无其他写者”，也**不**把 journal 缺席/read-only export 成功升级为 global-safe handoff
  证明。Dart validation 失败（key/mid/generation/labels/digest mismatch）必须是 typed、
  **零 effect** 的拒绝：导出为只读、bootstrap/adoption 已完成的 durable evidence 按原样保留，
  不得回溯撤销、不得以“同输入再比较”充当独立 oracle。

## 3. 失败/取消/清理状态机（契约，binding）

1. **definite failure**（`bootstrapRefused`/`invalidBootstrap`/`staleTransaction`/
   `invalidRecoveryJournal` 等 typed 拒绝）：零持久写（或按 297 已验证的 candidate 清理
   复位），session 中止并向上传递 typed error；不得重试性“修补”。
2. **persistent unknown**（`publicationUnknown`，journal 保留）：session fail closed；
   durable evidence 保留；**不 replay/不伪造 receipt/不自动 resolve**；只有显式 isolated
   resolution 可以分类并清除。
3. **pre/post-successful-await cancellation**：pre-await 取消零 IO；post-await 取消在结果
   解释前抛出；不得把已完成的成功读结果重新解释为 typed 失败，不得在 verified commit 后
   追溯取消。
4. **terminal acquisition cleanup**：throw/cancel/dispose 路径都释放 operation token
   （finally、恰一次）；maintenance token 由 holder 恰一次 end；“另一个表被清空”不构成释放。
5. **typed zero-effect**：拒绝路径零 effect（capture/busy、freeze 的 StateError、lease 的
   `revoked`、validation mismatch），且不与 unknown 保留语义混淆。

## 4. NEXT 小切片（本计划唯一选定的实现范围）——S1：Dart composition-session barrier/ownership 契约 harness（test-only，offline）

- **范围**：新增 Dart 测试模块（如
  `test/services/native_accounts/native_account_composition_session_contract_test.dart`），
  只用现有生产类（`AccountWriteBackCoordinator`、`NativeAccountLiveMemoryCaptureService`、
  `NativeAccountSnapshotService` 与既有测试可用 seam）；**零生产文件改动、零 MethodChannel、
  零 Swift 改动、零新 CI 文件**。
- **判别性用例**：
  1. `capture is optimistic not a lease`：checkpoint 内完成一条合法 admitted 写链
     （真实 `tryAdmit`+release）；capture 后 `verifyCurrent()` 精确抛
     `AccountLiveMemoryShadowException('snapshotChanged')`；等值 endpoints 不证明 freeze。
  2. `freeze is terminal and rejects new admissions`：freeze 后 `tryAdmit()==null`；
     已 admitted 链 release 后 drain 完成；无恢复路径（注释/API 检视记录，不发明调用）。
  3. `quiesce admits a new chain while draining`：等待期间新链被 admitted 且 drain 必须等其
     release 完成。
  4. `beginMaintenance is exclusive and end(false) resumes`：持 token 时 `tryAdmit()==null`；
     第二 `beginMaintenance()` 等待；end(false) 后恢复 admission；**先 freeze 再 maintenance
     end(false) 仍 `tryAdmit()==null`**（end(false) 不清除 freeze）。
  5. `end(permanent:true) closes`：之后 `beginMaintenance()==null` 且 `tryAdmit()==null`。
  6. `abandoned maintenance token leaks until holder ends`：holder 不 end ⇒ 第二个
     beginMaintenance 在受控测试超时内不完成；holder end 后才推进（文档化泄漏，无隐式清理）。
  7. `operation release is exactly-once`：重复 release no-op；drain 计数不重复扣除。
  8. `captured-restore busy state`：`_capturedRestoreOperation` 等 non-null 时 capture 抛
     `busy`（引用既有语义；不重复既有 `account_write_barrier_test.dart` 已覆盖的 frozen
     SET/selectTemporarily/refresh 等行）。
- **本地验证**：仅静态审阅（无本地 Dart SDK）；mock/静态不得替代 CI。
- **验收流程（获批后）**：实现 S1 → commit/push 新 code SHA → **STOP BEFORE CI for Codex
  SOURCE PREFLIGHT** → 通过后同 SHA 各派发 `ios.yml`/`ios-home-preview.yml` 一次 → 实际
  release 账户组日志含新用例计数 → Codex 独立实际证据复审 → 有限验收。
- **明确不含**：任何 production caller、Dart→Native session、MethodChannel、Swift 改动、
  global freeze caller、authority 激活。

## 5. 后续依赖（保持 OPEN，未获实现授权）

- S2（未来）：Swift 侧 session-prerequisite 只读组合 fence（session 级 preflight：原子读
  pointer+schema+journal 状态、unknown retain 契约），需独立 REVIEW 批准后才设计实现。
- S3（未来）：真实 frozen-revision Dart→Native→Dart composition（MethodChannel/binding，
  capture→P0→P1→export→Dart validation 全链，typed zero-effect mismatch）。
- 与全量 production composition 一起保持 OPEN：startup apply、nonempty-target reverse/revert、
  GC、handoff/authority 激活、process-kill/设备清单、Block3/4/5 其余项。

## 6. 验收顺序

1. 本 docs-only 计划先经 Codex CONTRACT review（返回本文 SHA；未获批前不实现 S1）。
2. 获批后：实现 S1 → 本地可为者仅静态/如实标注 → commit/push 新 code SHA → STOP BEFORE CI
   for Codex SOURCE PREFLIGHT → 通过后双 workflow 各一次 → Codex 独立实际证据复审 → 有限验收。
3. 全程保留：原 P05_BRIEF 范围、四 flag false、Flutter/Dart fallback、Aether 独立、
   no YouTube（含读取）、no UI visual、no auth/captcha/真实账户写、no unknown replay/fake device、
   不弱化断言/预算/门；不重开 R70–R73/297/6b/318。
