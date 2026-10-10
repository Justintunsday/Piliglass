# P05 Block 1 / B1a：生命周期 Port 写入接入统一 admission/drain

2026-10-10（Asia/Hong_Kong）。前置为 credential reader 只读组（
[P05_CREDENTIAL_READER_PLAN.md](P05_CREDENTIAL_READER_PLAN.md)，同 SHA 闭环完成后
开始实施）。本文件是 B1a 的实施前计划，不是实现或验收证明。范围是用户指定的 Block 1（全部 reader/writer 与统一
屏障）的第一个有限切片：**只做 Port 支撑的生命周期 writer 边界**；不接启动 apply/
NativeActive，四 flag 保持 false，不改写默认 Dart 行为（无 freeze 调用者时逐字节等价）。

## 盘点（本组触及的 writer）

| writer | 位置 | 现状 | 本组处理 |
|---|---|---|---|
| install | `Accounts.installCredentials` → `writeLegacyInstall` | 有 begin/complete/fail，无 barrier | 入口单次 admit；frozen 拒绝 |
| import | `Accounts.importCredentials` → `writeLegacyImport` | 多账户 begin/fail 已实现 | 入口单次 admit；frozen 拒绝 |
| deleteAll | `Accounts.deleteAll` → `LoginAccount.delete`/`AnonymousAccount.delete` | revoke 后并发 port 删除 | 入口单次 admit；frozen 拒绝 |
| 直接 delete | `LoginAccount.delete` / `AnonymousAccount.delete` | UI 可直接调用 | 自身入口 admit（内部路径不重复） |
| clear / 匿名 reset | `Accounts.clear` → `clearLegacyAccounts` + `anonymous.delete` | recoveryOperation 语义 | 外层单次 admit；嵌套不重复 |
| refresh / set / selectTemporarily / temporary | `Accounts` | 选择与激活写入 | **不在本组**；B1b 单独定义拒绝/延迟语义 |
| 构造器 buvid 补值 / `notifyCookieMutation` | `LoginAccount`/`Accounts` | 纯内存 seed / revision-only | 不 admit（无持久写入） |
| WK 镜像 / LoginUtils 延迟副作用 / Hive close/compact | `LoginUtils` 等 | 独立副作用 | 盘点保留；B1d 处理 |

## 契约

- 复用 `AccountWriteBackCoordinator`（不改其实现语义）：外层公共入口
  `tryAdmit()` 一次；返回 null（frozen）时在**任何 revoke/字段变化/port 写入之前**抛
  `StateError('Account write-back is frozen')`；已 admit 的链在 `finally` 恰好释放一次。
- 嵌套规则：`clear`→`anonymous.delete`、`deleteAll`→`account.delete` 等内部调用走
  “已持票”私有路径，不二次 admit；直接调用 `account.delete()` 时自身 admit。
- 释放前所有真实 await（jar/Hive/port）都在同一 admission 内；drain 必须等真实写入
  完成，不得仅清表或提前完成。
- 无 frozen 调用者时行为与现状等价（既有 208 项账户测试必须原样通过）。

## 测试矩阵（新增 `test/utils/accounts/account_write_barrier_test.dart`）

1. frozen 时 `installCredentials` 拒绝：owners/box/jar/request stamps 均不变。
2. frozen 时 `importCredentials` 拒绝：所有候选均不写入，不触发部分安装。
3. frozen 时 `deleteAll` 拒绝：凭据未 revoke、jar/Hive 未删。
4. frozen 时 `clear` 拒绝：owners/box/mode 不变，匿名 reset 未开始。
5. drain：安装 port 写入被 gate 阻塞时 freeze 不完成；释放后 drain 完成且状态一致。
6. drain：delete/clear 的在途 port 写入同理（写后台受控、freeze 先不完成）。
7. 嵌套：`clear`、`deleteAll` 在 frozen 边界只产生一次 admission，不产生半状态、不死锁。
8. 直接 `LoginAccount.delete()` / `AnonymousAccount.delete()` 入口在 frozen 时的行为
   与内部路径一致。
9. 既有账户 suite 全量回归（实际计数以 CI artifact 为准）。

## 验收与停止边界

- 小 commit + push；组末同 SHA dispatch `ios.yml` + `ios-home-preview.yml`，读实际
  artifacts：账户 analyze 无问题、suite 实际计数、envelope 108/43/40/35/51 不变、
  九个聚合 outcome、BUILD SUCCEEDED/109.1MB/FFmpeg、preview 4/4。
- 本组不改变选择/激活语义（B1b）、不迁移 csrf/endpoint 读取（B1c）、不处理 WK/
  LoginUtils/Hive maintenance（B1d）；P05 未整体完成。
