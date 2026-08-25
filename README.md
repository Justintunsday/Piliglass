<div align="center">
    <img width="200" height="200" src="assets/images/logo/logo.png">
</div>



<div align="center">
    <h1>PiliGlass</h1>
<div align="center">

[![Build iOS Native UI](https://github.com/Justintunsday/Piliglass/actions/workflows/ios.yml/badge.svg)](https://github.com/Justintunsday/Piliglass/actions/workflows/ios.yml)
![GitHub repo size](https://img.shields.io/github/repo-size/Justintunsday/Piliglass)
![GitHub Repo stars](https://img.shields.io/github/stars/Justintunsday/Piliglass)
![GitHub all releases](https://img.shields.io/github/downloads/Justintunsday/Piliglass/total)
</div>
    <p>基于 PiliPlus 的第三方 BiliBili 客户端，提供 SwiftUI/UIKit iOS 原生界面</p>
    
<img src="assets/screenshots/510shots_so.png" width="32%" alt="home" />
<img src="assets/screenshots/174shots_so.png" width="32%" alt="home" />
<img src="assets/screenshots/850shots_so.png" width="32%" alt="home" />
<br/>
<img src="assets/screenshots/main_screen.png" width="96%" alt="home" />
<br/>
</div>


<br/>

## PiliGlass iOS 原生版

PiliGlass 在保留 PiliPlus 网络协议、登录状态和功能实现的基础上，为 iOS 提供 SwiftUI/UIKit 原生前端。目前原生播放器版本支持 iOS 16 及以上系统。

- 首页、动态、我的、用户主页、设置、视频详情和评论等界面由 SwiftUI/UIKit 呈现。
- 播放详情页和控制层均保持 SwiftUI/UIKit 原生结构，不再嵌套 Flutter 播放页面。
- 消息中心与聊天页直接调用本地 `SwiftgramUI` 原生模块；该模块从 Swiftgram/Telegram-iOS 的消息列表、气泡与输入栏源码裁剪适配，BiliBili 私信数据仍由 PiliGlass 桥接层提供，来源及 GPL 声明见 `ios/SwiftgramUI/NOTICE.md`。
- iOS 播放内核采用 [AetherEngine](https://github.com/superuser404notfound/AetherEngine)：由 FFmpeg 解析视频轨道，并通过 Apple 原生 VideoToolbox/AVPlayer 显示链路输出；BiliBili DASH 独立音轨继续由 AVPlayer 播放并跟随视频时钟同步。
- 保留画质选择、分 P、弹幕、字幕、倍速、手势、画中画和全屏控制，并针对 4K、HDR10 与杜比视界走原生 HDR/EDR 显示链路。实际可用画质及 HDR 效果仍取决于账号权限、视频源、设备解码与屏幕能力以及网络状况。
- 登录、点赞、投币、收藏、评论、回复与动态互动继续复用原有请求层。

> 本项目仍在持续原生化和修复中。若遇到播放器或交互问题，请在 Issue 中附上设备型号、iOS 版本、视频 BV 号和复现步骤。

## 适配平台

- [ ] Android
- [x] iOS
- [x] Pad
- [ ] Windows
- [ ] Linux

[![Packaging status](https://repology.org/badge/vertical-allrepos/piliplus.svg)](https://repology.org/project/piliplus/versions)

## refactor

- [ ] gRPC [wip]
- [x] 用户界面
- [x] 其他

## feat

- [x] 编辑动态
- [x] DLNA 投屏
- [x] 离线缓存/播放
- [x] 移动端支持点击弹幕悬停，点赞、复制、举报 by [@My-Responsitories](https://github.com/My-Responsitories)
- [x] 播放音频
- [x] 跳过番剧片头/片尾
- [x] 安卓端 `loudnorm` 适配 by [@My-Responsitories](https://github.com/My-Responsitories)
- [x] Win/Mac 支持极验、短信登录 by [@My-Responsitories](https://github.com/My-Responsitories)
- [x] 视频截取动图 by [@My-Responsitories](https://github.com/My-Responsitories)
- [x] AI 原声翻译
- [x] SuperChat
- [x] 播放课堂视频
- [x] 发起投票
- [x] 发布动态/评论支持`富文本编辑`/`表情显示`/`@用户`
- [x] 修改消息设置
- [x] 修改聊天设置
- [x] 展示折叠消息
- [x] 查看用户图文
- [x] 动态话题
- [x] 直播分区
- [x] 分享`视频`/`番剧`/`动态`/`专栏`/`直播`至消息
- [x] 创建/修改/删除关注分组
- [x] 移除粉丝
- [x] 直播弹幕发送表情
- [x] 收藏夹排序
- [x] 稍后再看 ~~`未看`~~ / `未看完` / ~~`已看完`~~ 分类
- [x] WebDAV 备份/恢复设置
- [x] 保存评论/动态
- [x] 高级弹幕 by [@My-Responsitories](https://github.com/My-Responsitories)
- [x] 取消/置顶评论
- [x] 记笔记
- [x] 多账号支持 by [@My-Responsitories](https://github.com/My-Responsitories)
- [x] 屏蔽带货动态/评论
- [x] 互动视频
- [x] 发评/动态反诈
- [x] 高能进度条
- [x] 滑动跳转预览视频缩略图
- [x] Live Photo
- [x] 复制/移动/排序收藏夹/稍后再看视频
- [x] 超分辨率
- [x] 合并弹幕
- [x] 会员彩色弹幕
- [x] 播放全部/继续播放/倒序播放
- [x] Cookie登录
- [x] 显示视频分段信息
- [x] 调节字幕大小
- [x] 调节全屏弹幕大小
- [x] 收藏夹/稍后再看多选删除
- [x] 搜索用户动态
- [x] 直播弹幕
- [x] 修改头像/用户名/签名/性别/生日
- [x] 创建/编辑/删除收藏夹
- [x] 评论楼中楼查看对话
- [x] 评论楼中楼定位点击查看的评论
- [x] 评论楼中楼按热度/时间排序
- [x] 评论点踩
- [x] 私信发图
- [x] 投币动画
- [x] 取消/追番，更新追番状态
- [x] 取消/订阅合集
- [x] SponsorBlock
- [x] 显示视频完整合集
- [x] 三连动画
- [x] 番剧三连
- [x] 带图评论
- [x] 视频TAG
- [x] 筛选搜索
- [x] 转发动态
- [x] 合集图片
- [x] 删除/置顶/撤回私信
- [x] 举报用户/评论/视频/动态
- [x] 删除/发布/置顶文本/图片动态
- [x] 其他

## opt

- [x] 专栏界面
- [x] 私信界面
- [x] 收藏面板
- [x] PIP
- [x] 视频封面
- [x] 回复界面
- [x] 系统通知
- [x] 评论显示
- [x] 亮度调节
- [x] 视频播放
- [x] 视频staff
- [x] 防止bottomsheet遮挡全屏视频
- [x] 其他

## fix

- [x] 番剧分集点赞/投币/收藏
- [x] bugs

<br/>

## 功能

- [x] 推荐视频列表(app端)
- [x] 最热视频列表
- [x] 热门直播
- [x] 番剧列表
- [x] 屏蔽黑名单内用户视频
- [x] 无痕模式（播放视为未登录）
- [x] 游客模式（推荐视为未登录）

- [x] 用户相关
  - [x] 粉丝、关注用户、拉黑用户查看
  - [x] 用户主页查看
  - [x] 关注/取关用户
  - [x] 离线缓存
  - [x] 稍后再看
  - [x] 观看记录
  - [x] 我的收藏
  - [x] 站内私信
  
- [x] 动态相关
  - [x] 全部、投稿、番剧分类查看
  - [x] 动态评论查看
  - [x] 动态评论回复功能

- [x] 视频播放相关
  - [x] 双击快进/快退
  - [x] 双击播放/暂停
  - [x] 垂直方向调节亮度/音量
  - [x] 垂直方向上滑全屏、下滑退出全屏
  - [x] 水平方向手势快进/快退
  - [x] 全屏方向设置
  - [x] 倍速选择/长按2倍速
  - [x] 硬件加速（视机型而定）
  - [x] 画质选择（高清画质未解锁）
  - [x] 音质选择（视视频而定）
  - [x] 解码格式选择（视视频而定）
  - [x] 弹幕
  - [x] 字幕
  - [x] 记忆播放
  - [x] 视频比例：高度/宽度适应、填充、包含等
     
- [x] 搜索相关
  - [x] 热搜
  - [x] 搜索历史
  - [x] 默认搜索词
  - [x] 投稿、番剧、直播间、用户搜索
  - [x] 视频搜索排序、按时长筛选
    
- [x] 视频详情页相关
  - [x] 视频选集(分p)切换
  - [x] 点赞、投币、收藏/取消收藏
  - [x] 相关视频查看
  - [x] 评论用户身份标识
  - [x] 评论(排序)查看、二楼评论查看
  - [x] 主楼、二楼评论回复功能
  - [x] 评论点赞
  - [x] 评论笔记图片查看、保存

- [x] 设置相关
  - [x] 画质、音质、解码方式预设      
  - [x] 图片质量设定
  - [x] 主题模式：亮色/暗色/跟随系统
  - [x] 震动反馈(可选)
  - [x] 高帧率
  - [x] 自动全屏
  - [x] 横屏适配
- [ ] 等等

<br/>

## 下载

推荐从 [GitHub Actions 的 iOS 工作流](https://github.com/Justintunsday/Piliglass/actions/workflows/ios.yml) 下载最新成功构建：

1. 打开最新的成功运行记录。
2. 在页面底部找到 `Artifacts`。
3. 下载 `PiliPlus_ios_*.ipa` 构建产物。

已发布的稳定版本也可以从仓库右侧的 Releases 下载。IPA 未包含正式签名，安装前需要使用你自己的证书签名。

仓库的 `.github/workflows/ios.yml` 使用 GitHub Actions 自动完成 Flutter 依赖准备、iOS Release 编译、IPA 打包和产物上传。

<br/>

## 声明

此项目（PiliGlass）完全由 Codex 完成开发。

本项目仅用于兴趣学习和测试，请于下载后24小时内删除。
所用API皆从官方网站收集，不提供任何破解内容。
在此致敬原作者：[guozhigq/pilipala](https://github.com/guozhigq/pilipala)
在此致敬上游作者：[orz12/PiliPalaX](https://github.com/orz12/PiliPalaX)
本仓库做了更激进的修改，感谢原作者的开源精神。

感谢使用


<br/>

## 致谢

- [bilibili-API-collect](https://github.com/SocialSisterYi/bilibili-API-collect)
- [flutter_meedu_videoplayer](https://github.com/zezo357/flutter_meedu_videoplayer)
- [media-kit](https://github.com/media-kit/media-kit)
- [dio](https://pub.dev/packages/dio)
- 等等

<br/>
<br/>
<br/>

## Star History

<a href="https://star-history.dera.page/#Justintunsday/Piliglass&Date">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://star-history.dera.page/svg?repos=Justintunsday/Piliglass&type=Date&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://star-history.dera.page/svg?repos=Justintunsday/Piliglass&type=Date" />
   <img alt="Star History Chart" src="https://star-history.dera.page/svg?repos=Justintunsday/Piliglass&type=Date" />
 </picture>
</a>
