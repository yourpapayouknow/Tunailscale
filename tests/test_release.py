"""检查发布身份、凭据隔离与关于页归属。"""
from pathlib import Path
import hashlib
import math
import plistlib
import sys
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[1]
bundle = "com.iwmei.tunailscale"
group = f"group.{bundle}"
app = plistlib.loads((ROOT / "src/app/Info.plist").read_bytes())
share = plistlib.loads((ROOT / "src/share/Info.plist").read_bytes())
assert app["CFBundleIdentifier"] == bundle
assert app["CFBundleDisplayName"] == "Tunailscale"
assert share["CFBundleIdentifier"] == f"{bundle}.share"
assert app["CFBundleShortVersionString"] == share["CFBundleShortVersionString"] == "1.0.0"
core_build = (ROOT / "build_tailscaled.sh").read_text(encoding="utf-8")
assert 'export GOTOOLCHAIN=go1.27.3' in core_build
assert 'b83f28ebfbd9f86c2543e30e9dcf035a417dce1e' in core_build
assert '~/tailscale-repo' not in core_build and '~/build_tsnativeprobe' not in core_build
test_runner = (ROOT / "tests/run_tests.sh").read_text(encoding="utf-8")
assert 'DAEMON_BIN="${PWD}/build/test-viewmodel/host-tailscaled"' in test_runner
assert 'go version "$DAEMON_BIN"' in test_runner
for name in ("app_b", "share"):
    entitlements = plistlib.loads((ROOT / f"entitlements/{name}.plist").read_bytes())
    assert entitlements["com.apple.security.application-groups"] == [group]
api = (ROOT / "src/tailscale/TSLocalAPI.m").read_text(encoding="utf-8")
assert f'@"{group}"' in api
model = (ROOT / "src/ui/TSViewModel.swift").read_text(encoding="utf-8")
assert 'appendingPathComponent("Tunailscale/Accounts")' in model
assert '"/var/root/tunailscale.state"' in model
assert '"/var/root/Tunailscale"' in model
for legacy in ("TSNativeTailscale/Accounts", "/var/root/tailscaled.state", "/var/root/TSNativeTailscale", "/var/run/tailscaled-auth.sock"):
    assert legacy not in model, legacy
about = (ROOT / "src/ui/AboutView.swift").read_text(encoding="utf-8")
for value in ("https://github.com/yourpapayouknow", "https://github.com/yourpapayouknow/Tunailscale", 'Text("iwmei")', 'UIImage(named: "CreatorAvatar")'):
    assert value in about, value
assert (ROOT / "src/app/icons/CreatorAvatar.png").read_bytes().startswith(b"\x89PNG\r\n\x1a\n")
# 九点坐标、半径和原有配色必须与批准的矢量母版一致。
icon = ET.parse(ROOT / "src/app/icons/AppIcon.svg").getroot()
circles = icon.findall("{http://www.w3.org/2000/svg}circle")
assert [(float(c.attrib["cx"]), float(c.attrib["cy"])) for c in circles] == [(x, y) for y in (128, 256, 384) for x in (128, 256, 384)]
assert all(math.isclose(float(c.attrib["r"]), 512 / 12) for c in circles)
assert [c.attrib["fill"] for c in circles] == ["#374151", "#14B8A6", "#374151", "#14B8A6", "#14B8A6", "#14B8A6", "#374151", "#14B8A6", "#374151"]
print("PASS: release bundle, share group, fresh credentials and creator links")

# 对交付包逐项核对身份、构建号和本地图像。
if len(sys.argv) == 2:
    package = Path(sys.argv[1])
    with zipfile.ZipFile(package) as archive:
        builds = []
        for path, expected in (("Info.plist", app), ("PlugIns/TSFileShare.appex/Info.plist", share)):
            actual = plistlib.loads(archive.read(f"Payload/TSNativeTailscale.app/{path}"))
            assert all(actual.get(key) == value for key, value in expected.items()), path
            builds.append(actual["TSBuildID"])
        assert builds[0] == builds[1]
        for resource in (ROOT / "src/app/icons").glob("*.png"):
            assert archive.read(f"Payload/TSNativeTailscale.app/{resource.name}") == resource.read_bytes(), resource.name
        assert archive.read("Payload/TSNativeTailscale.app/THIRD_PARTY_NOTICES.md") == (ROOT / "THIRD_PARTY_NOTICES.md").read_bytes()
        for notice in (ROOT / "licenses").rglob("*"):
            if notice.is_file():
                assert archive.read("Payload/TSNativeTailscale.app/" + notice.relative_to(ROOT).as_posix()) == notice.read_bytes(), notice
    print(f"PASS: packaged identifiers, build and images; Build={builds[0]}")
    print(f"SHA256={hashlib.sha256(package.read_bytes()).hexdigest()}")
