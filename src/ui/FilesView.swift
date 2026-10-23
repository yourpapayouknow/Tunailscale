// Taildrop 原生文件选择、预览与导出入口
import SwiftUI
import UniformTypeIdentifiers
import QuickLook

struct FilesView: View {
    @ObservedObject var viewModel: TSViewModel
    var sourceURL: URL? = nil
    @StateObject private var transfer = TSFileTransfer()
    @State private var target: TSTailscalePeer?
    @State private var importing = false
    @State private var preview: URL?
    @State private var sharing: URL?
    @State private var deleting: URL?
    @State private var visible = false

    // 无沙盒 iOS 使用本机 Downloads，不读取 Safari/iCloud 的私有设置
    private var downloads: URL { URL(fileURLWithPath: "/var/mobile/Downloads", isDirectory: true) }

    var body: some View {
        List {
            Section {
                Label { TSScrollText(text: viewModel.activeAccount?.name ?? "请先登录") } icon: { Image(systemName: "person.crop.circle") }
            }
            Section(header: Text("发送到")) {
                if let sourceURL = sourceURL { Text(sourceURL.lastPathComponent).foregroundColor(TSTheme.textSecondary) }
                ForEach(viewModel.peers.filter { $0.taildropAvailable }, id: \.ip) { peer in
                    Button {
                        if let sourceURL = sourceURL { transfer.send(sourceURL, to: peer) }
                        else { target = peer; importing = true }
                    } label: {
                        HStack {
                            Label { TSScrollText(text: peer.displayName, font: TSTheme.menuFont) } icon: { Image(systemName: peer.deviceSymbol) }
                                .font(TSTheme.menuFont).accessibilityLabel(peer.name)
                            Spacer()
                            Text(peer.online ? "在线" : "离线").font(TSTheme.detailFont).foregroundColor(TSTheme.textSecondary).fixedSize()
                        }
                    }
                    .disabled(transfer.busy || viewModel.isAuthenticating || !viewModel.isConnected)
                }
                if !viewModel.peers.contains(where: { $0.taildropAvailable }) { Text("暂无可发送设备").foregroundColor(TSTheme.textSecondary) }
            }
            Section(header: Text("已接收")) {
                Button { refresh() } label: {
                    Label("接收文件", systemImage: "arrow.down.to.line").font(TSTheme.menuFont)
                }.disabled(transfer.busy || viewModel.isAuthenticating || !viewModel.isConnected)
                ForEach(transfer.files, id: \.self) { url in
                    Button { preview = url } label: {
                        Label { TSScrollText(text: url.lastPathComponent) } icon: { Image(systemName: "doc") }
                            .foregroundColor(TSTheme.textPrimary)
                    }
                    .disabled(transfer.busy)
                    .swipeActions {
                        Button(role: .destructive) { deleting = url } label: { Label("删除", systemImage: "trash") }
                        Button { sharing = url } label: { Label("导出", systemImage: "square.and.arrow.up") }.tint(TSTheme.primary)
                    }
                }
                if transfer.files.isEmpty { Text("暂无文件").foregroundColor(TSTheme.textSecondary) }
            }
            if !transfer.incomplete.isEmpty {
                Section(header: Text("未完成"), footer: Text("文件不完整，请勿直接使用。")) {
                    ForEach(transfer.incomplete, id: \.self) { url in
                        TSScrollText(text: url.lastPathComponent, font: TSTheme.detailFont).accessibilityLabel(url.path)
                    }
                }
            }
            if transfer.busy || viewModel.isAuthenticating {
                Section {
                    ProgressView(transfer.busy ? "正在传输" : "正在准备文件服务")
                    if transfer.busy { Button("取消传输", role: .destructive) { transfer.cancel() } }
                }
            }
        }
        .tsList()
        .navigationTitle("文件传输")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { visible = true; refresh(reason: "appearance") }
        .onDisappear { visible = false; transfer.cancel() }
        .onChange(of: viewModel.activeAccount?.id) { _ in refresh(reason: "account-change") }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            do { if let peer = target { transfer.send(try result.get(), to: peer) } }
            catch { transfer.message = error.localizedDescription }
        }
        .sheet(isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } })) {
            if let url = preview { FilePreview(url: url) }
        }
        .sheet(isPresented: Binding(get: { sharing != nil }, set: { if !$0 { sharing = nil } })) {
            if let url = sharing { FileShare(url: url) }
        }
        .confirmationDialog("删除后无法恢复", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            if let url = deleting { Button("删除文件", role: .destructive) { transfer.delete(url); deleting = nil } }
            Button("取消", role: .cancel) { deleting = nil }
        }
        .alert("文件传输", isPresented: Binding(get: { transfer.message != nil }, set: { if !$0 { transfer.message = nil } })) {
            Button("确定", role: .cancel) { transfer.message = nil }
        } message: { Text(transfer.message ?? "") }
    }

    // 固定账户和 socket 后领取后台收件箱中的文件
    private func refresh(reason: String = "manual") {
        guard !transfer.busy else { return }
        let account = viewModel.activeAccount
        transfer.configure(account: account, socketPath: TSLocalAPI.activeSocketPath(), downloads: downloads)
        if viewModel.isConnected {
            viewModel.prepareFileTransfer { error in
                guard visible, viewModel.activeAccount?.id == account?.id else { return }
                if let error = error { transfer.message = error.localizedDescription; return }
                transfer.configure(account: account, socketPath: TSLocalAPI.activeSocketPath(), downloads: downloads)
                transfer.receive(reason: reason)
            }
        }
    }
}

// 系统预览不加载整个文件到 SwiftUI 状态
private struct FilePreview: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(_ url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}

// 通过系统分享面板导出文件
struct FileShare: UIViewControllerRepresentable {
    let url: URL
    var completion: (() -> Void)? = nil
    // 原生面板完成或取消时交回展示状态
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in completion?() }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
