# P11/P12：剩余页面覆盖与 Flutter runtime 退出准备

2026-10-05，P05 Policy-1 CI 期间准备；没有移除页面、Dart 或 Flutter 依赖。
目标仍按 PLAN.md 为 iOS 完整业务原生化，UI 视觉重写在主线完成后执行。

## 已有的实际依赖

当前 inventory 为 62 bridge commands、62 注册 GetPage routes、95 个 pub dependencies。
它只索引 `lib/router/app_pages.dart` 和 bridge switch，不覆盖全部 `Get.to` builder、
sheet/dialog、动态链接和平台插件调用；数字归零不能单独证明功能没有遗漏。
登录设备/记录、文章/网页、课程/音乐、投屏/WebDAV、设置导入/导出和诊断等辅助
功能仍需按原调用点审计，不能只验收首页、详情、播放三页。

实际入口：AppDelegate 继承 FlutterAppDelegate，implicit engine 注册插件；
SceneDelegate 继承 FlutterSceneDelegate，再将 FlutterViewController 包进 NativeRoot。
Root 直接持有 MethodChannel、FlutterPlayerSurface 和聚合状态。Podfile 读取
Flutter/Generated.xcconfig、podhelper 并安装全部 Flutter pods；PBX 有 Flutter build/
embed_and_thin。现有 ios.yml 仍先安装 Flutter，再 patch、生成依赖和构建 Runner。
这些都尚未符合无 Flutter SDK 的验收条件。

Aether 使用独立 SPM FFmpegBuild/LibDovi，不依赖 Flutter；当前最终 Mach-O 仍同时
有 media-kit 路径的 FFmpeg，因此保持既有 load-order 检查。删除 Flutter 播放路径时
再检查 Aether 自有 FFmpeg 的嵌入/签名/架构与符号，不能一起删掉整个播放依赖。
Podfile 的本地 SwiftgramUI 是 Native messaging primitives，逐项按真实 caller 保留，
不因移除 Flutter 而自动移除所有 CocoaPods。

## P11：逐功能迁移与页面删除

1. 在 P06–P10 各领域继续建 typed Feature State/Repository/Domain，穿插 P02b 拆分
   Root/Player。按 source owner 拆 DTO、route registry、公共 UIKit/SwiftUI 支持，
   不用把大文件改名移动来代替边界。每个领域保持小 commit、既有外观和全部行为。
2. 固定机器可检查的 route coverage：原注册 route + 参数/导航副作用 + builder/modal/
   inbound URL + Native Feature/Repository + 迁移状态/实际验收证据。新增/删除 route
   自动要求更新表；Web/WKWebView 是明确的 Native feature，不用空页面顶替旧功能。
3. 用领域 Native 数据源绑定当前界面，校验 loading/empty/error/分页、动作、风控、
   account 选择、返回手势、状态恢复、离线/取消。Native feature 能展示但 Repository
   仍转发 Dart 时最多是 B，不能进入旧代码可删除的 R。
4. 每个旧页面及其特有 controller 只有在全部 iOS caller 切为 Native、业务/资源/
   数据迁移验收成功后才删除。共享 model/service 若仍有活跃 caller 继续保留；
   不因“Native 主入口没有直接引用”跳过动态 Dart route 或插件层调用。
5. 实际 Runner composition 的 integration/UI tests 覆盖核心及剩余路径、参数转发、
   登录边界/深链/冷启动。当前抽取式 preview 与 offline fixtures 继续做展示回归，
   但不当作真实业务/Repository 绑定已经 Native 的证据。

最终 UI 核心矩阵包括播放器、登录、首页、视频详情/评论、动态、用户、收藏、历史、
搜索、私信、直播、下载和原辅助功能。真机后台/登录业务证据与 CI 编译分别记录；
不能从模拟器画面推导网络、Cookie、gRPC、消息或数据导入已经等价。

## P12：分步退出 Bridge 与 runtime

1. 每领域完成 Native authority/实际功能对照后，移除该领域 Swift Dart adapter 和
   channel 命令，再移除已无 caller 的 Dart bridge/helper。callback、lease terminal、
   TTL/dispose 不留悬挂写入；未知结果不自动换另一实现重发。每组独立 commit+全 CI。
2. 先新增 Native-only app composition/入口构建演练，使用实际 Native Repository，
   以同一套核心路径通过编译/启动/业务 fixture。不能用空 stub/no-op 返回值掩盖
   缺失领域；必要阶段现有 Runner/Flutter fallback 同时保留，未验证前不删 engine。
3. Native app lifecycle 接管 Scene/window、URL/open-file、通知、background session
   completion、权限、照片/分享/网页 Cookie、剪贴板、音频中断和配置恢复。替代每个
   Flutter plugin 的实际用途，不只删 GeneratedPluginRegistrant 来获得编译通过。
4. 把仍使用的图片/字体/emoji/本地化/许可证/配置映射到 Native bundle，保存资源
   清单和实际加载验证。Flutter assets 不代表全部无用；不能因原加载方式改变丢资源。
5. Native-only 真正可用且 route/command 覆盖无遗漏后，切入口、移除 Flutter SDK
   imports/classes、FlutterPlayerSurface、MethodChannel、engine 和 Dart runtime。
   同阶段更新 PBX/xcconfig/Podfile/锁文件/构建脚本与 workflow，不留下隐藏 SDK 路径。
6. 逐组删已无活跃 caller 的 Dart 业务和无用依赖；仓库仍有其他平台 workflow，按
   已确认的 iOS 主线范围处理共享源码，其他平台不能成为保留 iOS Dart runtime 的理由。
   在最新 inventory 和真实 caller graph 上逐项检查，不一次盲删 lib/assets/pubspec。

## 完成验证与回滚

新增 Native build job 不安装/patch Flutter，清洁 workspace 无 FLUTTER_ROOT，使用
固定 Native 依赖构建并产出实际 Runner IPA；检查包中 framework/Mach-O/资源，不
只看 `rg Flutter`。SPM/Pods 的原生依赖仍可按固定锁文件解析，离线缓存演练在依赖
已准备后运行，不把网络下载失败误认为 Dart 依赖已消失。

ios.yml 原完整构建门禁切为实际 Native build；ios-home-preview 同时按最终 composition
更新，保留导航/持久化/播放器/图片/账户/压力覆盖。所有 jobs 同 SHA 成功；核心数据
路径无需 Dart、旧账户/下载/设置导入可重启恢复、深链/后台/播放器仍通过后才记录完成。
每个删除阶段保存撤回方式和数据兼容材料，入口/构建依赖回滚必须与其协议/数据切片
一起处理，不能仅恢复一个 Swift 文件便宣称已恢复旧 runtime。

UI_REDESIGN.md 和 brand-spec.md 保留原生玻璃方向，最后基于已完成的 Native Feature
状态/Repository 改造视觉、导航和公共组件；不把视觉成果计入当前 P05/P11 的业务完成率。
