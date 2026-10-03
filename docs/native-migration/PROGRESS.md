# 迁移进度与编译证据

最后更新：2026-10-04（Asia/Hong_Kong）。目标仍在进行，Flutter runtime 保留。

| 阶段 | 阶段代码 Commit | iOS release | Preview | 状态 |
|---|---|---|---|---|
| 起点 | 8044a8d | [成功](https://github.com/Justintunsday/Piliglass/actions/runs/36085475142) | [分页检查失败](https://github.com/Justintunsday/Piliglass/actions/runs/36085470278) | 仅基线 |
| P00 | 603d3c6 -> ad0e8b5 | [成功](https://github.com/Justintunsday/Piliglass/actions/runs/37132297374) | [全部成功](https://github.com/Justintunsday/Piliglass/actions/runs/37132297176) | 基线与迁移计划完成 |
| P01a | b906383 -> c783318 | [成功](https://github.com/Justintunsday/Piliglass/actions/runs/37133641553) | [全部成功](https://github.com/Justintunsday/Piliglass/actions/runs/37133641528) | 首批组件边界完成 |
| P01b | 9d9fb2f | [成功](https://github.com/Justintunsday/Piliglass/actions/runs/37135310166) | [全部成功](https://github.com/Justintunsday/Piliglass/actions/runs/37135310327) | DesignSystem/codec 边界完成 |
| P02a | 662f739 | [成功](https://github.com/Justintunsday/Piliglass/actions/runs/37136856478) | [全部成功](https://github.com/Justintunsday/Piliglass/actions/runs/37136856328) | Search Feature/UI 状态契约完成 |
| P03 | 7ff23b9 | [成功，含 Swift 6 core](https://github.com/Justintunsday/Piliglass/actions/runs/37140033171) | [全部成功](https://github.com/Justintunsday/Piliglass/actions/runs/37139965902) | Native Search state、typed Repository 与临时 Dart adapter 完成 |

P00 证据：inventory 包含 59 个 bridge commands、62 个注册 Flutter routes、311 个 REST 常量、45 个 gRPC 常量、95 个依赖。压力检查 `failures=[]`，1,000 条评论保持懒加载、未在离屏处触发分页、实际末条出现后分页成功；100,000 条弹幕保留，活跃渲染上限 60。仅测试 harness 调整了懒加载自适应行定位等待；没有修改生产 UI 或业务。

P00 实际 Actions 工具链：Xcode 26.6 / Apple Swift 6.3.3；Runner 仍以 Swift 5 language mode 构建。release 日志确认 Aether FFmpeg 在 media-kit FFmpeg 之前链接。

P01a 范围：从 Root 抽出 Flutter player surface，从 Player 抽出诊断日志与同步 HTTP range IOReader。保留 child containment、缓存/seek/取消和所有 fallback；同步扩展 localization checker 到 Native 子目录。逐类型对比移动前后正文，仅放宽两个 file-private 类型到 Runner 内部可见。

P01a 验证：当前阶段代码 `c783318d8e13f93061b2ce5f6ed3cd9153097593` 的完整 iOS release 编译和 FFmpeg 链接顺序检查通过；preview 的 account-pages、image-preview、player-controls、preview 四个 jobs 全通过。本地 staged diff 检查通过；没有删除业务、资源或依赖。类型正文一致性与本地 source extractor 检查只作为提交前检查，完成依据是上述真实 Actions。

P01b 范围：抽出 semantic design tokens、3 个 view modifiers、View chrome extension 与
7 个 codec helpers；更新 Xcode 注册与集中 preview 源读取。类型正文和四个预览生成
结果与提交前一致（忽略空行），仅放宽跨文件需要的可见性。独立子智能审查发现并
修复 helper-only CI path 覆盖缺口；未删除功能、资源或 Flutter fallback。

P01b 验证：`9d9fb2fd704af2458d51cee9307b5a6146406f7a` 的 release 与 preview 同 SHA
全部成功。Actions 日志确认完整 Runner 编译、677 项双语检查与 Foundation runtime
格式化检查通过；account-pages、image-preview、player-controls、preview 全部成功。
下载实际视频压力报告：`failures=[]`、评论 1,000/懒加载/无离屏分页/末条分页通过，
100,000 条弹幕完整保留、活跃上限 60，末条定位用了 2 次真实滚动。

P02a 范围：Search View 以 MainActor/ObservableObject 的窄协议读取 12 个属性、调用
7 个操作，Root ViewModel 继续私有；新增播放导航转发保留原有默认参数。拆出 video
bridge DTO、loading/error、transition source 和 remote image。Root 减少约 420 行。
图片 loader 保留动态/评论图片所需的内部访问权限，缓存/取消和业务正文未变。
预览 fixture 使用实际生产协议与泛型 View，保持 actor/namespace/Reduce Motion guards。

P02a 验证：`662f7399d9633853e8b4167e50fd18c305487778` 的完整 release 与四组 preview
同 SHA 全成功，实际日志确认完整 Runner 编译及 FFmpeg load order。本地正文对照与
独立子智能审查无剩余问题；没有删除功能/资源/依赖。实际视频报告 `failures=[]`，
1,000 评论的懒加载/离屏分页/末条分页检查通过，100,000 弹幕完整保留、活跃上限 60。
本阶段只完成 UI/状态依赖边界，搜索业务仍由 Dart 提供；不能视作 Repository 迁移完成。

P03 范围：Root 不再持有搜索状态或发起搜索 channel 调用。独立 MainActor Search model
注入 Sendable Domain Repository；Data adapter 暂时转发现有 Dart 请求和 Hive 操作。
不可变 codec snapshot 在 Flutter 回调线程捕获后跨 actor 传递，invoker 统一完成/取消
门禁，忽略重复与迟到回调。请求代次覆盖重复词/A→B→A，提交失效联想，关闭取消读取。
record/remove/clear 统一排序；第一页先等待历史写入，保存失败阻止 HTTP，clear 不等待
视频 HTTP。已请求的写操作保留，迟到快照不能回写新状态。旧 Dart callers 默认继续
自动记历史；Native adapter 显式记录后传 `recordHistory: false` 避免重复写入。

P03 验证：`7ff23b9c52909c07dcf5ad9ff0b5d3db4d6f70e8` 两个 workflow 同 SHA 成功。
真实 macOS Swift 6 `-strict-concurrency=complete` 编译生产核心，63 项 codec/transport/
Repository/state/history/cancellation 检查通过；完整 Runner release 编译及 Aether FFmpeg
load order 通过，实际 Flutter SDK wrapper 由完整 Runner 验证。四组 preview 全成功。
下载的视频压力报告 `failures=[]`，1,000 评论懒加载、离屏不分页、末条分页通过，
100,000 弹幕完整保留、活跃上限 60。提交前 diff 检查通过，无业务/资源/依赖删除。
本阶段只完成 Native state 和业务边界，不能据此宣称搜索网络或存储已原生化。

下一步：P04a URLSession/decoder fixture。并行审查已写入 [SEARCH.md](SEARCH.md)：
Native HTTP runtime 切换必须保留 recommend 账户与 Cookie 语义，
P04a fixture -> P05a context lease -> P04b hybrid cutover。
Dart 业务仍完整保留，整体原生化目标仍在进行中。
