# P05 修复计划：3658406 审查（2 strict-info 风格 + R39 清单修正 + R40 负例覆盖）

2026-10-16（Asia/Hong_Kong）。依据 TOP handoff 与
`build/native-migration/review-3658406d30d06b0be0efc4e72f7d62e47ef9a04b-codex/REVIEW.md`
（CHANGES_REQUESTED）。**在代码修改之前保存**。已核对事实：`3658406` 对 release
[38834437129](https://github.com/Justintunsday/Piliglass/actions/runs/38834437129)
FAILURE（main job 116760267190 最终 aggregate 拒绝 ACCOUNT_DART/ACCOUNT_NATIVE/COOKIES/
ACCOUNT_ENVELOPE_OUTCOME，其余 4 job SUCCESS）、preview
[38834439919](https://github.com/Justintunsday/Piliglass/actions/runs/38834439919)
SUCCESS 4/4；实际 BUILD SUCCEEDED/109.1MB/FFmpeg 已观察但不得替代失败门。
本组只做：最小风格修复 + 清单修正 + 定向负例回归；不重做已接受的 R38/recovery/harness。

## 1. strict-analysis 风格修复（不改 gate）

- `lib/services/native_accounts/native_account_snapshot_service.dart:21`（prefer_initializing_formals，
  分析器建议原文 "Try using an initialing formal ('this._credentialReader')"）：
  构造器改为
  `NativeAccountSnapshotService({Future<void> Function()? checkpoint, this._credentialReader = accountCredentialReader}) : _checkpoint = checkpoint ?? _yield;`——
  Dart SDK `>=3.13` 支持私有命名参数，公开实参名保持 `credentialReader`、默认 reader 与语义
  不变；删除原 `_credentialReader = credentialReader` 赋值。
- `test/utils/accounts/native_account_hive_export_test.dart:56`（cascade_invocations，
  "Unnecessary duplication of receiver"）：`final restored = ...; restored.activated = true;`
  相邻 receiver 重复 → 改为 `Accounts.account.get('601')!..activated = true;`（语义不变）；
  本组新增测试同样避免该相邻模式。
- 不加 ignore、不改 analysis options/fatal-infos、不变断言/caps/flags。

## 2. R39 清单修正（recursive、显式 scope；不动 UI）

方法：`lib/` 递归、排除 `youtube/`、文本匹配（**非 AST**），逐条分类
定义/注释/live 调用。独立复核结果：

| 面 | raw 匹配 | 文件 | 定义 | 注释 | **live 调用** |
|---|---|---|---|---|---|
| `csrfOf` | 124 | 18 | 1（`accounts.dart:103`） | 3（`video.dart:368`、`msg.dart:379`、`dynamics.dart:137`） | **120 / 17 文件** |
| `accessKeyOf` | 19 | 9 | 1（`accounts.dart:120`） | 0 | **18 / 8 文件** |

- csrfOf live 分布：fav24、msg17、dynamics13、video13、user12、live8、member7、reply6、
  danmaku5、pgc5、validate2、danmaku_block2、login2、`member_profile/view.dart`1、follow1、
  black1、music1。
- accessKeyOf live 分布：live8、video4、`member_profile/view.dart`1、
  `ios_native_ui_bridge.dart`1、login1、`video_popup_menu.dart`1、user1、member1。
- 原计划表遗漏的实际消费者（补齐）：`lib/pages/member_profile/view.dart:348`
  `accessKeyOf(Accounts.main)`（face-update 预检，null/empty → toast 返回）、`:523`
  `csrfOf(Accounts.main)`（`/x/member/web/face/update` 请求参数）；
  `lib/common/widgets/video_popup_menu.dart:104` `accessKeyOf(rcmd)`（recommend 用途账号）。
  三者均走既有 fail-closed wrapper；本组**不修改**这些 UI 调用点、不批量迁移。
- 明确纪律：文本匹配数不是 AST live-call 计数，不证明 ownership/async/purpose routing
  已全覆盖；`csrfOf`/`accessKeyOf` 调用点的 tagged 类型迁移与其余 endpoint/composition
  任务保持 OPEN。

## 3. R40 定向负例覆盖（test-only，不新增生产 authority）

fixtures 新增测试专用 `ScriptedCredentialReader`（decorator：计数 allowance + 运行时
toggle；只拒 accessKey/refresh 两者之一，其余成员全部 delegate），覆盖当前 blanket-deny
未到达的 seam：

1. `native_account_hive_export_test.dart`：
   - descriptor 已接受、staging-entry **仅 refresh** 被拒（allowance=2；accessKey 保持
     bound）→ `snapshotChanged`、reads=3/3、revision 零效应、默认 reader 输出不变
     （证明 `_stagingEntry` 拒绝分支实际执行，删掉该守卫测试必须失败）；
   - converse：entry **仅 accessKey** 被拒（allowance=2）→ `snapshotChanged`、reads=3/2；
   - post-checkpoint：checkpoint 回调翻转**同一** reader → `_verify` 重捕获被拒 →
     `snapshotChanged`、reads 证明 descriptors+entries 曾 bound、revision 零效应。
2. `native_account_live_memory_capture_test.dart`：
   - 仅 refresh 被拒而 accessKey 保持 bound → `unavailable`、reads=1/1、revision 零效应；
   - legal bound-null：`refresh == null` 的账号 → `refreshTokenUnits` null 且
     `accessKeyUnits` 保留；
   - `verifyCurrent` 状态化拒绝（同一 reader 捕获后翻转）→ `unavailable`、reads 增加、
     revision 零效应。
3. 既有 Denied/默认等价/legal-null/stale-owner 用例全部保留；断言只增不减。

## 4. 验收与边界

- 小 commit/push → 新最终**代码** SHA 显式 dispatch BOTH `ios.yml` +
  `ios-home-preview.yml`（各一次）→ 读实际 evidence（account 实际计数、envelope
  109/44/40/**245**/**292**/51、producer、九 outcome、BUILD/FFmpeg、preview 20/11/压力）
  → docs-only 证据（与代码 SHA 分离）→ Codex 独立复审。
- 不降基线/预算/断言；四 flag false；不改 UI/`youtube/`/authority；不重跑 unchanged
  `3658406`、不自我验收、不复用旧 SHA 证据。
