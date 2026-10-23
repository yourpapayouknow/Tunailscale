// 在隔离模拟器渲染真实视图，全部账户和设备均为合成测试数据
import UIKit
import SwiftUI
import ObjectiveC

@main
final class UIAudit: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var screens: [(String, AnyView, TimeInterval)] = []
    private var index = 0

    // 构造不连接后台的视觉测试状态
    private func model(connected: Bool) -> TSViewModel {
        let value = TSViewModel()
        value.stopPolling()
        value.isConnected = connected
        value.isLoggedIn = true
        value.backendState = connected ? "Running" : "Stopped"
        value.accountTitle = "preview-account@example.com"
        value.deviceIp = connected ? "100.64.0.10" : "--"
        value.accounts = [TSAccountItem(name: value.accountTitle, tailnet: "preview.tailnet.ts.net", serverUrl: "https://controlplane.tailscale.com", isActive: true, profileId: "preview")]
        value.peers = ["桌面电脑", "很长的设备名称用于检查小屏显示", "MacBook"].enumerated().map { offset, name in
            let peer = TSTailscalePeer()
            peer.name = name + ".preview.ts.net."
            peer.ip = "100.64.0.\(offset + 11)"
            peer.os = offset == 0 ? "windows" : offset == 1 ? "iOS" : "macOS"
            peer.online = offset < 2
            peer.taildropAvailable = true
            return peer
        }
        return value
    }

    // 所有页面使用同一台小屏设备与两档系统字号
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // 同时验证原生解码和具名资源加载，避免空白图像被快照数量掩盖。
        for name in ["AppIcon512", "CreatorAvatar"] {
            let path = Bundle.main.path(forResource: name, ofType: "png")!
            precondition(UIImage(contentsOfFile: path) != nil, "Invalid bundled image: \(name)")
            precondition(UIImage(named: name) != nil, "Missing named image: \(name)")
        }
        // 仅测试进程替换默认 socket，禁止访问宿主或手机的真实后台
        let socket = class_getClassMethod(TSLocalAPI.self, #selector(TSLocalAPI.defaultSocketPath))!
        method_setImplementation(socket, imp_implementationWithBlock({ () -> NSString in "/tmp/ui-audit-disconnected.sock" } as @convention(block) () -> NSString))
        let connected = model(connected: true), stopped = model(connected: false)
        // 只在隔离模拟器核验真实系统剪贴板，完成后还原全部内容
        let previousClipboard = UIPasteboard.general.items
        for address in ["100.64.0.10", "fd7a:115c:a1e0::1234"] {
            TSIPText.copy(address)
            precondition(UIPasteboard.general.string == address, "IP copy changed address")
        }
        UIPasteboard.general.items = previousClipboard
        let many = model(connected: true)
        many.peers = (0..<30).reversed().map { index in
            let peer = TSTailscalePeer()
            peer.name = String(format: "设备%02d", index + 1) + ".preview.ts.net."
            peer.ip = "100.64.1.\(index + 1)"
            peer.os = "windows"
            peer.online = index % 2 == 0
            return peer
        }
        let loggedOut = model(connected: false)
        loggedOut.accounts = []; loggedOut.isLoggedIn = false
        let share = SharePanelState()
        share.account = connected.activeAccount; share.peers = connected.peers
        share.file = URL(fileURLWithPath: "/tmp/中文文件名称与长名称排版检查.txt")
        let transfer = TSFileTransfer()
        let views: [(String, AnyView)] = [
            ("home", AnyView(HomeView(viewModel: connected))),
            ("home-many-top", AnyView(HomeView(viewModel: many))),
            ("home-many-bottom", AnyView(HomeView(viewModel: many))),
            ("home-off", AnyView(HomeView(viewModel: stopped))),
            ("settings", AnyView(SettingsView(viewModel: connected))),
            ("accounts", AnyView(NavigationView { AccountsView(viewModel: connected) })),
            ("login", AnyView(NavigationView { AccountsView(viewModel: loggedOut) })),
            ("files", AnyView(NavigationView { FilesView(viewModel: stopped) })),
            ("dns", AnyView(NavigationView { DnsSettingsView(viewModel: connected) })),
            ("about", AnyView(NavigationView { AboutView() })),
            ("share", AnyView(SharePanel(state: share, transfer: transfer, close: {})))
        ]
        for (size, tag) in [(DynamicTypeSize.large, "normal"), (.accessibility1, "large")] {
            for (name, view) in views {
                screens.append(("\(name)-\(tag)", AnyView(view.dynamicTypeSize(size).environment(\.scenePhase, .active).navigationViewStyle(.stack).preferredColorScheme(.dark).tint(TSTheme.primaryLight)), 0.8))
            }
        }
        // 同内容两帧对照证明动画启动及暂停，不依赖肉眼猜测
        for (name, text, phase) in [("active", String(repeating: "完整滚动校验", count: 6), ScenePhase.active), ("fit", "短名称", .active), ("inactive", String(repeating: "完整滚动校验", count: 6), .background)] {
            for (frame, delay) in [("start", 0.8), ("later", 3.5)] {
                let content = TSScrollText(text: text).frame(width: 140).frame(maxWidth: .infinity, maxHeight: .infinity).background(TSTheme.background)
                    .environment(\.scenePhase, phase).preferredColorScheme(.dark)
                screens.append(("scroll-\(name)-\(frame)", AnyView(content), delay))
            }
        }
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.makeKeyAndVisible()
        render()
        return true
    }

    // 查找当前视觉测试页面的系统滚动视图
    private func scroll(in view: UIView) -> UIScrollView? {
        if let value = view as? UIScrollView { return value }
        return view.subviews.lazy.compactMap { self.scroll(in: $0) }.first
    }

    // 系统窗口完成布局后输出PNG，长设备列表实际滚动到底部
    private func render() {
        guard index < screens.count else { NSLog("UIAudit complete: %d screenshots", screens.count); exit(0) }
        let (name, view, delay) = screens[index]
        let controller = UIHostingController(rootView: view)
        window?.rootViewController = controller
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let window = self.window else { exit(1) }
            window.layoutIfNeeded()
            if name.hasPrefix("home-many-bottom") {
                guard let scroll = self.scroll(in: window) else { preconditionFailure("Missing peer scroll view") }
                precondition(scroll.contentSize.height > scroll.bounds.height, "Peer list did not overflow")
                scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom), animated: false)
                scroll.layoutIfNeeded()
            }
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name + ".png")
            do { try image.pngData()!.write(to: output) } catch { NSLog("UIAudit failed: %@", error.localizedDescription); exit(1) }
            self.index += 1
            self.render()
        }
    }
}
