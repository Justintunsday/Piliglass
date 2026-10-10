# P05 Block 1 / B1b：选择、refresh 与登录副作用写入接入统一屏障

2026-10-10（Asia/Hong_Kong）。前置为 B1a 生命周期 Port 写入组
（[P05_WRITE_BARRIER_PLAN.md](P05_WRITE_BARRIER_PLAN.md)，代码 `2507fdb` 待同 SHA
验收）。本文件是实施前计划；范围是 Block 1 的第二个有限切片。

## 范围与盘点

| writer | 位置 | 现状 | 本组处理 |
|---|---|---|---|
| `Accounts.set` | `accounts.dart` | 选择 + type 变更 + `onChange` + `buvidActive` + `LoginUtils` 主账号副作用 | 入口单次 admit；frozen 在任何变更前拒绝 |
| `Accounts.selectTemporarily` | `accounts.dart` | 同步临时选择 | 单次 admit（同步窗口）；frozen 拒绝 |
| `Accounts.refresh` | `accounts.dart`，`Request.setCookie` 调用 | Hive 对账 + 选择重建 + buvid 激活 | 支持外层 admission 复用；frozen 拒绝 |
| `LoginUtils.onLoginMain` → `Accounts.deleteAll` | `login_utils.dart:70` | `set(main)` 内嵌删除（失败分支） | 透传外层 admission，禁止二次 admit |
| `importCredentials` → `refresh` | `accounts.dart` | 已 admit 的 import 内再 refresh | 复用 admission，不再单开 token |
| WK 镜像 / `RequestUtils.syncHistoryStatus` / `GStorage.userInfo` | `LoginUtils` | 延迟副作用 | 本组不包装；B1d 盘点 |
| csrf/accessKey/页面读取 | 100+ endpoint | 未收口 | B1c |

## 契约

- 嵌套链（`set(main)` → `onLoginMain` → `deleteAll`；`importCredentials` → `refresh`）
  必须复用同一个 admission：不允许二次 `tryAdmit`，冻结落在链中时不得产生半状态、
  不得死锁；admitted 链在 freeze 后仍运行到 finally 恰好释放一次。
- frozen 一律返回 `StateError('Account write-back is frozen')`，并且发生在任何选择/
  type/凭据/持久化变更之前。
- 无 frozen 调用者时行为与现状等价；带注入 coordinator 的正常路径必须原样可用。

## 测试

1. frozen `set`：选择、type、box 不变。
2. frozen `selectTemporarily`：选择不变。
3. frozen `refresh`：在 reconcile 之前拒绝，owner/revision 不变。
4. 在途 `set`（受控 persistence）：freeze 不完成；释放后 drain 完成且选择生效。
5. 注入未冻结 coordinator 的 `set` 正常路径。
6. B1a 全部测试与既有 208 项账户 suite 原样通过。

## 验收与边界

- 小 commit + push；组末同 SHA dispatch release5+preview4，读实际 artifact/outcome。
- 本组不改 WK 镜像、LoginUtils 的其它副作用、Hive close/compact（B1d），不迁移
  endpoint 读取（B1c）；四 flag 保持 false，P05 未整体完成。
