<div align="center">

<img src="assets/readme-badge.png" alt="Tunailscale项目横幅" />

# Tunailscale

*为TrollStore用户提供独立于系统VPN的设备互联与文件传输。*

<img src="https://img.shields.io/badge/平台-iOS%2015.0%2B%20%7C%20iPadOS%2015.0%2B-blue.svg?style=flat-square" alt="平台：iOS及iPadOS15.0以上" />
<img src="https://img.shields.io/badge/语言-Swift-orange.svg?style=flat-square" alt="语言：Swift" />
<img src="https://img.shields.io/badge/界面-SwiftUI-green.svg?style=flat-square" alt="界面：SwiftUI" />

</div>

---

Tunailscale面向已安装TrollStore的iPhone与iPad用户，通过原生utun接入Tailscale网络，不占用系统VPN配置。登录后即可查看设备、管理账户，并通过应用内文件传输或系统分享向自己的设备发送文件。

## 快速开始

将以下指令发给具备终端执行能力的编程助手：

```text
帮我安装这个仓库：https://github.com/yourpapayouknow/Tunailscale。检查设备是否支持TrollStore，通过TrollStore安装正式包；无安装包时在Mac构建。必要授权由我本人确认。
```

---

## 传统开始

应用最低部署目标为iOS/iPadOS15.0，设备必须处于TrollStore支持的系统版本且已安装TrollStore；不能通过普通侧载工具替代其特权安装。

源码构建使用macOS、Xcode16.3及其iOS SDK、Homebrew、Git和Go。脚本为本项目固定Go1.27.3及Tailscale源码提交，不修改其他检出或全局Go配置。首次构建需要联网获取工具链及依赖，并须先打开Xcode完成许可确认。

```zsh
brew install go ldid
git clone https://github.com/yourpapayouknow/Tunailscale.git
cd Tunailscale
/bin/zsh build.sh
```

将生成的`dist/Tunailscale.tipa`传到设备，通过TrollStore打开并安装，再启动Tunailscale登录账户。

---

## 功能

| 功能 | 用途 |
|---|---|
| 原生网络连接 | 通过utun连接Tailnet，不占用系统VPN配置 |
| 多账户管理 | 添加、切换和重新认证账户，取消新增不影响现有连接 |
| 设备列表 | 在线优先展示全部设备，长按复制完整IP |
| 文件传输 | 向设备发送文件，接收文件保存到Downloads |
| 系统分享 | 从其他应用选择文件并指定接收设备 |
| DNS设置 | 管理当前账户的MagicDNS开关 |
| 日志导出 | 在关于页查看及导出完整诊断日志 |

---

## 使用

1. 首次打开后，在账户页选择浏览器登录或输入AuthKey，完成授权后连接。
2. 首页查看连接状态和设备列表；绿点表示在线，红点表示离线，长按IP可复制。
3. 在设置中进入文件传输，选择文件和目标设备；接收文件保存在系统Downloads下的Taildrop账户目录。
4. 从其他应用的系统分享页选择“Tailscale文件传输”，再选择设备发送；此时当前账户须已连接且后台服务仍在运行。
5. 更新或卸载前在设置中选择“停止后台服务”；更新后重新连接以载入新核心，卸载则通过TrollStore完成。
