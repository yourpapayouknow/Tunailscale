// 系统分享扩展直接选设备传输，不使用非官方方式跳转包含 App
import UIKit
import SwiftUI
import UniformTypeIdentifiers
import Combine

@objc(ShareController)
final class ShareController: UIViewController {
    private let state = SharePanelState()
    private let staging = FileManager.default.temporaryDirectory.appendingPathComponent("ts-share-\(UUID().uuidString)")
    private var closed = false
    private lazy var transfer = TSFileTransfer(executable: Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("tailscale").path)

    // 加载系统提供的单文件，注册规则不接受批量或文本链接
    override func viewDidLoad() {
        super.viewDidLoad()
        let panel = UIHostingController(rootView: SharePanel(state: state, transfer: transfer) { [weak self] in self?.close() })
        addChild(panel)
        panel.view.frame = view.bounds
        panel.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(panel.view)
        panel.didMove(toParent: self)
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        guard providers.count == 1, let provider = providers.first else { state.error = "请一次分享一个文件"; return }
        let staging = self.staging
        let delivered: (URL?, Error?) -> Void = { [weak self] url, error in
            do {
                if let error = error { throw error }
                guard let url = url else { throw TSShareState.failure("无法读取分享文件") }
                let file = try TSFileTransfer.stage(url, in: staging)
                Task { @MainActor [weak self] in
                    guard let self = self, !self.closed else { try? FileManager.default.removeItem(at: staging); return }
                    self.state.file = file
                    self.loadAccount()
                }
            } catch {
                Task { @MainActor [weak self] in self?.state.error = error.localizedDescription }
            }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, error in delivered(value as? URL, error) }
        } else if let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .data) == true }) {
            provider.loadFileRepresentation(forTypeIdentifier: type, completionHandler: delivered)
        } else { state.error = "该分享内容不是可发送的文件" }
    }

    // 实时确认连接、有效期和 Profile，不能仅信任共享文件中的旧元数据
    private func loadAccount() {
        do {
            let snapshot = try TSShareState.load()
            TSLogs.trace("share snapshot build=\(TSLogs.build) socket=\(snapshot.socket)", in: nil)
            TSLocalAPI.fetchStatus(socketPath: snapshot.socket) { [weak self] status, error in
                Task { @MainActor [weak self] in
                    guard let self = self, !self.closed else { return }
                    // 记录真实校验分支，不把接口失败误当作账户掉线
                    TSLogs.trace("share status state=\(status?.backendState ?? "<none>") expired=\(status?.keyExpired.description ?? "<none>") expiry=\(status?.keyExpiry?.description ?? "<none>") error=\(error?.localizedDescription ?? "<none>")", in: nil)
                    if let error = error { self.state.error = "无法访问后台：\(error.localizedDescription)"; return }
                    guard let status = status, status.backendState == "Running", !status.keyExpired,
                          status.keyExpiry.map({ $0 > Date() }) ?? true else {
                        self.state.error = "请先打开App连接或重新认证当前账户"
                        return
                    }
                    self.state.account = snapshot.account
                    self.state.peers = status.peers.filter { $0.taildropAvailable }
                    self.transfer.configure(account: snapshot.account, socketPath: snapshot.socket)
                }
            }
        } catch {
            TSLogs.trace("share snapshot error=\(error.localizedDescription)", in: nil)
            state.error = "请先打开App完成连接：\(error.localizedDescription)"
        }
    }

    // 取消扩展只清理本次传输副本，不停止主 App 后台服务
    private func close() {
        transfer.cancel()
        guard !transfer.busy else { return }
        closed = true
        do { if FileManager.default.fileExists(atPath: staging.path) { try FileManager.default.removeItem(at: staging) } }
        catch { state.error = error.localizedDescription; return }
        extensionContext?.completeRequest(returningItems: nil)
    }
}

// 分享面板仅保存本次文件和可选设备
final class SharePanelState: ObservableObject {
    @Published var file: URL?
    @Published var account: TSAccountItem?
    @Published var peers: [TSTailscalePeer] = []
    @Published var error: String?
}

struct SharePanel: View {
    @ObservedObject var state: SharePanelState
    @ObservedObject var transfer: TSFileTransfer
    let close: () -> Void

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("发送文件")) {
                    Label { TSScrollText(text: state.file?.lastPathComponent ?? "正在读取文件") } icon: { Image(systemName: "doc") }
                    if let account = state.account {
                        Label { TSScrollText(text: account.name, font: TSTheme.detailFont) } icon: { Image(systemName: "person.crop.circle") }
                            .foregroundColor(TSTheme.textSecondary)
                    }
                }
                Section(header: Text("选择设备")) {
                    ForEach(state.peers, id: \.ip) { peer in
                        Button { if let file = state.file { transfer.send(file, to: peer) } } label: {
                            Label { TSScrollText(text: peer.displayName, font: TSTheme.menuFont) } icon: { Image(systemName: peer.deviceSymbol) }
                                .font(TSTheme.menuFont)
                        }
                            .accessibilityLabel(peer.name)
                            .disabled(transfer.busy || state.file == nil)
                    }
                    if state.peers.isEmpty { Text("暂无可发送设备").foregroundColor(TSTheme.textSecondary) }
                }
                if transfer.busy { ProgressView("正在发送") }
                if let error = state.error { Label(error, systemImage: "exclamationmark.circle").font(TSTheme.detailFont).foregroundColor(TSTheme.warning) }
                if let message = transfer.message { Text(message).font(TSTheme.detailFont).foregroundColor(TSTheme.textSecondary) }
            }
            .tsList()
            .navigationTitle("文件传输")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: close) {
                        Label(transfer.busy ? "取消传输" : "完成", systemImage: transfer.busy ? "xmark.circle" : "xmark").tsIcon()
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .preferredColorScheme(.dark)
        .tint(TSTheme.primaryLight)
    }
}
