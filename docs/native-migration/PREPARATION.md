# 后续阶段并行准备索引

> 2026-10-05 执行节奏更新：按用户最新要求，同组并行实施、各切片独立检查/提交/推送，整组汇合后统一运行 release 与全部 preview，并读取实际日志修复至成功。本文件旧有逐切片完整 CI 门禁由此替代；功能/数据验收、fallback 删除和权威切换门禁保留。见 [P05_GROUP_ACCEPTANCE.md](P05_GROUP_ACCEPTANCE.md)。

2026-10-04 开始；2026-10-05 补充，按用户要求在 P05 实施/CI 期间准备后续阶段。
这些文件是基于实际源码的执行计划，均未切换运行时，不表示对应阶段已经完成。
主顺序仍是 PLAN.md 的 P05→P12；视觉 UI 重写最后，已选原生玻璃风格保留。
其中 Policy-1 实际 Dart 描述与 Policy-2 lease/Swift codec 已完整 CI 验证；其他准备项
的阶段状态见 PROGRESS.md。能力判定和实际 transport 对照方案也已保存，未开启 runtime。

| 准备方案 | 可先做的独立工作 | 生产切换前置 |
|---|---|---|
| [有效 HTTP policy](P05_EFFECTIVE_HTTP_POLICY_PLAN.md) | 实际Dart配置来源/代次描述、合同与wire矩阵 | 请求头生命周期、有效timeout/proxy/trust/retry/compression、字段保存transport |
| [Policy lease/Swift codec](P05_POLICY_LEASE_PLAN.md) | await前后完整有效输入复查、versioned DTO与actualDart golden | Policy-1完整CI、原owner单次终结、能力判定和transport parity |
| [Native policy 能力判定](P05_POLICY_CAPABILITY_PLAN.md) | 纯 evaluator/reasons、具体transport证据profile、发送前边界 | Policy-2完整CI；零发送fallback与原owner单次finish；Policy-4实际wire |
| [transport 实际对照](P05_TRANSPORT_PARITY_PLAN.md) | 固定版本 iOS 编译/字段 probe、真实 idle/raw encoding/H1-H2矩阵 | 每切片完整CI、有序字段/cancel/原owner验收、实际API后才切 composition |
| [账户与签名](P05_ACCOUNT_SIGNING_PLAN.md) | 固定实际Dart输出的纯signer、四用途readonly协议/快照 | 原owner/generation与单authority、完整现有登录/退出/存储验收 |
| [首页/视频 REST](P06_HOME_VIDEO_REST_PLAN.md) | 窄Repository+Dart adapter、Root DTO/Feature拆分、纯参数/过滤/decoder | 各endpoint用途/签名/policy/lease，单路实际API对照 |
| [模型与持久化](P07_MODELS_PERSISTENCE_PLAN.md) | 各领域DTO边界、真实Hive exporter、staging/restart/idempotence | 全caller单写authority、旧数据完整导入、切回兼容reverse-export |
| [protobuf/gRPC](P08_GRPC_PLAN.md) | schema来源/生成hash、actualDart frame/message/metadata golden | iOS16实际依赖链接、HTTP2/status/trailers、各服务账户与业务验收 |
| [直播/私信/弹幕](P09_LIVE_MESSAGE_PLAN.md) | 真实Dart packet golden、typed事件/状态边界、生命周期矩阵 | P05/P08门禁、真实Socket/消息同步/账号隔离、真机后台行为 |
| [下载/后台/播放器外围](P10_DOWNLOAD_PLAYER_PLAN.md) | typed下载边界、真实旧manifest/file与Range状态、Player外围拆分 | P05/P07/P08门禁、单存储authority、真机后台/音频/PiP验收 |
| [页面/runtime退出](P11_P12_RUNTIME_PLAN.md) | 完整route/caller覆盖、插件/资源映射、Native-only构建演练 | 所有领域Native供数/authority、核心路径/数据导入/实际CI，无旧caller |

准备时发现并已写入方案的兼容约束：

- 首页当前Web/App推荐均是REST；注释掉的Popular/View wrapper不能当成活跃gRPC。
  视频详情heartbeat、关系/tags main、related recommend，不统一绑定main。
- WBI/AppSign编码/空值/旧digest、UTF16排序和组合字符不能由Swift默认描述/排序猜。
  当前Accounts.refresh是Hive/用途对账，不是token续期；Native QR不代表完整登录。
- Hive导出全部设置只包含setting/video；搜索历史与服务端观看历史分开。旧Cookie
  adapter丢失的非根domain/path属性无法恢复；Native/Hive账户不得独立双写。
- 当前grpc只有生成Dart文件、无proto源；SDK、schema来源和生成版本须先固定。
  app+bytes使用实际cached grpcHeaders，当前grpc用途默认main，不能自行改成video。
- tcp/live实际WebSocket；连接后的自动重连尚无旧实现。packet/压缩/事件与心跳
  分层验证，新重连行为单独提交，不能用WebSocket ping替代应用心跳。

实施每一个切片时重新核对相关源码与方案中的原始假设；计划不是冻结API，也不是
跳过行为对照的理由。继续按diff→commit→push→完整release+全部preview同SHA→实际
日志修复循环；当前代码未全绿时只准备后续，不混入其他领域生产实现。
P10下载/后台与P11/P12页面/runtime删除的准备也已补充，仍按PLAN执行，未通过覆盖门禁前不删旧依赖。
