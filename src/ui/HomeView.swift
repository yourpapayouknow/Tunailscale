//
//  HomeView.swift
//  TSNativeTailscale UI
//
//  主界面 (1:1 严格对齐原版主页 UI 布局)
//  支持 iPad 平板自适应布局、字重加粗、真实未登录/已登录状态联动
//

import SwiftUI

public struct HomeView: View {
    @StateObject private var viewModel = TSViewModel()
    @State private var showingSettings = false
    @State private var incomingFile: URL?
    @State private var showingFile = false
    @ScaledMetric(relativeTo: .title2) private var statusSize = 26

    public init() {}

    // 视觉回归使用隔离状态，不读取或修改真实连接
    init(viewModel: TSViewModel) { _viewModel = StateObject(wrappedValue: viewModel) }

    public var body: some View {
        ZStack {
            // 背景底色 (原版深黑)
            TSTheme.background
                .ignoresSafeArea()

            GeometryReader { geometry in
            ScrollView(.vertical) {
            VStack(spacing: 0) {
                // 1. 顶部 Header 栏 (1:1 原版：未登录时仅单行 Not Connected，已登录时两行账号+状态)
                HStack(spacing: 14) {
                    Toggle(TSLocalization.tr("Connect"), isOn: Binding(
                        get: { viewModel.isConnected },
                        set: { _ in viewModel.toggleConnection() }
                    ))
                    .labelsHidden()
                    .toggleStyle(SwitchToggleStyle(tint: TSTheme.primaryLight))
                    .disabled(viewModel.isAuthenticating || viewModel.backendState == "Checking")

                    VStack(alignment: .leading, spacing: 2) {
                        if viewModel.isLoggedIn {
                            TSScrollText(text: viewModel.accountTitle, font: TSTheme.menuFont)
                                .foregroundColor(TSTheme.textPrimary)

                            if let tailnet = viewModel.activeAccount?.tailnet, !tailnet.isEmpty, tailnet != viewModel.accountTitle {
                                TSScrollText(text: tailnet, font: TSTheme.detailFont)
                                    .foregroundColor(TSTheme.textSecondary)
                            }
                        } else {
                            Text("Tunailscale")
                                .font(TSTheme.menuFont)
                                .foregroundColor(TSTheme.textPrimary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    Button(action: { showingSettings = true }) {
                        Image(systemName: "person.crop.circle.fill")
                            .resizable()
                            .frame(width: 36, height: 36)
                            .foregroundColor(TSTheme.textSecondary)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel(TSLocalization.tr("Settings"))
                }
                .padding(.horizontal, TSTheme.margin)
                .padding(.top, 12)
                .padding(.bottom, 20)
                .frame(maxWidth: 600) // iPad 居中适配

                Spacer()

                // 2. 屏幕中央核心区 (1:1 原版居中大电源 + 状态大字 + 说明 + 宽大按钮，iPad 优雅居中)
                VStack(spacing: 20) {
                    // 大电源图标 (原版尺寸，加粗字重与海沫绿光泽)
                    Image(systemName: "power")
                        .font(.system(size: 68, weight: .bold))
                        .foregroundColor(viewModel.isConnected ? TSTheme.primaryLight : TSTheme.textSecondary.opacity(0.5))
                        .frame(width: 104, height: 104)
                        .background(
                            Circle()
                                .fill(viewModel.isConnected ? TSTheme.primaryLight.opacity(0.12) : Color.clear)
                        )

                    // 状态标题随系统文字大小缩放
                    Text(viewModel.connectionTitle)
                        .font(.system(size: statusSize, weight: .bold))
                        .foregroundColor(TSTheme.textPrimary)

                    // 已连接时只显示本机地址
                    if viewModel.isConnected && viewModel.deviceIp != "--" {
                        TSIPText(address: viewModel.deviceIp)
                    }

                    // 宽幅大药丸按钮 (字重加粗至 Bold，iPad 限制最大宽度保持黄金比例)
                    Button(action: {
                        viewModel.toggleConnection()
                    }) {
                        Group {
                            if viewModel.isAuthenticating || viewModel.backendState == "Checking" {
                                ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .accessibilityLabel("正在处理")
                            } else {
                            Text(viewModel.isConnected ?
                                 TSLocalization.tr("Disconnect") :
                                 (viewModel.isLoggedIn ? TSLocalization.tr("Connect") : TSLocalization.tr("Log In...")))
                            }
                        }
                        .font(TSTheme.menuFont)
                        .foregroundColor(viewModel.isConnected ? TSTheme.textPrimary : Color.white)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(viewModel.isConnected ? TSTheme.surfaceLight : TSTheme.primaryFill)
                        .cornerRadius(TSTheme.radius)
                    }
                    .disabled(viewModel.isAuthenticating || viewModel.backendState == "Checking")
                    .padding(.horizontal, TSTheme.margin)
                    .padding(.top, 14)
                }
                .frame(maxWidth: 480) // 平板 iPad 适配，保持舒适居中布局
                .animation(.easeInOut(duration: 0.25), value: viewModel.isConnected)

                Spacer()

                // 全部设备随页面滚动，在线优先，角标区分在线与离线
                if viewModel.isConnected && !viewModel.peers.isEmpty {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(viewModel.orderedPeers, id: \.ip) { peer in
                            HStack(alignment: .center, spacing: 12) {
                                Image(systemName: peer.deviceSymbol)
                                    .font(TSTheme.bodyFont)
                                    .frame(width: 28, height: 28)
                                    .foregroundColor(TSTheme.textSecondary)
                                    .overlay(alignment: .bottomTrailing) {
                                        Circle().fill(peer.online ? TSTheme.primaryLight : TSTheme.danger)
                                            .frame(width: 8, height: 8)
                                            .overlay(Circle().stroke(TSTheme.background, lineWidth: 1))
                                    }
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 4) {
                                    TSScrollText(text: peer.displayName)
                                        .foregroundColor(peer.online ? TSTheme.textPrimary : TSTheme.textSecondary)
                                    TSIPText(address: peer.ip, color: peer.online ? TSTheme.accent : TSTheme.textSecondary)
                                }
                            }
                            .frame(minHeight: 48)
                            .accessibilityElement(children: .combine)
                            .accessibilityValue(TSLocalization.tr(peer.online ? "Online" : "Offline"))
                            .padding(.horizontal, TSTheme.margin)
                            .padding(.vertical, 4)
                        }
                    }
                    .frame(maxWidth: 480)
                    .padding(.bottom, 20)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: geometry.size.height)
            }
            }
        }
        .sheet(isPresented: $showingSettings, onDismiss: { if incomingFile != nil { showingFile = true } }) {
            SettingsView(viewModel: viewModel)
        }
        .sheet(isPresented: $showingFile, onDismiss: { incomingFile = nil }) {
            NavigationView {
                FilesView(viewModel: viewModel, sourceURL: incomingFile)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button { showingFile = false } label: { Label("完成", systemImage: "xmark").tsIcon() }
                        }
                    }
            }.navigationViewStyle(StackNavigationViewStyle())
        }
        // 文件打开事件只进入设备选择页，不自动发送或切换账户
        .onOpenURL { url in
            guard url.isFileURL else { return }
            incomingFile = url
            if showingSettings { showingSettings = false }
            else { showingFile = true }
        }
        .alert(isPresented: Binding(
            get: { !showingSettings && viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Alert(
                title: Text(TSLocalization.tr("Operation Failed")),
                message: Text(viewModel.errorMessage ?? ""),
                dismissButton: .default(Text("OK"))
            )
        }
        .preferredColorScheme(.dark)
    }
}
