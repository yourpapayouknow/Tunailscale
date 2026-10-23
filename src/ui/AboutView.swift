//
//  AboutView.swift
//  TSNativeTailscale UI
//
//  关于页面 (原版 About Tailscale，纯净无冗余技术黑话)
//

import SwiftUI

public struct AboutView: View {
    public init() {}

    public var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    Image(uiImage: UIImage(named: "AppIcon512")!)
                        .resizable()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: TSTheme.radius))
                        .accessibilityHidden(true)
                        .padding(.top, 8)

                    Text("Tunailscale")
                        .font(.title3.weight(.semibold))
                        .foregroundColor(TSTheme.textPrimary)

                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0")
                        .font(TSTheme.detailFont)
                        .foregroundColor(TSTheme.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            Section(header: Text("项目")) {
                Link(destination: URL(string: "https://github.com/yourpapayouknow")!) {
                    HStack(spacing: 14) {
                        Image(uiImage: UIImage(named: "CreatorAvatar")!)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 40, height: 40)
                            .clipShape(Circle())
                            .frame(width: 44)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("iwmei").font(TSTheme.menuFont).foregroundColor(TSTheme.textPrimary)
                            TSScrollText(text: "github.com/yourpapayouknow", font: TSTheme.detailFont)
                                .foregroundColor(TSTheme.textSecondary)
                        }
                        Image(systemName: "arrow.up.right").font(TSTheme.detailFont).foregroundColor(TSTheme.textSecondary)
                    }
                }
                Link(destination: URL(string: "https://github.com/yourpapayouknow/Tunailscale")!) {
                    HStack(spacing: 14) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right").foregroundColor(TSTheme.primaryLight)
                            .frame(width: 44)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("项目仓库").font(TSTheme.menuFont).foregroundColor(TSTheme.textPrimary)
                            TSScrollText(text: "yourpapayouknow/Tunailscale", font: TSTheme.detailFont)
                                .foregroundColor(TSTheme.textSecondary)
                        }
                        Image(systemName: "arrow.up.right").font(TSTheme.detailFont).foregroundColor(TSTheme.textSecondary)
                    }
                }
            }

            Section(header: Text("Tailscale")) {
                Button(action: {
                    if let url = URL(string: "https://tailscale.com") {
                        UIApplication.shared.open(url)
                    }
                }) {
                    HStack {
                        Text("Tailscale官方网站")
                            .font(TSTheme.menuFont)
                            .foregroundColor(TSTheme.textPrimary)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(TSTheme.detailFont)
                            .foregroundColor(TSTheme.textSecondary)
                    }
                }

                Button(action: {
                    if let url = URL(string: "https://github.com/tailscale/tailscale") {
                        UIApplication.shared.open(url)
                    }
                }) {
                    HStack {
                        Text("Tailscale源码仓库")
                            .font(TSTheme.menuFont)
                            .foregroundColor(TSTheme.textPrimary)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(TSTheme.detailFont)
                            .foregroundColor(TSTheme.textSecondary)
                    }
                }

                Button(action: {
                    if let url = URL(string: "https://tailscale.com/terms") {
                        UIApplication.shared.open(url)
                    }
                }) {
                    HStack {
                        Text("服务条款")
                            .font(TSTheme.menuFont)
                            .foregroundColor(TSTheme.textPrimary)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(TSTheme.detailFont)
                            .foregroundColor(TSTheme.textSecondary)
                    }
                }
                Link(destination: URL(string: "https://tailscale.com/privacy-policy")!) {
                    HStack {
                        Text("隐私政策").font(TSTheme.menuFont).foregroundColor(TSTheme.textPrimary)
                        Spacer()
                        Image(systemName: "arrow.up.right").font(TSTheme.detailFont).foregroundColor(TSTheme.textSecondary)
                    }
                }
            }

            Section(header: Text("诊断与日志")) {
                NavigationLink(destination: LogViewerSheet()) {
                        Label("运行日志", systemImage: "doc.text")
                            .font(TSTheme.menuFont)
                            .foregroundColor(TSTheme.textPrimary)
                }
            }
        }
        .tsList()
        .labelStyle(TSRowLabelStyle())
        .navigationTitle("关于Tunailscale")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
    }
}

public struct LogViewerSheet: View {
    @State private var logContent: String = "正在加载"
    @State private var exporting = false
    @State private var exportURL: URL?
    @State private var showingExport = false
    @State private var exportError: String?

    public init() {}

    public var body: some View {
        ScrollView {
            Text(logContent)
                .font(TSTheme.monoFont)
                .textSelection(.enabled)
                .foregroundColor(TSTheme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .background(Color.black)
        .navigationTitle("运行日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack {
                    if exporting { ProgressView() }
                    Button { exportLog() } label: {
                        Label("导出完整日志", systemImage: "square.and.arrow.up").tsIcon()
                    }.disabled(exporting || showingExport)
                    Button { loadLog() } label: {
                        Label("刷新", systemImage: "arrow.clockwise").tsIcon()
                    }
                }
            }
        }
        .sheet(isPresented: $showingExport, onDismiss: clearExport) {
            if let url = exportURL { FileShare(url: url) { showingExport = false } }
        }
        .alert("日志导出失败", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("确定", role: .cancel) { exportError = nil }
        } message: { Text(exportError ?? "") }
        .onAppear {
            loadLog()
        }
    }

    // 近期日志只用于界面预览，不限制完整导出
    private func loadLog() {
        logContent = TSLogs.read()
    }

    // 在后台创建完整诊断副本，再交给现有系统文件分享面板
    private func exportLog() {
        guard !exporting else { return }
        exporting = true
        let context = "App: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "unknown")\nSocket: \(TSLocalAPI.activeSocketPath())\nUID: \(getuid()) EUID: \(geteuid())"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let url = try TSLogs.export(context: context)
                Task { @MainActor in exportURL = url; exporting = false; showingExport = true }
            } catch {
                Task { @MainActor in exporting = false; exportError = error.localizedDescription }
            }
        }
    }

    // 分享结束仅移除自有导出副本，原日志和用户另存的文件不变
    private func clearExport() {
        if let url = exportURL { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        exportURL = nil
    }
}
