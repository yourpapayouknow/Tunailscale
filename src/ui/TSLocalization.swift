//
//  TSLocalization.swift
//  TSNativeTailscale UI
//
//  系统语言跟随国际化工具 (纯Swift实现)
//  严格遵守字数≤13字与中英文无空格规范
//

import Foundation

public enum TSLocalization {
    public static var isChinese: Bool {
        if let lang = Locale.preferredLanguages.first {
            return lang.hasPrefix("zh")
        }
        return false
    }

    private static let dictionary: [String: String] = [
        /* 状态与导航标题 */
        "Not Connected": "未连接",
        "Connected": "已连接",
        "Connecting...": "正在连接",
        "Checking...": "正在读取状态",
        "Status Unavailable": "暂时无法读取状态",
        "Needs Login": "等待认证",
        "Starting": "正在启动",
        "Settings": "设置",
        "Accounts": "账户",
        
        /* 按钮与动作 */
        "Connect": "连接",
        "Disconnect": "断开连接",
        "Done": "完成",
        "Cancel": "取消",
        "Save": "保存",
        "Confirm": "确定",
        "Reauthenticate": "重新认证",
        "Log Out": "退出登录",
        "Add Account...": "添加账户",
        "Cancel Adding Account": "取消添加账户",
        "Adding account timed out": "添加账户超时，已取消",
        "Account already added": "该账户已添加",
        "Operation Failed": "操作失败",
        "Copy IP": "复制IP",
        "Online": "在线",
        "Offline": "离线",
        
        /* 原版高级菜单与独家设置 */
        "Advanced Login Options": "高级登录选项",
        "Use an auth key": "使用AuthKey入网",
        "Use a custom coordination server": "自定义协调服务器",
        "Native utun Status": "原生utun状态",
        "DNS Settings": "DNS设置",
        "Bug Report": "问题反馈",
        "About Tailscale": "关于Tailscale",
        "Kernel Channel": "内核通道",
        
        /* 说明文案 */
        "Log In...": "登录",
        "Log in to connect to your devices and Tailscale network.": "登录以连接您的设备与网络。",
        "Connect again to talk to other devices in tailnet.": "连接后即可访问Tailnet局域网中的设备。",
        "Manage your account from admin console.": "在控制台管理您的网络与设备。"
    ]

    public static func tr(_ key: String) -> String {
        if isChinese, let localized = dictionary[key] {
            return localized
        }
        return key.hasSuffix("...") ? String(key.dropLast(3)) : key
    }
}
