# iOS 原生弹幕筛选移植

对照来源：guozhigq/pilipala 主分支提交
`06f23f67ca61f22db42ebabd9b979b2c2f4fa808`，重点为
`lib/pages/video/detail/widgets/header_control.dart`、
`lib/pages/danmaku/view.dart`。项目继续沿用仓库的 GPL-3.0 许可。

原版主分支提供顶部、底部、滚动和彩色弹幕设置，以及显示区域、
不透明度、字体、描边、时长设置。其中彩色选项将文字变为白色，
并不丢弃弹幕。PiliGlass 所保留的 PiliPlus Dart 层另有高级弹幕、
智能云屏蔽（0–11 级）、关键词/正则/用户规则，本次也接入原生 UI。

## 使用与数据

- 竖屏弹幕栏右侧的筛选按钮、全屏播放器的弹幕设置均进入原生设置。
- 顶部和底部分别控制；滚动包含逆向弹幕；不再将“计数”误接到逆向屏蔽。
- 设置即时作用于同一个播放会话，横竖屏共享；使用原有 Hive 设置键保存。
- “关键词 / 正则 / 用户”中可新增、编辑、删除；用户规则输入 UID，
  复用原有 CRC32 转换，展示与弹幕 midHash 相同的哈希。
- 本地规则未登录亦可使用。登录后可选择保存到账号，或同步账号规则。
  同步为从服务端刷新账号规则，不会上传或删除本地规则。
- 规则缓存按账号隔离，旧 compiled RuleFilter 缓存首次读取时迁移一次。
  网络失败保留原缓存；云端编辑先添加后删除，部分成功会明确提示。
- 原始弹幕保留在串行工作队列中，筛选在合并之前进行；修改或删除规则后
  重新计算缓存，避免被屏蔽用户的同文弹幕吞掉正常用户弹幕。
- 正则在 Dart 端校验；原生使用系统 JavaScriptCore 的 ECMAScript RegExp，
  与 Dart 正则规则保持同类语义，避免 ICU 的 `\w` 等匹配范围差异。
  用户输入通过参数传给 RegExp 构造器，不作为脚本执行。
- 模式 8/9 的代码/BAS 不当作普通文字渲染；本次未实现这些渲染器。

## 验证

运行 `python3 tool/check_native_danmaku.py`（可用 `--dart` 指定 Dart 路径）。
脚本提取生产服务、模型和匹配代码，仅替换账号、HTTP、Hive 边界；
使用真正的 archive CRC32 与 synchronized 锁。覆盖迁移、验证、CRUD、
失败保留、云端部分成功、账号切换、并发写入等 30 项检查，并执行 Dart analyze。
不使用真实账号或对 Bilibili 发起写请求。

macOS 上先运行 `python3 tool/preview_ios_home.py`，然后运行
`python3 tool/check_ios_video_load.py`。后者提取生产 Swift 筛选、缓冲和渲染代码，
覆盖类型与权重边界、ECMAScript 正则、合并前筛选、规则删除后恢复、
彩色转白、设置清屏，以及原有十万条弹幕/评论性能检查。

已将 Dart 检查接入 iOS 构建工作流；Swift 渲染检查继续使用现有模拟器工作流。
Windows 本地不能执行 Xcode/iOS 模拟器检查，仍需在 macOS/CI 编译并验证
设置页布局、横竖屏切换和实际登录后的服务端同步。脚本中的模拟账号测试
不能代替这些检查。
