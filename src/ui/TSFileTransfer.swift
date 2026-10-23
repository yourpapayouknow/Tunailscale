// 使用官方 Taildrop 协议流式发送、CLI 接收，不加载整个文件
import Foundation
import Combine
import CryptoKit

@MainActor
final class TSFileTransfer: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var files: [URL] = []
    @Published private(set) var incomplete: [URL] = []
    @Published var message: String?
    private(set) var directory: URL?
    private var job: URL?
    private var pid: pid_t = 0
    private var timer: Timer?
    private var accountID: String?
    private var account: TSAccountItem?
    private var socket = ""
    private let executable: String
    private var lease: TSAccountLease?
    private var receiving: URL?
    private var notifySuccess = true
    private let session: URLSession
    private var upload: URLSessionUploadTask?
    private var cancelling = false

    // 注入测试二进制；正式运行始终使用包内 CLI
    init(executable: String = Bundle.main.bundleURL.appendingPathComponent("tailscale").path, configuration: URLSessionConfiguration = .ephemeral) {
        self.executable = executable
        configuration.connectionProxyDictionary = [:]
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        session = URLSession(configuration: configuration, delegate: TSNoRedirect(), delegateQueue: nil)
    }

    // 为每个原生账户分配稳定目录，不把邮件地址或密钥用作路径
    static func folder(for account: TSAccountItem, downloads: URL) -> URL {
        let identity = account.serverUrl + "|" + account.id
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return downloads.appendingPathComponent("Taildrop").appendingPathComponent(key)
    }

    // 切换账户时取消旧任务，固定本次使用的 socket 和接收目录
    func configure(account: TSAccountItem?, socketPath: String, downloads: URL? = nil) {
        if accountID != account?.id || socket != socketPath { cancel() }
        guard !busy else { return }
        accountID = account?.id
        self.account = account
        socket = socketPath
        directory = account.flatMap { account in downloads.map { Self.folder(for: account, downloads: $0) } }
        reload()
    }

    // 只列出本账户目录中的普通文件，不跟随文件符号链接
    func reload() {
        files = []
        incomplete = []
        guard let directory = directory, FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            try checkDirectory(directory)
            let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
            incomplete = try entries.filter { url in
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                return url.lastPathComponent.hasPrefix("接收中-") && UUID(uuidString: String(url.lastPathComponent.dropFirst(4))) != nil
                    && values.isDirectory == true && values.isSymbolicLink != true
            }
            files = try entries
                .filter { url in
                    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    return values.isRegularFile == true && values.isSymbolicLink != true
                }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        } catch { message = error.localizedDescription }
    }

    // 校验仅由 App 创建的 Taildrop 两层目录，拒绝重定向到其他位置
    private func checkDirectory(_ directory: URL) throws {
        for url in [directory.deletingLastPathComponent(), directory] {
            if FileManager.default.fileExists(atPath: url.path), try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeSymbolicLink {
                throw NSError(domain: "Taildrop", code: Int(ELOOP), userInfo: [NSLocalizedDescriptionKey: "拒绝使用符号链接接收目录"])
            }
        }
    }

    // 完整接收后才发布到文件列表，中断产物保留在明确标记的目录
    func receive(reason: String = "manual") {
        guard !busy, accountID != nil, let directory = directory else { return }
        // 自动收件只更新列表，完成弹窗只回应手动操作。
        notifySuccess = reason == "manual"
        do {
            try checkDirectory(directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            _ = try workspace("receive reason=\(reason)")
            busy = true
            let staging = directory.appendingPathComponent("接收中-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            receiving = staging
            TSLogs.trace("receive staging=\(staging.path)", in: job)
            try launch(["file", "get", "--conflict=rename", staging.path])
        } catch { finish(error.localizedDescription) }
    }

    // 在安全作用域内复制文件，通过原生上传发送独立副本
    func send(_ source: URL, to peer: TSTailscalePeer) {
        guard !busy, accountID != nil, peer.taildropAvailable, peer.ip != "--", !peer.ip.isEmpty else { return }
        notifySuccess = true
        let address = peer.ip
        do {
            guard let base = peer.peerAPIURLs.compactMap(URL.init(string:)).first(where: {
                $0.scheme == "http" && $0.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) == peer.ip
                    && $0.port != nil && $0.user == nil && $0.password == nil
                    && ($0.path.isEmpty || $0.path == "/") && $0.query == nil && $0.fragment == nil
            }) else { throw TSShareState.failure("设备未提供有效的文件接收地址") }
            let workspace = try workspace("send")
            busy = true
            let token = workspace
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    let copy = try Self.stage(source, in: workspace.appendingPathComponent("source"))
                    Task { @MainActor [weak self] in
                        guard let self = self, self.job == token else { try? FileManager.default.removeItem(at: workspace); return }
                        self.authorize {
                            var request = URLRequest(url: base.appendingPathComponent("v0/put").appendingPathComponent(copy.lastPathComponent))
                            request.httpMethod = "PUT"
                            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                            let size = try copy.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                            request.setValue(String(size), forHTTPHeaderField: "Content-Length")
                            TSLogs.trace("upload bytes=\(size) target=\(address)", in: self.job)
                            self.upload = self.session.uploadTask(with: request, fromFile: copy) { [self] data, response, error in
                                Task { @MainActor in
                                    guard self.job == token else { return }
                                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                                    TSLogs.trace("upload HTTP=\(code) error=\(error?.localizedDescription ?? "<none>")", in: self.job)
                                    if self.cancelling { self.finish(nil) }
                                    else if let error = error { self.finish(error.localizedDescription) }
                                    else if code == 200 { self.finish("文件传输完成") }
                                    else { self.finish("发送失败 (HTTP \(code))\n\(String(decoding: (data ?? Data()).prefix(2000), as: UTF8.self))") }
                                }
                            }
                            self.upload?.resume()
                        }
                    }
                } catch {
                    Task { @MainActor [weak self] in
                        guard let self = self, self.job == token else { try? FileManager.default.removeItem(at: workspace); return }
                        self.finish(error.localizedDescription)
                    }
                }
            }
        } catch { message = error.localizedDescription }
    }

    // 分享扩展须在 NSItemProvider 临时 URL 失效前复制，主 App 复用相同校验
    nonisolated static func stage(_ source: URL, in folder: URL) throws -> URL {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard source.isFileURL, values.isRegularFile == true, values.isSymbolicLink != true else {
            throw NSError(domain: "Taildrop", code: Int(EINVAL), userInfo: [NSLocalizedDescriptionKey: "请选择普通文件，不支持文件夹或符号链接"])
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let copy = folder.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: copy)
        return copy
    }

    // 创建任务专属临时目录，取消只能清理自己的副本与日志
    private func workspace(_ operation: String) throws -> URL {
        let lease = try TSAccountLease.acquire(exclusive: false)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ts-file-\(UUID().uuidString)")
        do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch { lease?.release(); throw error }
        self.lease = lease
        job = url
        TSLogs.trace("begin operation=\(operation) build=\(TSLogs.build) socket=\(socket) previous_message=\(message ?? "<none>")", in: job)
        message = nil
        return url
    }

    // 参数直接传给 posix_spawn，不经过 shell
    private func launch(_ arguments: [String]) throws {
        authorize { try self.spawn(arguments) }
    }

    // 发送和接收共用固定账户验证，取消后忽略迟到回包
    private func authorize(_ action: @escaping () throws -> Void) {
        guard let job = job, let account = account else { return }
        let snapshot = TSShareState(account: account, socket: socket)
        TSLocalAPI.listProfiles(socketPath: socket) { [weak self] profiles, error in
            Task { @MainActor [weak self] in
                guard let self = self, self.job == job else { return }
                guard error == nil, profiles.contains(where: { snapshot.matches($0) }) else {
                    self.finish(error?.localizedDescription ?? "后台账户已改变，请重新选择账户")
                    return
                }
                do { try action() }
                catch { self.finish(error.localizedDescription) }
            }
        }
    }

    // 持共享账户锁验证后，再直接启动 CLI
    private func spawn(_ arguments: [String]) throws {
        guard let job = job else { return }
        var number: Int32 = 0
        var detail: NSString?
        let result = SpawnRoot.spawnHelperBinary(executable, args: ["--socket=\(socket)"] + arguments, environment: [:], root: false, logPath: job.appendingPathComponent("transfer.log").path, pid: &pid, errNum: &number, errMsg: &detail)
        TSLogs.trace("spawn result=\(result) errno=\(number) pid=\(pid)", in: job)
        guard result == 0 else { throw NSError(domain: "Taildrop", code: Int(number), userInfo: [NSLocalizedDescriptionKey: detail as String? ?? "文件传输启动失败"]) }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    // 只在主执行器轮询或取消，避免两个 waitpid 争抢同一个子进程
    func poll() {
        guard pid > 0 else { return }
        let result = SpawnRoot.pollChild(pid)
        guard result != -EAGAIN else { return }
        pid = 0
        TSLogs.trace("exit code=\(result) operation=\(receiving != nil ? "receive" : "send")", in: job)
        let detail = job.flatMap { try? String(contentsOf: $0.appendingPathComponent("transfer.log"), encoding: .utf8) }
        if result == 0 {
            do {
                // 空收件箱只刷新，发送或实际收件才提示完成。
                let wasReceiving = receiving != nil
                let count = try publish()
                finish(notifySuccess && (!wasReceiving || count > 0) ? "文件传输完成" : nil)
            }
            catch { finish("文件已接收，但整理失败: \(error.localizedDescription)") }
        } else { finish("传输未完成，请重试 (\(result))\n\(detail?.suffix(2000) ?? "")") }
    }

    // 同一磁盘原子移动完整文件，遇到重名不覆盖用户原文件
    private func publish() throws -> Int {
        guard let receiving = receiving, let directory = directory else { return 0 }
        try checkDirectory(directory)
        let files = try FileManager.default.contentsOfDirectory(at: receiving, includingPropertiesForKeys: nil)
        for file in files {
            var candidate = directory.appendingPathComponent(file.lastPathComponent)
            var index = 1
            while true {
                do { try FileManager.default.moveItem(at: file, to: candidate); break }
                catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                    candidate = directory.appendingPathComponent("\(file.deletingPathExtension().lastPathComponent) (\(index))" + (file.pathExtension.isEmpty ? "" : ".\(file.pathExtension)"))
                    index += 1
                }
            }
        }
        try FileManager.default.removeItem(at: receiving)
        self.receiving = nil
        TSLogs.trace("published files=\(files.count)", in: job)
        return files.count
    }

    // 取消仅终止当前传输子进程，不删除用户的源文件或已接收文件
    func cancel() {
        if let upload = upload { cancelling = true; upload.cancel(); return }
        if pid > 0 {
            let result = SpawnRoot.terminateChild(pid)
            guard result == 0 else { message = "取消传输失败 (\(result))"; return }
            pid = 0
        }
        finish(nil)
    }

    // 回收本次临时目录并刷新真实文件列表
    private func finish(_ detail: String?) {
        upload = nil
        cancelling = false
        timer?.invalidate()
        timer = nil
        TSLogs.trace("finish message=\(detail ?? "<none>") previous_message=\(message ?? "<none>")", in: job)
        if let job = job {
            do { try TSLogs.retainTransfer(from: job) }
            catch { NSLog("Unable to retain file transfer diagnostics: %@", error.localizedDescription) }
            do { try FileManager.default.removeItem(at: job) }
            catch { message = "临时文件清理失败: \(error.localizedDescription)" }
        }
        job = nil
        lease?.release()
        lease = nil
        busy = false
        if let detail = detail { message = detail }
        if let receiving = receiving {
            if (try? FileManager.default.contentsOfDirectory(atPath: receiving.path).isEmpty) == true {
                try? FileManager.default.removeItem(at: receiving)
            } else {
                message = (message.map { $0 + "\n" } ?? "") + "未验证完整的文件已保留，请勿视为接收成功:\n\(receiving.path)"
            }
            self.receiving = nil
        }
        reload()
    }

    // 删除前验证仍是本账户目录中的普通文件
    func delete(_ url: URL) {
        guard !busy, let directory = directory else { return }
        do {
            try checkDirectory(directory)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL, values.isRegularFile == true, values.isSymbolicLink != true else { return }
            try FileManager.default.removeItem(at: url)
            message = "文件已删除，无法恢复"
            reload()
        } catch { message = error.localizedDescription }
    }

    deinit { timer?.invalidate(); session.invalidateAndCancel() }
}

// 不允许接收设备将文件上传重定向到其他地址
private final class TSNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
