//
//  SettingsView.swift
//  TSNativeTailscale UI
//
//  设置页 (1:1 严格对齐原版 Settings 页面，纯净无生硬黑客用语)
//

import SwiftUI

public struct SettingsView: View {
    @ObservedObject var viewModel: TSViewModel
    @Environment(\.presentationMode) var presentationMode
    @State private var confirmingStop = false

    public init(viewModel: TSViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationView {
            List {
                // Section 1: 用户卡片 (已登录显示账号，未登录显示 Log In...)
                Section {
                    NavigationLink(destination: AccountsView(viewModel: viewModel)) {
                        HStack(spacing: 14) {
                            Image(systemName: "person.crop.circle.fill")
                                .resizable()
                                .frame(width: 44, height: 44)
                                .foregroundColor(viewModel.isLoggedIn ? TSTheme.primaryLight : TSTheme.textSecondary)

                            VStack(alignment: .leading, spacing: 3) {
                                TSScrollText(text: viewModel.isLoggedIn ? viewModel.accountTitle : TSLocalization.tr("Log In..."), font: TSTheme.menuFont)
                                    .foregroundColor(TSTheme.textPrimary)
                                if viewModel.isLoggedIn {
                                    TSScrollText(text: viewModel.deviceIp != "--" ? viewModel.deviceIp : (viewModel.activeAccount?.tailnet ?? ""), font: TSTheme.detailFont)
                                        .foregroundColor(TSTheme.textSecondary)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    if viewModel.isLoggedIn {
                        Button(action: {
                            viewModel.openAdminConsole()
                        }) {
                            Label("管理控制台", systemImage: "arrow.up.right.square")
                                .font(TSTheme.menuFont)
                                .foregroundColor(TSTheme.primaryLight)
                        }
                    }
                }

                // Section 2: 原版网络设置
                Section {
                    NavigationLink(destination: DnsSettingsView(viewModel: viewModel)) {
                        Label(TSLocalization.tr("DNS Settings"), systemImage: "network")
                                .font(TSTheme.menuFont)
                                .foregroundColor(TSTheme.textPrimary)
                    }
                    NavigationLink(destination: FilesView(viewModel: viewModel)) {
                        Label("文件传输", systemImage: "arrow.up.arrow.down")
                            .font(TSTheme.menuFont).foregroundColor(TSTheme.textPrimary)
                    }
                    NavigationLink(destination: AboutView()) {
                        Label(TSLocalization.tr("About Tailscale"), systemImage: "info.circle")
                                .font(TSTheme.menuFont)
                                .foregroundColor(TSTheme.textPrimary)
                    }
                }

                // Section 4: 诊断与降温重置
                Section {
                    Button(action: {
                        confirmingStop = true
                    }) {
                        Label("停止后台服务", systemImage: "stop.circle")
                            .font(TSTheme.menuFont).foregroundColor(TSTheme.danger)
                    }
                    .disabled(viewModel.isAuthenticating || viewModel.isAddingAccount)
                }
            }
            .tsList()
            .labelStyle(TSRowLabelStyle())
            .navigationTitle(TSLocalization.tr("Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        presentationMode.wrappedValue.dismiss()
                    } label: {
                        Label(TSLocalization.tr("Done"), systemImage: "xmark").tsIcon()
                    }
                    .foregroundColor(TSTheme.primaryLight)
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle()) // 适配 iPad 平板
        .preferredColorScheme(.dark)
        .confirmationDialog("停止后台服务？", isPresented: $confirmingStop, titleVisibility: .visible) {
            Button("停止服务", role: .destructive) { viewModel.killAllDaemons() }
            Button("取消", role: .cancel) {}
        } message: { Text("连接和正在进行的传输将中断。") }
        // 设置页承接当前层级的错误，避免主页提示被模态页遮挡
        .alert(isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Alert(title: Text(TSLocalization.tr("Operation Failed")), message: Text(viewModel.errorMessage ?? ""), dismissButton: .default(Text("OK")))
        }
    }
}
