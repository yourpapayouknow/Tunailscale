// 验证完整导出、启动参数保留、脱敏及原日志不变
import Foundation

@main
struct LogTests {
    // 使用独立临时日志，不连接任何真实账户或后台
    static func main() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("test-logs-\(UUID().uuidString)")
        try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: directory) }
        let source = directory.appendingPathComponent("main.log")
        let startup = "Program starting: tailscaled --statedir=/private/test/daemon"
        let secret = "https://login.tailscale.com/a/private-session tskey-auth-private_secret privkey:012345abcdef AuthURL=\"https://headscale.example/confirm/private\""
        let original = ([startup, secret] + (0..<500).map { "entry-\($0)" }).joined(separator: "\n")
        try original.write(to: source, atomically: true, encoding: .utf8)
        let preview = TSLogs.read(paths: [source])
        assert(preview.contains(startup) && preview.contains("entry-499"))
        assert(!preview.contains("entry-0\n"), "UI preview is not bounded")
        let missing = directory.appendingPathComponent("missing.log")
        let exported = try TSLogs.export(paths: [source, missing], context: "Socket: /test.sock\nAuthKey: tskey-api-context_secret")
        defer { try? fm.removeItem(at: exported.deletingLastPathComponent()) }
        let text = try String(contentsOf: exported, encoding: .utf8)
        assert(text.contains("Build: "), "Export cannot identify the installed build")
        assert(text.contains(startup) && text.contains("entry-0\n") && text.contains("entry-499"))
        for token in ["private-session", "private_secret", "012345abcdef", "confirm/private", "context_secret"] {
            assert(!text.contains(token), "Sensitive token leaked into exported log")
        }
        assert(text.contains("Socket: /test.sock") && text.contains("无法读取日志"))
        assert(try! String(contentsOf: source, encoding: .utf8) == original, "Export modified source log")
        let permissions = try fm.attributesOfItem(atPath: exported.path)[.posixPermissions] as! NSNumber
        assert(permissions.intValue == 0o600)
        let folderPermissions = try fm.attributesOfItem(atPath: exported.deletingLastPathComponent().path)[.posixPermissions] as! NSNumber
        assert(folderPermissions.intValue == 0o700)
        try Data([65, 0xff, 66]).write(to: source)
        assert(TSLogs.read(paths: [source], full: true).contains("B"), "An invalid trailing byte discarded the entire log")
        // CLI 没有输出时仍保留构建、执行阶段与零收件结果。
        let job = directory.appendingPathComponent("job")
        try fm.createDirectory(at: job, withIntermediateDirectories: false)
        TSLogs.trace("begin operation=receive reason=appearance tskey-auth-trace_secret", in: job)
        TSLogs.trace("exit code=0 published files=0", in: job)
        try Data().write(to: job.appendingPathComponent("transfer.log"))
        let retained = directory.appendingPathComponent("retained.log")
        try TSLogs.retainTransfer(from: job, to: retained)
        let retainedText = try String(contentsOf: retained, encoding: .utf8)
        assert(retainedText.contains("Build: ") && retainedText.contains("reason=appearance"))
        assert(retainedText.contains("exit code=0 published files=0") && !retainedText.contains("trace_secret"))
        assert((try! fm.attributesOfItem(atPath: retained.path)[.posixPermissions] as! NSNumber).intValue == 0o600)
        assert((try! fm.attributesOfItem(atPath: job.appendingPathComponent("events.log").path)[.posixPermissions] as! NSNumber).intValue == 0o600)
        print("PASS: complete diagnostic export beyond 150 lines, startup retention, secret redaction, missing logs, private permissions, invalid UTF-8 and original preservation")
    }
}
