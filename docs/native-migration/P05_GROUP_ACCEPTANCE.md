# P05 并行实施与整组验收

2026-10-05，按用户最新要求调整实施节奏。Policy-2 的基线为已验证的 7192a0c。
各组实际实现后汇合到同一个集成 SHA，再执行完整编译与行为检查；此文件不代表
P05 已完成。后续 P06–P12 同样采用组内并行、独立提交、组末验收。

| 工作组 | 本轮实现边界 | 汇合验收 | 状态 |
|---|---|---|---|
| 网络 | capability evaluator、head-aware executor、字段保留 transport、timeout/compression/pool probe | Swift 6 production tests、真实 H1/H2/timeout wire、原 owner 终结、iOS16 链接 | 78ad72b / 3f6942b 已提交，H2/body 对照汇合中，未编译验收 |
| 签名 | Native WBI/App signer、key provider/cache；旧 Dart synthetic golden | Dart signer 与 Swift 输出逐值一致、UTF16/percent/time/cache | 3262e77 已提交，待整组验收 |
| 账户/存储 | 四用途 selection/session、Cookie/Keychain staging store、Hive 只读导出 | generation/revision/epoch、同 MID 隔离、重启/导入重复执行、完整 Cookie 属性 | e4431a9 已提交，Cookie parser/selector 汇合中，未验收 |
| 登录 | QR/password/SMS/Cookie/Geetest/退出、请求与副作用边界、状态机 | 实际 Dart synthetic response、RSA、挑战/手机验证、失败/取消/批量退出 | c2d4f2a / 3fee950 已提交，待整组验收 |
| 集成 | bridge 薄路由、PBX/工具 source list、workflow 与 fixture 汇合 | 完整 release + 全 preview 同 SHA，无资源/功能删除 | 待各组接口汇合 |
| 生产切换 | transport/account/API 验收后按领域切 Repository | 真实 API、登录/多账户/重启、无重复写请求；原实现仍可回退 | 未授权以未验证实现替换；待验收 |

每个组报告已实现与仍依赖 Dart 的路径，不能把一个协议或 synthetic test 视为真实
功能迁移。Root 集成前逐文件审阅，单独提交共用接入；不得把所有无关代码合为巨大
提交。正在编辑的其他组文件不混入本组 staging，用户 youtube/ 保持原样。

最终统一运行既有账户/Cookie/request context/policy/HTTP/search/transfer/golden
检查与新增组内生产实现检查；实际 Actions 日志和 artifacts 作为验收证据。
preview 四组（导航/压力、账户、图片、播放器）及 release 全部成功后，才更新
该集成 SHA 的已验证状态。失败必须按日志修复并重新完整验收。

原生网络和账户权威开关在以上证据及真实账户验收齐备前保持关闭；AetherEngine
独立，Flutter runtime、旧页面、Dart bridge 和数据 authority 不提前删除。

## 本组仍需区分的交付与验收

字段保留候选独立位于 Packages/PiliHTTPTransport，使用固定 AHC 1.36.1 / NIO
2.100.0，禁用自动解压、重定向、连接建立隐式重试和全局 tracing；借用的平台
event loop 只由平台管理，composition 显式关闭客户端。production 仅 HTTPS，
测试 CA 与 plain HTTP 仅 package 内部 fixture 构造器可用，并限制 IPv4 loopback。
其连接 null/zero、proxy、retry、H2/fallback/pool 过期语义在实际对照成功前不授权
执行。依赖实际 resolved versions 从 Actions artifact 收集后固定；声明 iOS16
platforms 不替代设备和 simulator 的真实编译、链接与 FFmpeg order 检查。

本轮账户是保留 Dart/Hive authority 的只读 snapshot 和 Keychain shadow import；
登录请求/状态机是独立 Native 实现，但 production LoginHTTPExecuting 尚未安装。
新增 install/delete bridge 的 writer 仍然是 Accounts/Hive，operationID 一次性消费，
不能在未知 acknowledgement 后重放。现 Hive adapter 不能保存的 Cookie 属性明确
拒绝写入；不能通过丢属性宣称完整持久化。以上完成并通过 CI 仍不等于 P05 的
生产权威切换和真实登录/多账户/重启验收已经完成。
