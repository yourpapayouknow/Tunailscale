//
//  TSTheme.swift
//  TSNativeTailscale UI
//
//  海沫绿(Seafoam Green)主题系统 (SwiftUI)
//

import SwiftUI

public enum TSTheme {
    /* 海沫绿核心主色调 */
    public static let primary = Color(red: 13/255.0, green: 148/255.0, blue: 136/255.0)       // #0D9488 深海沫绿
    static let primaryFill = Color(red: 15/255.0, green: 118/255.0, blue: 110/255.0)          // #0F766E 白字按钮对比色
    public static let primaryLight = Color(red: 20/255.0, green: 184/255.0, blue: 166/255.0)  // #14B8A6 明亮海沫绿
    public static let accent = Color(red: 45/255.0, green: 212/255.0, blue: 191/255.0)        // #2DD4BF 青翠高亮
    public static let warning = Color(red: 245/255.0, green: 158/255.0, blue: 11/255.0)       // #F59E0B
    public static let danger = Color(red: 239/255.0, green: 68/255.0, blue: 68/255.0)         // #EF4444

    /* 暗黑背景与卡片底色 (参照原版纯黑/深灰) */
    public static let background = Color(red: 9/255.0, green: 10/255.0, blue: 10/255.0)       // #090A0A
    public static let surface = Color(red: 24/255.0, green: 24/255.0, blue: 27/255.0)         // #18181B
    public static let surfaceLight = Color(red: 39/255.0, green: 39/255.0, blue: 42/255.0)    // #27272A
    public static let border = Color(red: 63/255.0, green: 63/255.0, blue: 70/255.0)          // #3F3F46

    /* 文字色 */
    public static let textPrimary = Color(red: 244/255.0, green: 244/255.0, blue: 245/255.0)  // #F4F4F5
    public static let textSecondary = Color(red: 161/255.0, green: 161/255.0, blue: 170/255.0)// #A1A1AA

    // 原生语义字号跟随系统文字大小，所有页面复用同一层级
    static let menuFont = Font.system(.body).weight(.semibold)
    static let bodyFont = Font.body
    static let detailFont = Font.subheadline
    static let monoFont = Font.system(.footnote, design: .monospaced).weight(.medium)
    static let margin: CGFloat = 16
    static let radius: CGFloat = 8
}

// 统一原生列表行高、正文与操作色
extension View {
    func tsList() -> some View {
        self.listStyle(InsetGroupedListStyle())
            .font(TSTheme.bodyFont)
            .environment(\.defaultMinListRowHeight, 48)
            .tint(TSTheme.primaryLight)
    }

    // 所有工具栏与信息入口使用同一图标尺寸和点击区域
    func tsIcon() -> some View {
        self.labelStyle(.iconOnly).font(TSTheme.menuFont).frame(minWidth: 44, minHeight: 44)
    }
}

// 列表小图标与账户头像共用中心线和文字起点
struct TSRowLabelStyle: LabelStyle {
    // 保留原生列表图标比例，只统一水平位置
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 14) {
            configuration.icon.imageScale(.large).frame(width: 44)
            configuration.title
        }
    }
}

// 触屏通过信息按钮阅读说明，不依赖悬浮或挤占正文
struct TSInfoButton: View {
    let title: String
    let message: String
    @State private var showing = false
    var body: some View {
        Button { showing = true } label: {
            Label(title, systemImage: "info.circle").tsIcon()
        }
        .accessibilityLabel(title)
        .alert(title, isPresented: $showing) { Button("确定", role: .cancel) {} } message: { Text(message) }
    }
}

// IP共用系统长按菜单和辅助功能复制操作
struct TSIPText: View {
    let address: String
    var color: Color = TSTheme.textSecondary

    var body: some View {
        Text(address).font(TSTheme.monoFont).foregroundColor(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: 44).contentShape(Rectangle())
            .contextMenu {
                Button { Self.copy(address) } label: {
                    Label(TSLocalization.tr("Copy IP"), systemImage: "doc.on.doc")
                }
            }
            .accessibilityAction(named: Text(TSLocalization.tr("Copy IP"))) { Self.copy(address) }
    }

    // 原样复制完整IPv4或IPv6地址
    static func copy(_ address: String) { UIPasteboard.general.string = address }
}

// 所有设备列表复用同一系统图标映射
extension TSTailscalePeer {
    var deviceSymbol: String {
        switch os.lowercased() {
        case "ios", "android": return "iphone"
        case "macos", "windows", "linux": return "desktopcomputer"
        default: return "laptopcomputer"
        }
    }
}

// 超宽文字使用原生单行往返动画；减少动态效果时完整换行
struct TSScrollText: View {
    let text: String
    var font: Font = TSTheme.bodyFont
    @Environment(\.accessibilityReduceMotion) private var reduced
    @Environment(\.scenePhase) private var phase
    @Environment(\.sizeCategory) private var size
    @State private var visible = false

    var body: some View {
        Group {
            if reduced {
                Text(text).font(font).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(text).font(font).lineLimit(1).hidden()
                    .overlay(alignment: .leading) {
                        GeometryReader { viewport in
                            TSScrollLine(text: text, font: font, available: viewport.size.width, active: phase == .active && visible)
                                .id("\(text)|\(viewport.size.width)|\(size)|\(phase == .active && visible)")
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .onAppear { visible = true }
        .onDisappear { visible = false }
    }
}

// 动画状态只属于当前可见文本，离页、后台或布局变化会销毁旧动画
private struct TSScrollLine: View {
    let text: String
    let font: Font
    let available: CGFloat
    let active: Bool
    @State private var width: CGFloat = 0
    @State private var offset: CGFloat = 0

    var body: some View {
        Text(text).font(font).fixedSize(horizontal: true, vertical: false)
            .background(GeometryReader { size in Color.clear.preference(key: TSTextWidth.self, value: size.size.width) })
            .offset(x: offset)
            .frame(width: available, alignment: .leading).clipped()
            .onPreferenceChange(TSTextWidth.self) { width = $0 }
            .task(id: width) {
                guard active, available > 0, width > available + 1 else { return }
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                guard !Task.isCancelled else { return }
                withAnimation(.linear(duration: max(2, Double(width - available) / 24)).delay(1.5).repeatForever(autoreverses: true)) {
                    offset = available - width
                }
            }
    }
}

// 读取当前文本的实际排版宽度
private struct TSTextWidth: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
