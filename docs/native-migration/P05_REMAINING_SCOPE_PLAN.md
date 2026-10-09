# P05 剩余范围与依赖顺序（用户 2026-10-10 指定）

本文件把用户 2026-10-10 指定的五块剩余范围写成可执行清单。它不改变任何已验证结论，
也不表示任何块已完成；P05 整体完成判定仍以 CA5/CA6 真机验收与全部门禁为准。当前
进行组是 credential reader 只读 adapter（计划见
[P05_CREDENTIAL_READER_PLAN.md](P05_CREDENTIAL_READER_PLAN.md)），先完成该组的同 SHA
闭环与交付，再按下方依赖推进，不在每个小组后停下等待。

## 依赖顺序

1. **Block 1 全部 reader/writer 与屏障**：为块 2/3/4 提供统一的读者边界与写入屏障。
2. **Block 2 Native 账户 durable 事务**：依赖块 1 的 writer 边界与账号级排队。
3. **Block 3 生产交接/启动恢复/完整回退**：依赖块 2 的 durable identity 与块 1 的屏障。
4. **Block 4 Native 登录/签名/网络生产接线**：依赖块 1 的网络 reader/writer 边界；
   可与块 2/3 并行准备，整组汇合后统一验收。
5. **Block 5 真实账户设备验收与开放**：依赖块 1–4；全部满足后才按门禁开放。

每组流程沿用仓库既有节奏：实施前保存小组计划；按责任小 commit + push；同组汇合后对
同一代码 SHA 显式 dispatch `ios.yml` 与 `ios-home-preview.yml`；读实际日志/artifacts
修复至 5+4 全绿并核实聚合 outcome；交 Codex 复审；更新 PROGRESS/STATUS_MATRIX/报告。
四能力 flag 保持 false；保留 Flutter/Dart fallback；不改 UI 视觉、不耦合 Aether、
不碰 `youtube/`。

## Block 1：全部 reader/writer 与统一屏障

盘点并逐项收口，每一项都记录位置、当前 authority、拟接入边界与测试方式：

- 只读 reader 全量：`csrf`（约 100+ endpoint 调用点）、`accessKey`/`refresh`、
  `grpcHeaders`、AccountManager 用途路由、页面 `Accounts.account.values/toMap/isEmpty`
  （login/mine/setting/about、snapshot service）。已完成的请求头与 lease 只是第一批。
- 生命周期 writer 全量：install/import/delete/set/selectTemporarily/temporary/refresh/
  clear/匿名 reset/activation；`LoginAccount` 构造器与 `BiliCookieJar.setBuvid3` 补值；
  WK Cookie 镜像；LoginUtils 延迟副作用（WK/cache/history）；Hive maintenance/close/compact。
- 统一协调边界要求：token 不替代 owner/epoch/generation 检查；嵌套操作与在途排空不得
  死锁，也不得仅清表假装排空；freeze/drain 语义必须覆盖每一个真实 await。
- 当前 response 写回 gate 只是有限组：本块把它扩展为包含上述 writer 的完整边界，逐个
  切片接入并保持 Dart writer 的返回语义与副作用顺序。
- 兼容约束：每个切片先包一层 port/reader，不改默认行为；无 CI 证据不声明迁移完成。

## Block 2：Native 账户 durable 事务

- 剩余写事务：持久用途切换（`Accounts.set` 的 type add/remove 双账户语义）、
  install/import/delete、buvid 补值等；建立 durable record identity。
- 账号级排队与结果语义：同一账号的写序列化、每笔操作的 receipt/unknown 语义；
  unknown ack 不重放、不误判未写。
- 数据保持：完整 Cookie 属性/顺序、nullable 凭据、临时选择与原有副作用必须保持。
- 复用已验收的 strict codec、transaction store 与 vault；事务组件测试通过不等于生产
  authority 已切换。

## Block 3：生产交接、启动恢复与完整回退

- 把已验收的 Native marker/coordinator、Dart proxy 与恢复 Vault 接入真实 composition；
  明确 freeze → drain → export → 验证 → publish → resume 的顺序与失败处理。
- 完成启动 apply、`completeRevert`、崩溃阶段恢复与非空目标政策；legacy Hive 重启丢
  属性问题不得绕过。
- GC 仅在引用安全有证据时执行；无证据时安全保留。
- 组件或 shadow 通过不等于生产 authority 已迁移；切换开关留在 composition/repository。

## Block 4：Native 登录、签名与网络生产接线

- 登录全量：完整 QR/密码/SMS/Cookie、Geetest/手机验证、退出及多账户用途行为。
- 把已实现的原生签名/缓存与 HTTP 能力接到 Repository/Client；按真实 Dart 对照迁移。
- 补齐或精确标注支持范围：proxy/retry/pool generation、HTTP1/HTTP2/TLS、timeout
  （idle vs deadline）、raw `Set-Cookie` 字段保存、gRPC 认证 metadata；未验证组合继续
  显式 fallback。
- 取消与未知结果不得二次发送写请求。

## Block 5：真实账户设备验收与开放

- CA5/CA6：登录/换号、四用途隔离、响应 Cookie 属性、杀进程/冷启动/重启、网络异常
  与回退的完整验收。
- 全部门禁满足后才开放已验收的 Native authority 能力；缺真实账户/设备时列出具体
  待验收步骤与阻塞项，继续不依赖这些输入的代码工作。
- 不伪造通过、不提前写 P05 完成；Codex 在 P05 整体完成后给出 P06–P12 与最终 UI
  重写的交接提示词。

## 保留事项（上一组补测）

1. frozen lease 零写：完整 `NativeOrderedCookieJarExporter.export` 前后对比 + host-only
   `lease_cookie` 不存在断言（已完成于本组）。
2. redirect 多 Location 逐阶段受控阻塞（已完成于本组）。
3. AccountManager 真实 save 抛错与真实 Hive onChange 抛错 token 精确释放（已完成于本组）。
4. image-preview 就绪等待 16s 是 ready deadline 从 6s 放宽的稳定性调整，不宣称维持
   原 6 秒性能门槛（随本组验收的文档更新记录）。
