---
version: alpha
name: Tunailscale Design System
description: Seafoam green theme inspired by official Tailscale iOS app with TrollStore native utun features
colors:
  primary: "#0D9488"
  primaryFill: "#0F766E"
  primaryLight: "#14B8A6"
  accent: "#2DD4BF"
  success: "#10B981"
  warning: "#F59E0B"
  danger: "#EF4444"
  background: "#090A0A"
  surface: "#18181B"
  surfaceLight: "#27272A"
  border: "#3F3F46"
  textPrimary: "#F4F4F5"
  textSecondary: "#A1A1AA"
typography:
  title:
    fontFamily: SF Pro
    fontSize: 24px
    fontWeight: 700
  body:
    fontFamily: SF Pro
    fontSize: 17px
    fontWeight: 400
  menu:
    fontFamily: SF Pro
    fontSize: 17px
    fontWeight: 600
  detail:
    fontFamily: SF Pro
    fontSize: 15px
    fontWeight: 400
  mono:
    fontFamily: SF Mono
    fontSize: 13px
    fontWeight: 500
rounded:
  card: 8px
  button: 8px
  indicator: 9999px
spacing:
  base: 4px
  cardPadding: 16px
  screenMargin: 16px
---

# Tunailscale Design System

## Overview
极致纯净的原生系统级设计，全面参照原版 Tailscale iOS App 的极简美学，融入海沫绿（Seafoam Green / Mint / 青色）科技视觉。专属针对 TrollStore 免越狱原生 utun 内核通道深度定制，中英文自适应跟随系统。

## Colors
- 主品牌色 (Primary): `#0D9488` (深邃海沫青，按钮与主要焦点)
- 白字按钮底色 (PrimaryFill): `#0F766E`，保证普通字号文字至少4.5:1对比度。
- 明亮海沫绿 (PrimaryLight): `#14B8A6` (高亮海沫绿，开关打开状态与连接成功状态)
- 点缀青翠 (Accent): `#2DD4BF` (呼吸光环与重要指标指示)
- 成功状态 (Success): `#10B981` (网络打通与就绪)
- 警示状态 (Warning): `#F59E0B` (连接中/认证中)
- 断开/危险状态 (Danger): `#EF4444` (退出登录/核心断开)
- 暗黑背景底色 (Background): `#090A0A` / 动态系统深色 (`systemBackgroundColor`)
- 单层卡片底色 (Surface): `#18181B` / 动态次级深色 (`secondarySystemBackgroundColor`)
- 悬浮/选中底色 (SurfaceLight): `#27272A`
- 边框分割线 (Border): `#3F3F46` (0.5px 极细微分割线)
- 主文本颜色 (TextPrimary): `#F4F4F5`
- 次文本颜色 (TextSecondary): `#A1A1AA`

## Typography
- 主状态大标题: SF Pro，24pt/26pt，加粗 (Bold)
- 导航与顶栏标题: SF Pro，17pt，半粗体 (Semibold)
- 菜单与操作: SF Pro，17pt，半粗体 (Semibold)；同类入口统一字重与字号。
- 正文: SF Pro，17pt，常规体 (Regular)；次级数据15pt。
- 专有指标与 IP: SF Mono，13pt，等宽中粗体 (Medium)
- 使用原生语义字体随系统文字大小缩放；状态标题默认26pt并支持动态缩放。

## Layout
- 全局基础间距步长: 4px 基数阶梯 (4px, 8px, 12px, 16px, 20px, 24px)
- 屏幕安全边距: 16px
- 单层卡片内边距: 16px
- 用户于2026-10-22确认保留16pt安全边距、8pt自绘圆角和系统分组列表；4pt作为间距步长，不将整页压缩为4pt。
- 所有图标按钮至少44×44pt，列表行至少48pt；按钮用最小高度而非固定高度，避免大字裁切。
- 整体架构严格参照原版：
  1. 顶部 Header 状态栏：左侧开关 Switch + 登录身份；右侧圆形账户设置入口。
  2. 中间大核心区域：居中大电源图标、醒目连接状态大字、副文本说明、海沫绿大药丸操作按钮。
  3. 独家特性单层分组（TrollStore 专属）：原生 utun 通道状态、免 VPN 状态、核心进程 PID、接口指标。
- 绝无任何卡片嵌套，所有卡片均为独立平铺单层。

## Elevation & Depth
- 沉浸式暗黑平面极简层级。
- 按钮采用平滑海沫绿渐变或纯色轻微微光，不采用繁杂拟物深阴影。
- 依靠 `#18181B` 模块化卡片与微边框实现清晰区域划分。

## Shapes
- 单层卡片圆角: 8px 平滑圆角
- 核心操作大按钮: 8px 药丸/平滑大圆角
- 状态电源图标: 大圆形外环 (80x80px 居中圆环)
- 状态圆点: 9999px (完全圆形)

## Components
1. **顶栏控制器 (HeaderBar)**：
   - 左侧为海沫绿 UISwitch 状态开关与连接身份摘要（文字≤13字）；
   - 右侧为圆形个人账户/设置按钮。
2. **中心状态大电源区 (PowerCenterView)**：
   - 大尺寸电源符号图标（海沫绿光泽）；
   - 状态标题（如「未连接」「已连接」）；
   - 一键连接/断开海沫绿宽幅大按钮（文字≤13字）。
3. **独家特性卡片 (UtunPrivilegeCard)**：
   - 独家 TrollStore 原生 utun 特性看板（通道模式：内核直通免VPN；网络接口：utun5；守护进程：运行中）；
   - 严格单层，每行双侧对齐。
4. **设置与账户模态页 (SettingsSheet)**：
   - 参照原版弹窗页面：账户信息、Headscale自定义服务器、AuthKey快速入网、重认证与退出登录。
5. **系统语言国际化 (Localization)**：
   - 自动检测并跟随系统首选语言（简体中文 / 英文）。
   - 中英文之间无空格，标签字数≤13字。
6. **列表与工具栏**：
   - 列表统一系统分组外观；菜单使用SF Symbols与17pt半粗体，文件名等数据使用17pt正文。
   - 关于页、设置页、账户页的前导头像及小图标共用44pt图标列，图形水平居中，距右侧文字14pt；保留40/44pt头像与语义字号的小图标，不以放大素材补偿偏移。忙碌指示放在动作文字后，不挤移图标列。
   - 刷新、导出、关闭使用系统图标并提供辅助功能名称；连接、登录等关键动作保留文字。
   - iOS无悬浮鼠标提示，说明统一通过44pt信息按钮点击打开系统提示；不常驻页面。
   - 账户、设备名、文件名、URL、时间与诊断正文是用户数据，不按13字截断原始内容；紧凑行自动滚动，辅助功能保留全名。
   - 成功、错误、传输进度及删除警告属于操作反馈，不能为减字隐藏。
   - 用户于2026-10-22选择固定单行自动滚动：仅超宽数据文本使用24pt/秒原生往返动画，两端停顿；后台、离页停止，减少动态效果时完整换行。不得用省略号隐藏数据。
   - 主页设备图标使用28pt固定列，名称在上、IP在下；不同设备图形必须共用图标与文字起点。
   - 主页完整列出设备，在线优先并按名称与IP稳定排序；整页纵向滚动，不截取前三台。设备图标右下角用绿点表示在线、红点表示离线，离线文字使用次级色，辅助功能保留状态名称。
   - 本机与设备IP统一使用原生长按复制菜单，提供辅助功能复制操作；复制完整IPv4或IPv6地址，不增加常驻说明或额外复制按钮。
   - 发布图标使用App Store原版九点布局：中心位于画布25%/50%/75%，半径为画布宽度1/12，整体宽度2/3；保留本项目配色，以SVG母版原生导出各尺寸。关于页使用同一图标、本地作者头像、作者主页和项目仓库入口，不增加常驻说明段落。

## Do's and Don'ts
- **Do**:
  - 全程使用海沫绿（Seafoam Green `#0D9488` / `#14B8A6`）作为主视觉灵魂；
  - 遵循原版 Tailscale iOS App 的极简大按键交互；
  - 突出 TrollStore 独家免 VPN 原生 utun 特性；
  - 严格遵守字符串字数≤13字；
  - 严格保持卡片单层，无任何嵌套；
  - 说明性内容统一置于信息弹窗/提示。
- **Don't**:
  - 严禁任何 emoji 图标；
  - 严禁卡片嵌套；
  - 严禁中英文之间插入空格；
  - 严禁深蓝旧配色。

