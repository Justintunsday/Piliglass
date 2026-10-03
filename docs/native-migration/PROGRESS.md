# 迁移进度与编译证据

最后更新：2026-10-03（Asia/Hong_Kong）。目标仍在进行，Flutter runtime 保留。

| 阶段 | 阶段代码 Commit | iOS release | Preview | 状态 |
|---|---|---|---|---|
| 起点 | 8044a8d | [成功](https://github.com/Justintunsday/Piliglass/actions/runs/36085475142) | [分页检查失败](https://github.com/Justintunsday/Piliglass/actions/runs/36085470278) | 仅基线 |
| P00 | 603d3c6 -> ad0e8b5 | [成功](https://github.com/Justintunsday/Piliglass/actions/runs/37132297374) | [全部成功](https://github.com/Justintunsday/Piliglass/actions/runs/37132297176) | 基线与迁移计划完成 |
| P01a | b906383 -> c783318 | [成功](https://github.com/Justintunsday/Piliglass/actions/runs/37133641553) | [全部成功](https://github.com/Justintunsday/Piliglass/actions/runs/37133641528) | 首批组件边界完成 |

P00 证据：inventory 包含 59 个 bridge commands、62 个注册 Flutter routes、311 个 REST 常量、45 个 gRPC 常量、95 个依赖。压力检查 `failures=[]`，1,000 条评论保持懒加载、未在离屏处触发分页、实际末条出现后分页成功；100,000 条弹幕保留，活跃渲染上限 60。仅测试 harness 调整了懒加载自适应行定位等待；没有修改生产 UI 或业务。

P00 实际 Actions 工具链：Xcode 26.6 / Apple Swift 6.3.3；Runner 仍以 Swift 5 language mode 构建。release 日志确认 Aether FFmpeg 在 media-kit FFmpeg 之前链接。

P01a 范围：从 Root 抽出 Flutter player surface，从 Player 抽出诊断日志与同步 HTTP range IOReader。保留 child containment、缓存/seek/取消和所有 fallback；同步扩展 localization checker 到 Native 子目录。逐类型对比移动前后正文，仅放宽两个 file-private 类型到 Runner 内部可见。

P01a 验证：当前阶段代码 `c783318d8e13f93061b2ce5f6ed3cd9153097593` 的完整 iOS release 编译和 FFmpeg 链接顺序检查通过；preview 的 account-pages、image-preview、player-controls、preview 四个 jobs 全通过。本地 staged diff 检查通过；没有删除业务、资源或依赖。类型正文一致性与本地 source extractor 检查只作为提交前检查，完成依据是上述真实 Actions。

下一步：P01b 抽出 DesignSystem/codec，同步集中 preview 源读取；随后做 Feature UI 拆分与 Native Repository 接口。Dart 业务仍完整保留，整体原生化目标仍在进行中。
