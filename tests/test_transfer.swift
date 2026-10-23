// 使用真实文件系统验证传输、账户固定和接收中断保护
import Foundation

final class TSTailscalePeer {
    var ip = "100.64.0.2"
    var taildropAvailable = true
    var peerAPIURLs = ["http://[fd7a:115c:a1e0::2]:1234"]
}

// 原生 URLSession 使用受控 HTTP 回包，不替代任务取消和账户验证
final class TransferProtocol: URLProtocol {
    static var received: URLRequest?
    static var status = 200
    static var hold = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.received = request
        guard !Self.hold else { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
final class TSTailscaleProfile {
    var profileId = "one"
    var name = "test"
    var serverUrl = "https://controlplane.tailscale.com"
    var nodeID = "node-one"
    var isCurrent = true
}
final class TSLocalAPI {
    static var profiles = [TSTailscaleProfile()]
    static var pending: (([TSTailscaleProfile], Error?) -> Void)?
    static var delayed = false
    // 只替代 HTTP，不替代文件路径和账户验证逻辑
    static func listProfiles(socketPath: String, completion: @escaping ([TSTailscaleProfile], Error?) -> Void) {
        assert(socketPath == "/tmp/pinned-file.sock")
        if delayed { pending = completion } else { completion(profiles, nil) }
    }
}
final class SpawnRoot {
    static var arguments: [String] = []
    static var result: Int32 = -EAGAIN
    static var failure: Int32 = 0
    static var stopped = 0
    static var onSpawn: (([String]) -> Void)?
    // 保留真实参数，受控退出码不启动网络或特权进程
    static func spawnHelperBinary(_ path: String, args: [String], environment: [String: String], root: Bool, logPath: String, pid: inout pid_t, errNum: inout Int32, errMsg: inout NSString?) -> Int32 {
        assert(!root && environment.isEmpty && args.first == "--socket=/tmp/pinned-file.sock")
        arguments = args
        if failure != 0 { errNum = failure; return failure }
        pid = 42
        onSpawn?(args)
        return 0
    }
    static func pollChild(_ pid: pid_t) -> Int32 { result }
    static func terminateChild(_ pid: pid_t) -> Int32 { stopped += 1; return 0 }
}

@main
struct TransferTests {
    // 交付主执行器上的异步 Profile 回包
    @MainActor static func settle() async { for _ in 0..<20 { await Task.yield() } }

    // 覆盖正常、空文件、重名、中断、迟到回包和不同账户
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("test-transfer-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let account = TSAccountItem(name: "test", isActive: true, profileId: "one", nodeID: "node-one")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TransferProtocol.self]
        let transfer = TSFileTransfer(executable: "/test/tailscale", configuration: configuration)
        transfer.configure(account: account, socketPath: "/tmp/pinned-file.sock", downloads: root)
        let directory = transfer.directory!
        assert(directory.lastPathComponent.count == 64)
        let other = TSAccountItem(name: "test", profileId: "two")
        assert(TSFileTransfer.folder(for: other, downloads: root) != directory)
        var anotherServer = account
        anotherServer.serverUrl = "https://headscale.example"
        assert(TSFileTransfer.folder(for: anotherServer, downloads: root) != directory)

        // 空收件箱检查成功不能伪报传输完成。
        SpawnRoot.result = 0
        transfer.receive(reason: "appearance"); await settle(); transfer.poll()
        assert(!transfer.busy && transfer.files.isEmpty && transfer.incomplete.isEmpty)
        assert(transfer.message == nil, "Empty inbox reported a completed transfer")
        let emptyLog = try String(contentsOf: TSLogs.transferURL, encoding: .utf8)
        assert(emptyLog.contains("operation=receive reason=appearance") && emptyLog.contains("exit code=0"))
        assert(emptyLog.contains("published files=0") && emptyLog.contains("finish message=<none>"))
        SpawnRoot.result = -EAGAIN

        SpawnRoot.onSpawn = { args in
            let destination = URL(fileURLWithPath: args.last!, isDirectory: true)
            try! Data("complete".utf8).write(to: destination.appendingPathComponent("中文.txt"))
            try! Data().write(to: destination.appendingPathComponent("empty"))
        }
        transfer.receive()
        await settle()
        assert(transfer.busy && transfer.files.isEmpty)
        assert(SpawnRoot.arguments.contains("--conflict=rename"))
        SpawnRoot.result = 0
        transfer.poll()
        assert(!transfer.busy && transfer.files.count == 2 && transfer.incomplete.isEmpty)
        assert(transfer.message == "文件传输完成")
        assert(try! Data(contentsOf: directory.appendingPathComponent("中文.txt")) == Data("complete".utf8))

        // 自动进入和账户刷新可以收件，但不能弹出手动操作成功窗。
        for reason in ["appearance", "account-change"] {
            let automatic = TSFileTransfer(executable: "/test/tailscale")
            automatic.configure(account: account, socketPath: "/tmp/pinned-file.sock", downloads: root.appendingPathComponent(reason))
            automatic.receive(reason: reason); await settle(); automatic.poll()
            assert(!automatic.busy && automatic.files.count == 2)
            assert(automatic.message == nil, "Automatic receipt showed a completion popup; fixture: \(root.path)")
            SpawnRoot.result = 1
            automatic.receive(reason: reason); await settle(); automatic.poll()
            assert(automatic.message?.contains("传输未完成") == true, "Automatic receipt hid a real error")
            SpawnRoot.result = 0
        }

        // 接收同名文件时不覆盖既有内容
        transfer.receive(); await settle(); transfer.poll()
        assert(transfer.files.count == 4)
        assert(fm.fileExists(atPath: directory.appendingPathComponent("中文 (1).txt").path))
        assert(fm.fileExists(atPath: directory.appendingPathComponent("empty (1)").path))

        // CLI 失败可能已从收件箱取走部分文件，全部保留但不当成成功
        SpawnRoot.result = 1
        transfer.receive(); await settle(); transfer.poll()
        assert(transfer.files.count == 4 && transfer.incomplete.count == 1)
        let incomplete = transfer.incomplete[0]
        assert(try! Data(contentsOf: incomplete.appendingPathComponent("中文.txt")) == Data("complete".utf8))
        assert(transfer.message?.contains("未验证完整") == true)
        SpawnRoot.result = -EAGAIN
        transfer.receive(); await settle(); transfer.cancel()
        assert(!transfer.busy && transfer.files.count == 4 && transfer.incomplete.count == 2)

        // 发送只用独立副本，文件名不能覆盖自己的任务日志
        SpawnRoot.onSpawn = nil
        // 已接收列表非空时，空收件箱仍须静默刷新。
        SpawnRoot.result = 0
        transfer.receive(); await settle(); transfer.poll()
        assert(!transfer.busy && transfer.files.count == 4 && transfer.incomplete.count == 2)
        assert(transfer.message == nil, "Existing files caused a false transfer notification")
        SpawnRoot.result = -EAGAIN
        let source = root.appendingPathComponent("transfer.log")
        try Data("original".utf8).write(to: source)
        let peer = TSTailscalePeer(); peer.ip = "fd7a:115c:a1e0::2"
        let beforeSend = SpawnRoot.arguments
        TransferProtocol.hold = true
        transfer.send(source, to: peer)
        for _ in 0..<200 {
            if TransferProtocol.received != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        assert(SpawnRoot.arguments == beforeSend, "Native send launched a CLI process")
        assert(TransferProtocol.received?.httpMethod == "PUT")
        assert(TransferProtocol.received?.url?.absoluteString == "http://[fd7a:115c:a1e0::2]:1234/v0/put/transfer.log")
        assert(TransferProtocol.received?.value(forHTTPHeaderField: "Content-Length") == "8")
        transfer.cancel()
        for _ in 0..<200 { if !transfer.busy { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        assert(try! Data(contentsOf: source) == Data("original".utf8))
        assert(!transfer.busy)

        // 发送成功仍显示完成，不受空接收判定影响。
        TransferProtocol.hold = false
        transfer.send(source, to: peer)
        for _ in 0..<200 {
            await settle(); transfer.poll()
            if !transfer.busy { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        assert(!transfer.busy && transfer.message == "文件传输完成")
        // 非成功状态必须报告失败；错误地址不能向其他主机发送
        TransferProtocol.status = 403
        transfer.send(source, to: peer)
        for _ in 0..<200 { if !transfer.busy { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        assert(transfer.message?.contains("HTTP 403") == true)
        let previousUpload = TransferProtocol.received?.url
        peer.peerAPIURLs = ["http://evil.example:1234"]
        transfer.send(source, to: peer)
        assert(!transfer.busy && transfer.message?.contains("接收地址") == true)
        assert(TransferProtocol.received?.url == previousUpload)
        peer.peerAPIURLs = ["http://[fd7a:115c:a1e0::2]:1234"]
        TransferProtocol.status = 200
        let shareTransfer = TSFileTransfer(executable: "/forbidden", configuration: configuration)
        shareTransfer.configure(account: account, socketPath: "/tmp/pinned-file.sock")
        assert(shareTransfer.directory == nil && shareTransfer.files.isEmpty && shareTransfer.message == nil)
        shareTransfer.send(source, to: peer)
        for _ in 0..<200 { if !shareTransfer.busy { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        assert(shareTransfer.message == "文件传输完成")
        SpawnRoot.result = -EAGAIN

        // 迟到 Profile 回包不能启动已取消任务
        TSLocalAPI.delayed = true
        let previous = SpawnRoot.arguments
        transfer.receive(); transfer.cancel()
        TSLocalAPI.pending?(TSLocalAPI.profiles, nil)
        await settle()
        assert(SpawnRoot.arguments == previous && !transfer.busy)
        TSLocalAPI.delayed = false

        // 即使同名账户也必须核对原生 ProfileID 和 NodeID
        TSLocalAPI.profiles[0].nodeID = "other-node"
        transfer.receive(); await settle()
        assert(!transfer.busy && SpawnRoot.arguments == previous)
        assert(transfer.message?.contains("后台账户已改变") == true)
        TSLocalAPI.profiles[0].nodeID = "node-one"
        SpawnRoot.failure = ENOENT
        transfer.receive(); await settle()
        assert(!transfer.busy && transfer.files.count == 4)
        SpawnRoot.failure = 0

        // 拒绝源符号链接和账户目录重定向，删除不越界
        let link = root.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: source)
        do { _ = try TSFileTransfer.stage(link, in: root.appendingPathComponent("copy")); assertionFailure("Accepted symlink") }
        catch {}
        transfer.delete(source)
        assert(fm.fileExists(atPath: source.path))
        transfer.delete(directory.appendingPathComponent("empty"))
        assert(transfer.files.count == 3)
        try fm.removeItem(at: directory)
        try fm.createSymbolicLink(at: directory, withDestinationURL: root)
        transfer.receive()
        assert(!transfer.busy && transfer.message?.contains("符号链接") == true)

        // 零字节文件属于真实收件，必须保留并提示完成。
        let zeroTransfer = TSFileTransfer(executable: "/test/tailscale")
        zeroTransfer.configure(account: account, socketPath: "/tmp/pinned-file.sock", downloads: root.appendingPathComponent("zero"))
        SpawnRoot.onSpawn = { args in
            try! Data().write(to: URL(fileURLWithPath: args.last!).appendingPathComponent("empty"))
        }
        SpawnRoot.result = 0
        zeroTransfer.receive(); await settle(); zeroTransfer.poll()
        assert(!zeroTransfer.busy && zeroTransfer.files.count == 1)
        assert(zeroTransfer.message == "文件传输完成")
        assert(try! Data(contentsOf: zeroTransfer.files[0]).isEmpty)

        // 真实原生文件锁允许并行传输，但不允许同时切换账户
        let lock = root.appendingPathComponent("account.lock")
        let shared = try TSAccountLease(file: lock, exclusive: false)
        let second = try TSAccountLease(file: lock, exclusive: false)
        do { _ = try TSAccountLease(file: lock, exclusive: true); assertionFailure("Changed account during transfer") }
        catch {}
        shared.release(); second.release()
        let exclusive = try TSAccountLease(file: lock, exclusive: true)
        do { _ = try TSAccountLease(file: lock, exclusive: false); assertionFailure("Transferred during authentication") }
        catch {}
        exclusive.release()
        print("PASS: Taildrop empty inbox stays silent, real send/receive notifications, pinned accounts, IPv6, file copies, zero-byte and Unicode files, no overwrite, interrupted retention, cancellation, stale callbacks, symlink rejection, native account locks")
    }
}
