//
//  AccountsView.swift
//  TSNativeTailscale UI
//
//  账户页 (支持未登录引导、真实 AuthKey 输入、自定义服务器输入、多账户切换与登出)
//

import SwiftUI

public struct AccountsView: View {
    @ObservedObject var viewModel: TSViewModel
    @Environment(\.presentationMode) var presentationMode

    @State private var showingAuthKeySheet = false
    @State private var authKeyInput = ""

    @State private var showingServerSheet = false
    @State private var serverInput = ""

    @State private var showingLogoutConfirm = false

    public init(viewModel: TSViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        List {
            if viewModel.accounts.isEmpty {
                // 未登录状态卡片组 (原版未登录引导)
                Section(header: Text("登录Tailscale")) {
                    Button(action: {
                        viewModel.launchBrowserAuth()
                    }) {
                        Label("浏览器登录", systemImage: "safari")
                            .font(TSTheme.menuFont).foregroundColor(TSTheme.primaryLight)
                    }

                    Button(action: {
                        authKeyInput = ""
                        showingAuthKeySheet = true
                    }) {
                        Label(TSLocalization.tr("Use an auth key"), systemImage: "key")
                            .font(TSTheme.menuFont).foregroundColor(TSTheme.textPrimary)
                    }

                    Button(action: {
                        serverInput = viewModel.customCoordinationServer
                        showingServerSheet = true
                    }) {
                        Label(TSLocalization.tr("Use a custom coordination server"), systemImage: "server.rack")
                            .font(TSTheme.menuFont).foregroundColor(TSTheme.textPrimary)
                    }
                }
                .disabled(viewModel.isAuthenticating)
            } else {
                // 已有账户列表 (支持点击切换当前活跃账号，支持右滑删除)
                Section(header: Text("已登录账户")) {
                    ForEach(viewModel.accounts) { account in
                        Button(action: {
                            viewModel.selectAccount(id: account.id)
                        }) {
                            HStack(spacing: 14) {
                                Image(systemName: "person.crop.circle.fill")
                                    .resizable()
                                    .frame(width: 44, height: 44)
                                    .foregroundColor(account.isActive ? TSTheme.primaryLight : TSTheme.textSecondary)

                                VStack(alignment: .leading, spacing: 4) {
                                    TSScrollText(text: account.name, font: TSTheme.menuFont)
                                        .foregroundColor(TSTheme.textPrimary)
                                    if account.tailnet != account.name { TSScrollText(text: account.tailnet, font: TSTheme.detailFont)
                                        .foregroundColor(TSTheme.textSecondary)
                                    }
                                    // 显示节点密钥状态，不把未知有效期当作永不过期
                                    Text(account.isExpired ? "节点密钥已过期" : account.keyExpiry.map { "到期 " + $0.formatted(date: .numeric, time: .omitted) } ?? "有效期未知")
                                        .font(TSTheme.detailFont)
                                        .foregroundColor(account.isExpired ? TSTheme.warning : TSTheme.textSecondary)
                                }

                                Spacer()

                                if account.isActive {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(TSTheme.menuFont)
                                        .foregroundColor(TSTheme.primaryLight)
                                }
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(account.isActive ? .isSelected : [])
                            .padding(.vertical, 4)
                        }
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            let target = viewModel.accounts[index]
                            viewModel.removeAccount(id: target.id)
                        }
                    }
                    .disabled(viewModel.isAddingAccount || viewModel.isAuthenticating)

                    Button(action: {
                        if viewModel.isAddingAccount { viewModel.cancelAddAccount() }
                        else { viewModel.startAddAccount() }
                    }) {
                        HStack {
                            Label(TSLocalization.tr(viewModel.isAddingAccount ? "Cancel Adding Account" : "Add Account..."), systemImage: viewModel.isAddingAccount ? "xmark.circle" : "person.badge.plus")
                            if viewModel.isAddingAccount { ProgressView().tint(TSTheme.primaryLight) }
                        }
                        .font(TSTheme.menuFont)
                        .foregroundColor(TSTheme.primaryLight)
                    }
                    .disabled(viewModel.isAuthenticating)
                }

                // Section 2: 认证与退出
                Section {
                    Button(action: {
                        viewModel.launchBrowserAuth()
                    }) {
                        Label(TSLocalization.tr("Reauthenticate"), systemImage: "arrow.clockwise.circle")
                            .font(TSTheme.menuFont)
                            .foregroundColor(TSTheme.primaryLight)
                    }

                    Button(action: {
                        showingLogoutConfirm = true
                    }) {
                        Label(TSLocalization.tr("Log Out"), systemImage: "rectangle.portrait.and.arrow.right")
                            .font(TSTheme.menuFont)
                            .foregroundColor(TSTheme.danger)
                    }
                }
                .disabled(viewModel.isAddingAccount || viewModel.isAuthenticating)
            }
        }
        .tsList()
        .labelStyle(TSRowLabelStyle())
        .navigationTitle(TSLocalization.tr("Accounts"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if viewModel.accounts.isEmpty == false { Menu {
                    Button(action: {
                        serverInput = viewModel.customCoordinationServer
                        showingServerSheet = true
                    }) {
                        Label(TSLocalization.tr("Use a custom coordination server"), systemImage: "server.rack")
                    }

                    Button(action: {
                        authKeyInput = ""
                        showingAuthKeySheet = true
                    }) {
                        Label(TSLocalization.tr("Use an auth key"), systemImage: "key.fill")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .tsIcon()
                        .foregroundColor(TSTheme.primaryLight)
                }
                .accessibilityLabel("登录选项")
                .disabled(viewModel.isAddingAccount || viewModel.isAuthenticating)
                }
            }
        }
        .sheet(isPresented: $showingAuthKeySheet) {
            NavigationView {
                Form {
                    Section {
                        SecureField("粘贴AuthKey", text: $authKeyInput)
                            .font(.system(.body, design: .monospaced))
                            .submitLabel(.done)
                            .onSubmit {
                                let key = authKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !key.isEmpty {
                                    showingAuthKeySheet = false
                                    viewModel.loginWithAuthKey(key)
                                }
                            }
                    } header: {
                        HStack {
                            Text("AuthKey")
                            Spacer()
                            TSInfoButton(title: "密钥说明", message: "在Tailscale管理控制台生成AuthKey后粘贴到此处。")
                        }.textCase(nil)
                    }
                }
                .tsList()
                .navigationTitle(TSLocalization.tr("Use an auth key"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { showingAuthKeySheet = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("入网") {
                            let key = authKeyInput
                            showingAuthKeySheet = false
                            viewModel.loginWithAuthKey(key)
                        }
                        .disabled(authKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .navigationViewStyle(StackNavigationViewStyle())
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showingServerSheet) {
            NavigationView {
                Form {
                    Section {
                        TextField("https://headscale.example.com", text: $serverInput)
                            .font(TSTheme.bodyFont)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .submitLabel(.done)
                            .onSubmit {
                                let srv = serverInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !srv.isEmpty {
                                    showingServerSheet = false
                                    viewModel.loginWithCustomServer(srv)
                                }
                            }
                    } header: {
                        HStack {
                            Text("服务器地址")
                            Spacer()
                            TSInfoButton(title: "服务器说明", message: "填写自建Headscale协调服务器的完整地址。")
                        }.textCase(nil)
                    }
                }
                .tsList()
                .navigationTitle(TSLocalization.tr("Use a custom coordination server"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { showingServerSheet = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("连接") {
                            let srv = serverInput
                            showingServerSheet = false
                            viewModel.loginWithCustomServer(srv)
                        }
                        .disabled(serverInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .navigationViewStyle(StackNavigationViewStyle())
            .preferredColorScheme(.dark)
        }
        .actionSheet(isPresented: $showingLogoutConfirm) {
            ActionSheet(
                title: Text(TSLocalization.tr("Log Out")),
                message: Text("确定断开并退出当前Tailscale网络吗？"),
                buttons: [
                    .destructive(Text(TSLocalization.tr("Log Out"))) {
                        viewModel.performFullLogout()
                        presentationMode.wrappedValue.dismiss()
                    },
                    .cancel(Text(TSLocalization.tr("Cancel")))
                ]
            )
        }
        // 在当前账户页显示新增错误，不依赖被设置页遮住的主页
        .alert(isPresented: Binding(
            get: { viewModel.additionError != nil },
            set: { if !$0 { viewModel.additionError = nil } }
        )) {
            Alert(
                title: Text(TSLocalization.tr("Operation Failed")),
                message: Text(viewModel.additionError ?? ""),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}
