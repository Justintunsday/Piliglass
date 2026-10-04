# PiliGlass 原生 UI 重设计执行计划

2026-10-04。用户已选择「iOS 原生玻璃感：克制配色、清晰层级、轻盈材质」。
用户随后明确顺序：先继续 PLAN.md 原生化主线，最后再进行 UI 重写。
本文件保留设计方向与执行方案；所有 UI 重设计暂缓，未修改生产 UI。
当前先完成 P05a2a 失败修复与 CI 闭环，再继续 P05a2b 及后续业务迁移。
设计规范见 [brand-spec.md](brand-spec.md)。

## 目标与保留范围

真正重新设计页面布局与公共组件，而非只改颜色。视频封面和内容是视觉主体；玻璃用于
导航、搜索入口等操作区域，正文使用清晰的实色表面。继续使用系统 TabView 和
NavigationStack，保持配置中的 tab 顺序、切换状态、push/back、sheet/fullScreenCover、
视频转场及播放器生命周期。iOS 16 仍为部署基线；iOS 26 的玻璃 API 按可用性启用。

页面只读取 Feature state 并发送用户动作；不加入 HTTP、Cookie、gRPC 或存储逻辑。
Home 的第一步使用窄状态协议转发现有业务，后续再接 HomeRepository。AetherEngine
保持独立，UI 重设计不把 Bilibili 业务加入播放内核，也不删除现有 Flutter 页面或入口。

## 可回滚阶段

| 阶段 | 页面和模块交付 | 功能保留与验证 | 状态 |
|---|---|---|---|
| UI01 | 拆出 Home state/feed/poster card；双列封面推荐流、轻盈搜索入口、公共玻璃组件 | 完整推荐列表、刷新、分页、首条预加载、搜索、账户、消息、视频打开/关闭；浅色/深色/大字体实际截图；release + 全 preview | 方案已保存；按用户顺序暂缓，原生化主线后实施 |
| UI02 | 动态与我的/账户页面；统一列表、空态、功能入口和导航层级 | 动态详情/互动、登录/退出、多账户、收藏/历史/稍后看/设置等入口不丢；账户与导航实际 fixture | 待实施 |
| UI03 | 视频详情、评论与播放器外围呈现；继续拆出巨型 Root/Player 文件 | 分 P/合集/番剧、字幕/弹幕/清晰度、互动/评论回复、横屏/PiP、seek 与返回；播放器 controls 和压力报告 | 待实施 |
| UI04 | 搜索、用户空间、收藏/历史等 Library 页面 | 全搜索类型/筛选/历史、关注、文件夹/分页/续播/批量操作；领域 fixture + 导航回归 | 待实施 |
| UI05 | 私信、直播、下载及剩余页面按领域重设计 | 会话/未读/发送、直播房间/弹幕、下载暂停/恢复、全部既有路由；原生业务门禁单独保留 | 待实施 |

每个阶段允许进一步拆为独立提交；每个代码切片先完成实际 release 和全部 preview，
读取日志修复失败，再进入下一切片。UI01 成功只代表首页阶段，不能宣称整个 UI 或业务
已完成。UI02 以后的具体参数/状态须先阅读对应现有页面后保存领域保留矩阵。

## UI01 实施边界

- Root 保留薄 Home NavigationStack wrapper、toolbar 与 PrimaryDestinations。独立
  `Native/Features/Home/` 通过 `@MainActor ObservableObject` 状态协议读取 typed video
  和 loading/error 状态；动作只调用现有 refresh/loadMore/search/openVideo/prewarm。
- 所有推荐统一进入 LazyVGrid，不丢弃第一条。常规字体双列，辅助大字体单列；封面
  明确 16:9 布局，标题、作者、时长及已有播放/弹幕数据可读。仅末条出现触发分页，
  保留 `home:<video.id>` 转场标识和首卡预加载。不给未实现的热门/排行等假入口。
- 公共玻璃组件放 DesignSystem；iOS 26 使用原生 glassEffect，iOS 16–25 使用 Material，
  系统减少透明度时为实色。系统 TabView 自身外观与交互继续由 iOS 管理。
- 预览 fixture 直接展开生产 Swift 文件，新增文件注册 Runner；Home fixture 和导航
  fixture 的窄协议同步，继续验证原有页面与手势。不得用假页面替代待测生产内容。

## 验证方法

本地仅检查 source expansion、Python syntax、项目注册、diff 和资源/依赖删除。Windows
无法提供 iOS 编译证据。提交并 push 后核对 `.github/workflows/ios.yml` 与
`ios-home-preview.yml` 的 headSha，保存实际编译日志、XCUITest 和截图报告。

视觉检查至少覆盖浅色、深色、辅助大字体、首屏/末屏、安全区域和封面尺寸；检查 44pt
触控与 VoiceOver 的完整标题/元数据。五维设计评审记录视觉层级、品牌、空间、精致度
与可用性，每项低于 7/10 则继续修复，不能只根据代码评分。减少透明度若仅用测试
override，报告明确只是分支验证；系统设置兼容须实际设置并读取系统值。

同时保留已有 Search/HTTP/Cookie/accounts checks、FFmpeg load order、账户/图片/播放器
preview，以及 1,000 评论/100,000 弹幕压力门禁。不降低断言来通过 CI。

采用用户提供的 SwiftUI/interop/architecture skills 及本地 SwiftUI design skill；
其新应用版本和风格示例不覆盖项目 iOS 16 兼容性及用户选定的原生玻璃方向。
