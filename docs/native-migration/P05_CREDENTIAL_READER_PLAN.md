# P05 下一有限组：credential reader 只读 adapter 与默认 Dart 实现

2026-10-10（Asia/Hong_Kong）。实施前保存的计划，不是实现或验收证明。前置为已验收的
CA3 响应写回协调器组（代码 `d255506`，复审
`build/native-migration/review-d255506-codex/P05_REAUDIT.md`）。本组只做凭据读取边界，
不接 `completeRevert`/启动 apply/NativeActive，四能力 flag 继续 false，不改 UI/Aether，
不删 fallback。

## 范围与盘点

盘点本轮涉及的 credential reader（只读）：

| 读取点 | 位置 | 本组处理 |
|---|---|---|
| 请求头 assembly（gRPC headers、base headers、accessKey） | `account_mgr.dart` `onRequest` 的 app/REST 分支 | 接入 reader（清晰共享请求路径） |
| Native lease 准备头 assembly | `native_http_request_lease_service.dart` `_captureInput` | 接入 reader（第二请求路径） |
| `csrf` | `lib/http/{video,live,user,msg,fav,dynamics,...}.dart` 约 100+ 处 `Accounts.*.csrf` | 提供 `csrfFor` 只读入口与测试；本轮不改 100+ endpoint 调用点 |
| 页面读取 `Accounts.account.values/toMap/isEmpty` | `pages/{login,mine,setting,about}`、`native_account_snapshot_service` | 提供 `visibleAccounts()` 只读摘要与测试；不重写 UI 页面 |
| `AccessKey`/`refresh` 直接读取 | `lib/http/{video,live,user}.dart` | 请求路径经 reader；endpoint 其余读取留后续切片 |

排除项（明确列出依赖，不本组实施）：install/import/delete/set/refresh/reset/activation
的生命周期 writer、Hive maintenance/close/compact、LoginUtils 的 WK/cache/history 延迟
副作用、页面整体 reader 收口。

## 契约

- 新 `lib/services/native_accounts/account_credential_reader.dart`：
  - `AccountCredentialContext`：不可变只读快照，含 `mid`、`isLogin`、`activated`、
    `generation`（来自请求 stamp）、`accessKey`、`headers`（unmodifiable copy）、
    `grpcHeaders`（unmodifiable copy）；不持有 Account、jar、Cookie 或 Hive 引用。
  - `AccountCredentialSummary`：页面只读摘要（storageKey、mid、isLogin、activated），
    不暴露 live 对象。
  - `AccountCredentialReader`：
    - `captureRequest(Account owner, AccountRequestStamp<Account> stamp)`：stamp 与
      tracker 身份一致且仍是当前安装 owner 时返回 owned 快照；否则 null。**纯读**：
      不 activate 匿名、不改 revision、不写 jar/Hive/网络。
    - `csrfFor(owner, stamp)`：同 owner/stamp 校验后返回真实 `csrf`（缺失仍按原样
      抛出）；供后续 endpoint 收口使用。
    - `visibleAccounts()`：从实际 account box 生成摘要列表；不返回 live Account。
  - `DartAccountCredentialReader` 默认实现 + `const accountCredentialReader` 共享实例。
- **不是 authority**：reader 不安装/激活/撤销凭据，不替代 `_isCurrentBinding`/
  `ownsCredentials`/`_owns` 检查；调用方保留原 owner/generation 校验。
- 接入路径：
  - `AccountManager` 增加可选 `credentialReader`（默认共享实例）；`onRequest` 在
    `_isCurrentBinding` 通过后用 `captureRequest` 取得 headers/grpcHeaders/accessKey，
    返回 null 时按原 `_revokedRequest` 拒绝；同步读取，不改变写入时序/重试/redirect。
  - `NativeHTTPRequestLeaseService` 增加可选 `credentialReader`；`_captureInput`
    用 `captureRequest(account, stamp)` 的 headers，null 时抛既有 `revoked`。
  - 生产两个默认共享同一 `accountCredentialReader`（组合断言测试）。
- 页面读取/100+ csrf 调用点保持原 Dart 路径，只在文档记录剩余缺口。

## 同组补测（上一组非阻塞项）

1. frozen lease 零写：改用完整 `NativeOrderedCookieJarExporter.export` 前后 JSON 对比
   （含 hostBuckets），并直接断言无 Domain 的 `lease_cookie` 不存在；不再只用有损
   `cookieJar.toJson`。
2. redirect 全部 save（含多个 Location）与最终 persistence 逐个受控阻塞：每个阶段
   drain 都不能提前完成，释放后才继续；保留原 302/2→3→2/1of1 断言。
3. AccountManager 真实 save 抛错与真实 Hive `onChange` 写后抛错：token 精确释放、
   drain 完成、写后错误不推导未写/不重放；不用纯协调器 throw 或 lease seam 替代。
4. 文档注明 image-preview 就绪等待是 ready deadline 从 6s 放宽到 16s 的稳定性调整，
   不宣称维持原 6 秒性能门槛。

## 验收与停止边界

- 分小提交：计划 → reader → AccountManager → lease → 补测；组末同 SHA dispatch
  `ios.yml` 与 `ios-home-preview.yml`，读实际日志/artifacts，失败修复重跑直到
  release5 + preview4 全绿；九强制 outcome、账户/envelope 实际计数为准。
- 本组不把只读快照当成 authority 切换；credential reader 之外的 writer/生命周期/
  maintenance/延迟副作用仍列待办，P05 未整体完成。
