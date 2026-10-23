"""检查共享样式、点击区域与主题对比度，不依赖UI测试框架。"""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
theme = (ROOT / "src/ui/TSTheme.swift").read_text(encoding="utf-8")
assert 'menuFont = Font.system(.body).weight(.semibold)' in theme
assert 'defaultMinListRowHeight, 48' in theme
assert 'minWidth: 44, minHeight: 44' in theme

# 头像与小图标共用固定列和文字起点，不依赖系统Label的自适应宽度。
assert 'struct TSRowLabelStyle: LabelStyle' in theme
assert 'configuration.icon.imageScale(.large).frame(width: 44)' in theme
assert 'HStack(spacing: 14)' in theme and 'configuration.title' in theme
for name in ["SettingsView", "AccountsView", "AboutView"]:
    text = (ROOT / f"src/ui/{name}.swift").read_text(encoding="utf-8")
    assert '.labelStyle(TSRowLabelStyle())' in text, name
about = (ROOT / "src/ui/AboutView.swift").read_text(encoding="utf-8")
assert '.clipShape(Circle())\n                            .frame(width: 44)' in about
assert '"chevron.left.forwardslash.chevron.right").foregroundColor(TSTheme.primaryLight)\n                            .frame(width: 44)' in about
assert 'HStack(spacing: 12)' not in about
accounts = (ROOT / "src/ui/AccountsView.swift").read_text(encoding="utf-8")
assert accounts.index('Label(TSLocalization.tr(viewModel.isAddingAccount') < accounts.index('if viewModel.isAddingAccount { ProgressView()')

# 所有同类列表共用样式，固定数字字号仅用于图形。
for name in ["SettingsView", "AccountsView", "DnsSettingsView", "AboutView", "FilesView"]:
    text = (ROOT / f"src/ui/{name}.swift").read_text(encoding="utf-8")
    assert ".tsList()" in text, name
    sizes = re.findall(r"\.font\(\.system\(size:\s*(\d+)", text)
    assert all(int(size) == 48 and name == "AboutView" for size in sizes), (name, sizes)
    assert "footer: Text" not in text or name == "FilesView", name
home = (ROOT / "src/ui/HomeView.swift").read_text(encoding="utf-8")
assert "@ScaledMetric" in home and "ScrollView" in home
assert "minHeight: 52" in home and ".frame(height: 54)" not in home
assert 'Toggle(""' not in home and '.accessibilityLabel(TSLocalization.tr("Settings"))' in home
assert '.frame(width: 28, height: 28)' in home and '.truncationMode' not in home
assert 'ScrollView(.vertical)' in home and 'viewModel.orderedPeers' in home
assert 'LazyVStack(alignment: .leading, spacing: 8)' in home
assert '.prefix(3)' not in home
assert 'TSIPText(address: viewModel.deviceIp)' in home
assert 'TSIPText(address: peer.ip' in home
assert '.overlay(alignment: .bottomTrailing)' in home
assert 'peer.online ? TSTheme.primaryLight : TSTheme.danger' in home
assert 'peer.online ? "Online" : "Offline"' in home
assert 'struct TSIPText' in theme and '.contextMenu' in theme
assert 'UIPasteboard.general.string = address' in theme and '.accessibilityAction' in theme
assert "struct TSScrollText" in theme and "accessibilityReduceMotion" in theme
assert "phase == .active" in theme and "width > available + 1" in theme
assert "repeatForever(autoreverses: true)" in theme and ".task(id: width)" in theme
assert "func tsIcon()" in theme and ".contentShape(Rectangle())" in theme
assert ".onDisappear { visible = false }" in theme and "phase == .active && visible" in theme
share = (ROOT / "src/share/ShareController.swift").read_text(encoding="utf-8")
assert ".tsList()" in share and "TSTheme.menuFont" in share
# 共用主题的本地化依赖必须同时进入扩展的独立编译清单。
build = (ROOT / "build.sh").read_text(encoding="utf-8")
share_build = build.split("-module-name TSFileShare", 1)[1].split('-o "${SHARE_DIR}/TSFileShare"', 1)[0]
assert "src/ui/TSTheme.swift" in share_build and "src/ui/TSLocalization.swift" in share_build

# 将主题颜色换算为WCAG相对亮度并检查文字对比度。
# 换算sRGB相对亮度。
def luminance(hex_color):
    channels = [int(hex_color[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    linear = [c / 12.92 if c <= .04045 else ((c + .055) / 1.055) ** 2.4 for c in channels]
    return sum(c * weight for c, weight in zip(linear, (.2126, .7152, .0722)))

# 计算文字与底色对比度。
def contrast(a, b):
    light, dark = sorted((luminance(a), luminance(b)), reverse=True)
    return (light + .05) / (dark + .05)

for foreground, background in [("FFFFFF", "0F766E"), ("F4F4F5", "18181B"), ("A1A1AA", "18181B"), ("14B8A6", "18181B")]:
    assert contrast(foreground, background) >= 4.5, (foreground, background)
print("PASS: shared semantic typography, native lists, touch targets, scalable home and AA text contrast")
