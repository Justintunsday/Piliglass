# P05a1b：账户凭据代次与响应写回边界

2026-10-04，已通过同 SHA 的完整 release 与全部 preview（15a7f9d）。HTTP 与 Hive runtime 仍由 Dart 供应，
尚未建立 Native context lease，也未迁移登录网络或存储。

## 可回滚切片

- 纯 Dart `AccountRequestState<T>` 用 identity map 管理不可变 request stamp；
  snapshot revision 与 credentials generation 分开。普通选择与 Cookie mutation
  只使准备中的 snapshot 失效，不撤销其他有效在途响应。跨 tracker stamp 不互认。
- 账户层显式 install/import，新凭据在 Hive 成功、仍为最新对象后才启用；失败或被替代
  不恢复旧 generation。所有持久账户均注册，包括未选中的对象；refresh 按 identity
  对账、重建用途，重复扫描同一有效对象不撤销 stamp。Hive schema 保持原样。
- `onChange` 仅更新有效且当前持有存储条目的对象；旧同 MID 对象不能覆盖或删除新对象。
  同 MID 重登录继承持久化用途，替换运行中的登录 slots，保留临时匿名选择。导入先检查
  全部 key/MID，再使用输入用途；账户模式列表对调用者只读。
- clear/delete 在第一次 await 前撤销旧请求；匿名 singleton reset 用独立 token，
  只允许最新 completion 补完 buvid 后启用新 generation，期间禁止 capture，
  并重置 activated。所有登录、Cookie 登录、Native QR、导入和临时无痕调用点转入窄接口。
- Dio 同步捕获首次 account/stamp，重试/重定向沿用原 binding。已撤销请求在再次发送前
  取消；已收到的旧响应忽略 Cookie 写回。正常/403/redirect 共用检查，每次 jar 保存之前、
  await 之后与 Hive 更新之前重新验证原对象与存储所有权，保持有效 A 的响应写回 A。
  redirect location 写回顺序保留，并逐次检查。NoAccount/CDN 绕过逻辑继续保留。

## 验证门禁

纯 Dart fixture 直接运行真实 tracker，覆盖 MID equality 不同 identity、A→B→A、
并发 Cookie 更新、撤销/重装、未选中账户、匿名同对象轮换、跨 tracker 与不可变 stamp。
实际执行后生成 `build/account-request-state/summary.json`；Windows 未运行。

Flutter fixtures 用真实 Hive account/cookie/type adapters、临时 setting/localCache、
真实 AccountManager 与可控 Dio adapter。正常/403/302、原账户写回、并发响应、同 MID
替换、旧 onChange/delete、refresh、clear、匿名 reset、旧 RequestOptions 重试、用途/临时
无痕、导入整批校验与重启反序列化都有断言。测试无真实 Bilibili 网络；旧删除测试补全
`await saveFromResponse`，不依赖当前 CookieJar 的同步实现偶然通过。

现有 iOS workflow 在 Flutter setup 与 iOS patch 后执行定向 analyze、纯 Dart fixture
和整个 `test/utils/accounts/`，上传分析、runtime JSON、Flutter test log。显式 `shell: bash`
启用 pipefail，确保 `tee` 不掩盖失败；共享 Cookie parser step 同样启用。
完成依据仍是同 SHA 的完整 Runner release、FFmpeg load order 与全部 preview 成功。

## 实际 CI 证据

最终代码 `15a7f9de53871a39a1bbe3e94d8638a95c94a49b` 的
[完整 release](https://github.com/Justintunsday/Piliglass/actions/runs/37177848831) 与
[全部 preview](https://github.com/Justintunsday/Piliglass/actions/runs/37177850629) 均成功。
定向 analyze 无问题，Dart 3.13.4 实际执行 72 项 tracker 检查与 22 个 Flutter/Hive/Dio
测试，包含生产 RetryInterceptor 重定向、同 MID 并发安装和重叠匿名 reset。
Cookie wire 70、parser 122、HTTP 74、Search 63 检查继续通过。Runner 日志确认
`BUILD SUCCEEDED`、677 双语 keys 和 Aether FFmpeg load order；压力报告 failures=[]，
1,000 评论懒加载/离屏不分页/末条分页，100,000 弹幕完整保留、活跃上限 60。

首轮 a19fe5a 的 release 成功，但 preview 的竖屏双击暂停断言失败。读取实际日志、
XCUI 附件和录屏后确认该次未触发暂停；坐标正确、横屏成功，具体根因未证明。
15a7f9d 保留相同生产播放器和测试断言，两项播放器测试实际通过；没有通过放宽断言
掩盖旧失败。新增账户测试与两处 lint 修正随最终提交重新验证了全部门禁。

生产 RetryInterceptor 在 AccountManager 之前消费中间 302 的既有行为仍保留；新增
测试验证最终响应写回首次账户，不宣称中间 302 Cookie 已保存。当前 pinned CookieJar
mutation 在 async body 首段同步执行；这些检查不证明任意未来异步 jar 的内部写入安全。

## 保留的限制

这是 strangler strategy 的账户兼容边界，不是 Native 账户业务完成。Swift/Bridge lease、
prepare/finish/abandon 的一次性终结、取消后的已收到头写回、原生 Cookie transport 的
歧义处理与有效网络策略均在 P05a2/P04b 继续实施。Flutter runtime、所有既有功能、
CookieJar/Hive 与 AetherEngine 独立边界保留；不扩展到 UI 数据缓存或完整登录流程重写。

计划依据和已审查风险见 [REQUEST_CONTEXT.md](REQUEST_CONTEXT.md)，Cookie wire 的真实
表示证据见 [COOKIE_HEADERS.md](COOKIE_HEADERS.md)。
