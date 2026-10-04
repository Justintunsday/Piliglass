# PiliGlass 原生玻璃设计规范

2026-10-04，适用于 UI 重设计；用户已选定原生玻璃方向。

## 已有品牌与视觉决策

继续使用仓库 AppIcon 中的白底粉色 Bilibili 标志，不重新生成 Logo、不替换现有资源。
`PiliNativeDesign.swift` 已定义 #FB7299 品牌强调色。新 UI 使用一处克制粉色强调，
不把所有正文和大面积背景染粉。正文、封面和真实推荐内容优先于装饰。

| 用途 | 规范 |
|---|---|
| 品牌强调 | #FB7299，现有 piliAccent；用于选中 tab、动作和小面积标识 |
| 强调文字 | 浅色 #A52B51 / 深色 #FF97B2，现有动态 accentText |
| 页面背景 | systemGroupedBackground，随系统浅色/深色变化 |
| 内容表面 | secondarySystemGroupedBackground，避免玻璃透过视频标题 |
| 次要填充/分隔 | tertiarySystemFill / separator；以语义系统值适配外观 |
| 正文与元数据 | primary / secondary；封面上时长使用白字及深色底 |
| 显示与正文 | 系统 SF 字体，largeTitle bold / title2 semibold / body / caption；数字可 monospacedDigit |
| 间距 | 8pt 主网格：8、16、24、32；4pt 仅图标和元数据微间距 |
| 圆角 | 保留公共 8/14/18pt tokens；搜索入口使用 Capsule |
| 触控 | 最小 44pt；放大字体时允许增加高度 |
| 阅读宽度 | 960pt 最大内容宽度；页面不读取 UIScreen 固定尺寸 |
| 封面 | 16:9，占位和加载成功使用同一布局边界 |

这是仓库既有品牌的延伸；系统语义颜色按运行时解析，不能伪称有五种官方品牌 HEX。
中文标题使用系统字体保证可读和 Dynamic Type，不为满足示例强塞装饰衬线字体。

## 材质与布局

系统 tab/navigation 保留原生行为。自定义搜索入口是首页的材质细节：轻盈、可点击、
与视频流有明确层级。iOS 26 可用时使用原生 Liquid Glass；旧系统 Material。读取系统
accessibilityReduceTransparency，为该控制提供实色回退。玻璃不铺满内容卡片。

首页用完整双列封面流代替现有大首卡加长列表；推荐首项与其他项地位一致，所有数据
保持真实。辅助大字体改为单列，文本不固定高度截断；VoiceOver 读完整标题和元数据。
无营销 hero、虚构推荐标签/栏目、渐变装饰或无行为入口。功能图标使用 SF Symbols。

## 验收

实际 simulator 浅/深/大字体截图检查后才记录五维评分。过渡动画继续尊重系统减少
动态效果设置；视频 zoom 标识和导航返回关系不得因布局改变丢失。设计与业务原生化
分别记录状态，截图里的离线 fixture 明确标注，不当作真实账号或 Bilibili API 验收。
