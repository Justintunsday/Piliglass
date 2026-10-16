# P05 修复计划：ced3b19 审查（void-await 移除 + R43 判别性用途矩阵）

2026-10-16（Asia/Hong_Kong）。依据 TOP handoff 与
`build/native-migration/review-ced3b19f366f2daba9a2ae7c2a060eb0591eacd6-codex/REVIEW.md`
（CHANGES_REQUESTED）。**在代码修改之前保存**。

## 实际事实（已核对）

- `ced3b19`：release [38848059700](https://github.com/Justintunsday/Piliglass/actions/runs/38848059700)
  FAILURE（main job 116802944161 的 account analyze 报 lifecycle_test 656:20
  `use_of_void_result` ERROR + 656:5 `await_only_futures` INFO，导致
  ACCOUNT_DART/ACCOUNT_NATIVE/COOKIES/ACCOUNT_ENVELOPE_OUTCOME 被 aggregate 拒绝，其余
  4 job SUCCESS）；preview [38848062384](https://github.com/Justintunsday/Piliglass/actions/runs/38848062384)
  SUCCESS4/4（20 tests/11 reports/`pressure[]`，独立正证据、不构成验收）。
- 291 account/本组 7 用例**未实际执行**（分析失败）；BUILD/109.1MB/FFmpeg 存在但不覆盖失败门。

## 修复 1：同步 void 的误 await（仅删这一处）

- `test/utils/accounts/account_request_lifecycle_test.dart:656`：
  `await Accounts.selectTemporarily(AccountType.video, b);` → 去掉 `await`。
  `Accounts.selectTemporarily` 返回 void 且同步完成；请求已被 adapter 持有，同步选择正是
  预期的确定性交错。**不**改生产 API 为 Future、不包装、不 suppression、不改
  options/fatal-infos。

## 修复 2（R43.1）：heartbeat 负例判别化 + 正例 provenance

- 负例重做：main 槽放**不同的**登录账号（`selectTemporarily(AccountType.main, mainLogin)`，
  避免 LoginUtils 副作用），heartbeat 保持 anonymous → `dio.get(Api.heartBeat)` 必须
  reject（cancel）且 `adapter.fetchCount == 0`；若解析错误回落 main（登录）则请求会继续，
  test 可判别。
- 正例新增：真实 heartbeat 表路径 `Api.videoIntro`（'/x/web-interface/wbi/view'，非特殊
  heartBeat 拒绝路径），HB 槽放不同登录 hb；main/video 各放不同 owner；无 preset；断言
  binding==hb、请求头 `x-bili-mid`==hb mid、Cookie header 含 hb SESSDATA、响应 cookie 只写
  hb、main/video 零写。

## 修复 3（R43.2）：recommend 表路径

- 新增：`Api.recommendListWeb`（真实 recommend 表条目），recommend/main/video 三个不同
  owner，无 preset；断言 binding==recommend、`x-bili-mid`/Cookie provenance、响应 cookie
  只写 recommend、main/video 零写。

## 修复 4（R43.3）：video 用例的 main 槽前置

- video 用例把其命名 `main` 对象真正 `selectTemporarily(AccountType.main, main)`，并断言
  `Accounts.get(main/video)` 槽前置条件，使"回落 main 会写 main"成为真实可判别对照。

## 修复 5（R43.4）：reader 用例的 header/计数精度

- reader 用例断言实际请求头 `x-bili-mid == '361'`（选中 video owner）、Cookie header 含
  'SESSDATA=video-reader'、`captures == 1`，且 `csrfReads/accessKeyReads/refreshReads/
  boundCsrfReads/boundAccessKeyReads/boundRefreshReads` 全 0（无非预期 legacy/tagged 读）。

## 边界与验收

- 只改测试；不复制 resolver、不 relabel preset、不真实网络；保留既有断言与"槽切换后旧
  owner A 的合法响应写入"用例；不弱化任何断言/预算。
- 小 commit/push → 新最终代码 SHA 显式 BOTH `ios.yml` + `ios-home-preview.yml`（各一次）
  → 读实际 evidence（account 291 真实执行、envelope 109/44/40/245/292/51、producer、
  九 outcome、BUILD/FFmpeg、preview 20/11/压力）→ docs-only 证据 → Codex 独立复审。
- 四 flag false；不改 UI/`youtube/`/authority；不重跑 unchanged `ced3b19`、不自我验收、
  不声称 whole Block1/P05 关闭。
- 验收记录（docs-only，不改变代码 SHA）：本计划的 B1f/R43 内容（连同 harness R44–R47）在
  代码 SHA `a50ea693c2d4b7d410fff9e29c40ad437af941ac` 获 Codex 有限 PASS（review
  `review-a50ea693c2d4b7d410fff9e29c40ad437af941ac-codex/REVIEW.md`）；仅在已测试路径范围
  内成立，whole Block1/authority 未闭合；`ced3b19` 失败与 `d5f9d0c` preview 失败史保留，
  不追溯改判。
