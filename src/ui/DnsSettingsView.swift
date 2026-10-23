//
//  DnsSettingsView.swift
//  TSNativeTailscale UI
//
//  DNS与路由配置页面 (原版 DNS Settings)
//

import SwiftUI

public struct DnsSettingsView: View {
    @ObservedObject var viewModel: TSViewModel

    public init(viewModel: TSViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        List {
            Section {
                Toggle("启用MagicDNS", isOn: Binding(
                    get: { viewModel.enableMagicDns },
                    set: { viewModel.setMagicDns(enabled: $0) }
                ))
                .toggleStyle(SwitchToggleStyle(tint: TSTheme.primaryLight))
                .font(TSTheme.menuFont)
            }
        }
        .tsList()
        .navigationTitle(TSLocalization.tr("DNS Settings"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                TSInfoButton(title: "DNS说明", message: "MagicDNS用于通过设备名访问Tailnet内的主机。具体域名和DNS配置由网络管理员设置。")
            }
        }
        .preferredColorScheme(.dark)
    }
}
