// 统一读取、脱敏和导出诊断日志，不读取账户凭据文件
import Foundation

enum TSLogs {
    static let additionURL = FileManager.default.temporaryDirectory.appendingPathComponent("ts-add-account.log")
    static let transferURL = FileManager.default.temporaryDirectory.appendingPathComponent("ts-file-transfer.log")
    static let paths = [URL(fileURLWithPath: "/tmp/tailscaled.log"), additionURL, transferURL]
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "TSBuildID") as? String ?? "unmarked" }

    // 隐藏临时授权链接、AuthKey 和私钥字符串，保留可定位问题的参数与状态
    static func redacted(_ text: String) -> String {
        var safe = text
        for pattern in [#"https?://[^\s\"<>]+/(?:a|register)/[^\s\"<>]+"#, #"tskey-(?:auth|api)-[A-Za-z0-9_-]+"#, #"privkey:[A-Fa-f0-9]+"#] {
            safe = safe.replacingOccurrences(of: pattern, with: "<redacted>", options: .regularExpression)
        }
        return safe.replacingOccurrences(of: #"(?i)(AuthURL[\"\s]*[=:][\"\s]*)(https?://[^\s\"<>]+)"#, with: "$1<redacted>", options: .regularExpression)
    }

    // 界面只显示近期日志并保留启动行，导出完整保留所有可读取内容
    static func read(paths: [URL] = paths, full: Bool = false) -> String {
        paths.map { url in
            let body: String
            do {
                let text = redacted(String(decoding: try Data(contentsOf: url), as: UTF8.self))
                if full { body = text }
                else {
                    let lines = text.components(separatedBy: "\n")
                    let recent = lines.suffix(150)
                    let startup = lines.first { $0.contains("Program starting:") }
                    let header = startup.map { recent.contains($0) ? "" : $0 + "\n...最近日志...\n" } ?? ""
                    body = header + recent.joined(separator: "\n")
                }
            } catch { body = "无法读取日志: \(error.localizedDescription)" }
            return "=== \(url.path) ===\n" + body
        }.joined(separator: "\n\n")
    }

    // 保存有限的传输阶段记录，不记录文件正文或账户凭据。
    static func trace(_ event: String, in job: URL?) {
        // 同步到系统日志，USB 采集无需访问 App 私有容器。
        let safe = redacted(event)
        NSLog("[TSTransfer] %@", safe)
        guard let job = job else { return }
        let url = job.appendingPathComponent("events.log")
        do {
            var data = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : Data()
            data.append(Data("\(ISO8601DateFormatter().string(from: Date())) \(safe)\n".utf8))
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { NSLog("Unable to record transfer diagnostics: %@", error.localizedDescription) }
    }

    // 保存最近任务的阶段记录与 CLI 输出，空输出不再丢失执行结果。
    static func retainTransfer(from job: URL, to destination: URL = transferURL) throws {
        let sources = [job.appendingPathComponent("events.log"), job.appendingPathComponent("transfer.log")]
        guard sources.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return }
        try Data("Build: \(build)\n\(read(paths: sources, full: true))".utf8).write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    // 独立临时文本交给系统分享，不修改或截断原日志
    static func export(paths: [URL] = paths, context: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ts-logs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let url = directory.appendingPathComponent("TSNativeTailscale-diagnostics.txt")
            let header = "TSNativeTailscale diagnostics\nGenerated: \(ISO8601DateFormatter().string(from: Date()))\nBuild: \(build)\n\(redacted(context))\nContains account and network information. Share carefully.\n\n"
            try (header + read(paths: paths, full: true)).write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
}
