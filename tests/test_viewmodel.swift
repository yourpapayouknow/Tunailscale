// 以可控 LocalAPI 回包验证真实 ViewModel 的冷启动和生命周期竞争
import Foundation

public final class TSTailscalePeer {
    var name = ""
    var ip = ""
    var online = false
}
final class TSTailscaleProfile {
    var serverUrl = ""
    var nodeID = ""
    var name = ""
    var tailnet = ""
    var profileId = ""
    var isCurrent = false
}
final class TSTailscaleStatus {
    var backendState = "Running"
    var selfIp = "100.83.61.21"
    var authUrl: String?
    var tailnetName: String?
    var loginName: String? = "test-account"
    var selfName: String?
    var peers: [TSTailscalePeer] = []
    var keyExpiry: Date?
    var keyExpired = false
}

// 仅替代宿主 macOS 不具备的 UIKit 生命周期入口
final class UIApplication {
    enum State { case active, background }
    var applicationState = State.active
    static let shared = UIApplication()
    static let willEnterForegroundNotification = Notification.Name("test.foreground")
    static let didEnterBackgroundNotification = Notification.Name("test.background")
    func open(_ url: URL, options: [String: Any] = [:], completionHandler: ((Bool) -> Void)? = nil) {
        completionHandler?(true)
    }
}

// 阻止测试启动特权进程或修改宿主网络
final class SpawnRoot {
    static var spawns: [(args: [String], root: Bool)] = []
    static var spawnResult: Int32 = 0
    static var reaped: [pid_t] = []
    static func terminateDaemonNamed(_ name: String, socketPath: String) -> Int32 { 0 }
    static func chmodPath(_ path: String, mode: mode_t) -> Int32 { 0 }
    static func spawnHelperBinary(_ path: String, args: [String], environment: [String: String], root: Bool, logPath: String, pid: inout pid_t, errNum: inout Int32, errMsg: inout NSString?) -> Int32 {
        spawns.append((args, root))
        if spawnResult != 0 { pid = 0; errNum = spawnResult; errMsg = "test spawn failure"; return spawnResult }
        pid = 100 + pid_t(spawns.count)
        if !root {
            precondition(FileManager.default.createFile(atPath: logPath, contents: Data("FATAL: test diagnostic https://login.tailscale.com/a/private-token\n".utf8)))
        }
        for prefix in ["--socket=", "--state="] {
            if root && prefix == "--state=" { continue }
            if let value = args.first(where: { $0.hasPrefix(prefix) }) {
                let file = String(value.dropFirst(prefix.count))
                if !FileManager.default.fileExists(atPath: file) {
                    precondition(FileManager.default.createFile(atPath: file, contents: Data("test-state".utf8)))
                }
            }
        }
        return 0
    }
    static func terminateChild(_ pid: pid_t) -> Int32 { 0 }
    // 记录已结束后台的回收，不操作宿主进程
    static func pollChild(_ pid: pid_t) -> Int32 { reaped.append(pid); return 0 }
}

// 模拟系统认证窗口的取消与关闭
final class TSAuthPresenter {}
enum ASWebAuthenticationSessionError: Int { case canceledLogin = 1 }
final class ASWebAuthenticationSession {
    static var sessions: [ASWebAuthenticationSession] = []
    static var canStart = true
    var presentationContextProvider: AnyObject?
    var canceled = false
    let completion: (URL?, Error?) -> Void
    init(url: URL, callbackURLScheme: String?, completionHandler: @escaping (URL?, Error?) -> Void) {
        completion = completionHandler
        Self.sessions.append(self)
    }
    func start() -> Bool { Self.canStart }
    func cancel() { canceled = true; completion(nil, NSError(domain: "ASWebAuthenticationSession", code: 1)) }
}

// 手动交付异步响应以重现后台切换和认证 socket 切换的乱序回包
final class TSLocalAPI {
    static var path = defaultSocketPath()
    static var requests: [(TSTailscaleStatus?, Error?) -> Void] = []
    static func defaultSocketPath() -> String { "/tmp/test-viewmodel-tunnel.sock" }
    static func activeSocketPath() -> String { path }
    static func setCustomSocketPath(_ value: String) { path = value }
    static var automaticStatus = false
    static func fetchStatus(_ completion: @escaping (TSTailscaleStatus?, Error?) -> Void) {
        if automaticStatus { completion(TSTailscaleStatus(), nil) }
        else { requests.append(completion) }
    }
    static var profiles: [TSTailscaleProfile] = []
    static var urlRequests: [(String?, Error?) -> Void] = []
    static var draftState = "NeedsLogin"
    static var draftProfiles: [TSTailscaleProfile] = []
    static var deferProfiles = false
    static var profileReplies: [([TSTailscaleProfile], Error?) -> Void] = []
    static var switches: [String] = []
    static var switchResult = true
    static var storageReady = true
    static var storageError: Error?
    static var storageChecks: [String] = []
    static var afterStorageCheck: (() -> Void)?
    // 单独模拟状态正常但 Taildrop 尚未配置的旧后台
    static func checkTaildrop(socketPath: String, completion: @escaping (Bool, Error?) -> Void) {
        storageChecks.append(socketPath)
        completion(storageReady, storageError)
        afterStorageCheck?()
    }
    static func listProfiles() async throws -> [TSTailscaleProfile] { profiles }
    static func fetchStatus(socketPath: String, completion: @escaping (TSTailscaleStatus?, Error?) -> Void) {
        let status = TSTailscaleStatus()
        status.backendState = draftState
        completion(status, nil)
    }
    static func listProfiles(socketPath: String, completion: @escaping ([TSTailscaleProfile], Error?) -> Void) {
        if deferProfiles { profileReplies.append(completion) }
        else { completion(draftProfiles, nil) }
    }
    static func setControlURL(_ url: String, socketPath: String, completion: (Bool, Error?) -> Void) { completion(true, nil) }
    static func requestLoginUrl(socketPath: String, completion: @escaping (String?, Error?) -> Void) { urlRequests.append(completion) }
    static func switchProfile(_ id: String, completion: (Bool, Error?) -> Void) { switches.append(id); completion(switchResult, switchResult ? nil : NSError(domain: "test", code: 500)) }
    static func deleteProfile(_ id: String, completion: (Bool, Error?) -> Void) { completion(true, nil) }
    static func newProfile(_ completion: (Bool, Error?) -> Void) { completion(true, nil) }
    static func setMagicDns(_ enabled: Bool, completion: (Bool, Error?) -> Void) { completion(true, nil) }
    static func setWantRunning(_ enabled: Bool, completion: (Bool, Error?) -> Void) { completion(true, nil) }
    static func login(withAuthKey key: String, completion: (Bool, String) -> Void) { completion(true, "") }
    static func setControlURL(_ url: String, completion: (Bool, Error?) -> Void) { completion(true, nil) }
    static func logout(_ completion: (Bool, Error?) -> Void) { completion(true, nil) }
    static func requestLoginUrl(_ completion: (String?, Error?) -> Void) { completion(nil, nil) }
}

@main
struct ViewModelTests {
    // 等待隔离进程的异步就绪，不启动实际进程
    @MainActor static func waitURL(_ count: Int) async {
        for _ in 0..<200 {
            if TSLocalAPI.urlRequests.count >= count { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        preconditionFailure("Isolated authentication did not become ready")
    }
    // 让 ViewModel 回包任务在主执行器完成
    @MainActor static func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }

    // 覆盖初始化、暂时失败、确认断开、旧响应和模式切换
    @MainActor static func main() async {
        let keys = ["TS_STORED_ACCOUNTS_KEY", "TS_CUSTOM_SERVER_KEY", "TS_MAGIC_DNS_KEY"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        defer {
            for (index, key) in keys.enumerated() {
                if let value = saved[index] { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        let model = TSViewModel()
        assert(model.backendState == "Checking" && TSLocalAPI.requests.count == 1)
        assert(model.connectionTitle == TSLocalization.tr("Checking..."))
        model.pollStatus()
        assert(TSLocalAPI.requests.count == 1, "Overlapping status polls")

        model.startPolling()
        TSLocalAPI.requests[0](TSTailscaleStatus(), nil)
        await settle()
        assert(model.backendState == "Checking", "Old lifecycle response applied")
        TSLocalAPI.requests[1](TSTailscaleStatus(), nil)
        await settle()
        assert(model.isConnected && model.backendState == "Running")
        assert(model.deviceIp == "100.83.61.21")

        model.pollStatus()
        TSLocalAPI.requests.last?(nil, NSError(domain: "TSLocalAPI", code: Int(ETIMEDOUT)))
        await settle()
        assert(model.backendState == "Unavailable" && model.isConnected)
        assert(model.deviceIp == "100.83.61.21" && model.errorMessage != nil)
        assert(model.connectionTitle == TSLocalization.tr("Status Unavailable"))
        model.pollStatus()
        TSLocalAPI.requests.last?(TSTailscaleStatus(), nil)
        await settle()
        assert(model.isConnected && model.errorMessage == nil)

        for code in [ENOENT, ECONNREFUSED] {
            model.pollStatus()
            TSLocalAPI.requests.last?(nil, NSError(domain: "TSLocalAPI", code: Int(code)))
            await settle()
            assert(!model.isConnected && model.backendState == "Stopped")
            assert(model.deviceIp == "--" && model.accountSubtitle == TSLocalization.tr("Not Connected"))
        }
        model.pollStatus()
        TSLocalAPI.requests.last?(nil, nil)
        await settle()
        assert(model.backendState == "Unavailable", "Empty response was treated as stopped")

        model.pollStatus()
        TSLocalAPI.setCustomSocketPath("/var/run/tailscaled-auth.sock")
        TSLocalAPI.requests.last?(TSTailscaleStatus(), nil)
        await settle()
        assert(model.backendState == "Unavailable", "Response from previous socket applied")
        model.pollStatus()
        TSLocalAPI.requests.last?(TSTailscaleStatus(), nil)
        await settle()
        assert(model.isLoggedIn && !model.isConnected, "Auth-only daemon reported as tunnel")

        model.pollStatus()
        let backgroundReply = TSLocalAPI.requests.last!
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        await settle()
        backgroundReply(nil, NSError(domain: "TSLocalAPI", code: Int(ENOENT)))
        await settle()
        assert(model.backendState == "Running", "Background response overwrote state")
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        await settle()
        assert(model.backendState == "Checking", "Foreground did not refresh state")
        let stopped = TSTailscaleStatus()
        stopped.backendState = "Stopped"
        TSLocalAPI.requests.last?(stopped, nil)
        await settle()
        assert(!model.isConnected && model.accountSubtitle == TSLocalization.tr("Not Connected"))

        assert(model.daemonEnvironment == ["TS_FORCE_NOISE_443": "1"])
        model.setCustomServer("http://headscale.example:8080")
        assert(model.daemonEnvironment.isEmpty, "Custom server transport overridden")
        model.killAllDaemons()
        assert(!model.isConnected && model.backendState == "Stopped")

        // 旧 JSON 无独立状态路径时继续使用既有凭据
        let legacy = try! JSONDecoder().decode(TSAccountItem.self, from: Data("{\"name\":\"legacy\",\"tailnet\":\"net\",\"serverUrl\":\"https://controlplane.tailscale.com\",\"isActive\":false,\"profileId\":\"old\"}".utf8))
        assert(legacy.statePath == nil)
        model.setCustomServer("https://controlplane.tailscale.com")
        TSLocalAPI.setCustomSocketPath(TSLocalAPI.defaultSocketPath())
        let primary = TSTailscaleProfile()
        primary.name = "test-account"; primary.profileId = "primary"; primary.isCurrent = true
        let secondary = TSTailscaleProfile()
        secondary.name = "other-account"; secondary.profileId = "secondary"
        TSLocalAPI.profiles = [primary, secondary]
        model.pollStatus()
        TSLocalAPI.requests.last?(TSTailscaleStatus(), nil)
        await settle()
        assert(model.activeAccount?.profileId == "primary" && model.accountTitle == "test-account")
        let originalAccounts = model.accounts
        let originalIP = model.deviceIp
        let originalSocket = TSLocalAPI.activeSocketPath()

        // 被其他认证拦截时必须有账户页错误和日志，不能静默返回
        model.isAuthenticating = true
        model.startAddAccount()
        assert(!model.isAddingAccount && model.additionError != nil && SpawnRoot.spawns.isEmpty)
        assert(model.isConnected && model.accounts == originalAccounts)
        assert(try! String(contentsOf: TSViewModel.additionLogURL, encoding: .utf8).contains("blocked:"))
        model.isAuthenticating = false

        // 用户取消和迟到 URL 不得切走、退出或重连原账户
        model.startAddAccount()
        assert(model.isAddingAccount && model.isConnected && model.isLoggedIn)
        assert(TSLocalAPI.activeSocketPath() == originalSocket)
        assert(SpawnRoot.spawns.count == 1 && !SpawnRoot.spawns[0].root)
        model.startAddAccount()
        assert(SpawnRoot.spawns.count == 1, "Repeated add started multiple sessions")
        await waitURL(1)
        let delayedURL = TSLocalAPI.urlRequests[0]
        model.cancelAddAccount()
        delayedURL("https://login.tailscale.com/a/test", nil)
        await settle()
        assert(!model.isAddingAccount && ASWebAuthenticationSession.sessions.isEmpty)
        assert(model.isConnected && model.isLoggedIn && model.accounts == originalAccounts && model.deviceIp == originalIP)
        let canceledSocket = String(SpawnRoot.spawns[0].args.first { $0.hasPrefix("--socket=") }!.dropFirst(9))
        for _ in 0..<100 {
            if !FileManager.default.fileExists(atPath: canceledSocket) { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        assert(!FileManager.default.fileExists(atPath: canceledSocket), "Canceled socket was not cleaned up")
        let diagnostic = try! String(contentsOf: TSViewModel.additionLogURL, encoding: .utf8)
        assert(diagnostic.contains("FATAL: test diagnostic") && !diagnostic.contains("private-token"))
        let attributes = try! FileManager.default.attributesOfItem(atPath: TSViewModel.additionLogURL.path)
        assert((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        // 系统取消按钮结束新增认证，旧连接的状态保持不变
        model.startAddAccount()
        await waitURL(2)
        TSLocalAPI.urlRequests[1]("https://login.tailscale.com/a/test", nil)
        await settle()
        assert(model.isAddingAccount)
        ASWebAuthenticationSession.sessions.last!.cancel()
        await settle()
        assert(!model.isAddingAccount && model.isConnected && model.backendState == "Running")
        assert(model.accounts == originalAccounts && model.accountTitle == "test-account")

        // 60 秒未完成就自动退出，之后收到 URL 也不会重新打开浏览器
        model.startAddAccount()
        await waitURL(3)
        model.checkAddAccount(now: Date().addingTimeInterval(61))
        TSLocalAPI.urlRequests[2]("https://login.tailscale.com/a/late", nil)
        await settle()
        assert(!model.isAddingAccount && model.isConnected && model.accounts == originalAccounts)
        assert(model.additionError == TSLocalization.tr("Adding account timed out"))

        // 认证成功只保存额外账户，原账户与连接仍保持活动
        let added = TSTailscaleProfile()
        added.name = "new-account"; added.profileId = "new"; added.isCurrent = true
        TSLocalAPI.draftProfiles = [added]
        TSLocalAPI.draftState = "Running"
        model.startAddAccount()
        await waitURL(4)
        TSLocalAPI.urlRequests[3]("https://login.tailscale.com/a/success", nil)
        await settle()
        assert(!model.isAddingAccount && model.accounts.count == originalAccounts.count + 1)
        assert(model.activeAccount?.profileId == "primary" && model.accountTitle == "test-account")
        assert(model.isConnected && model.deviceIp == originalIP && TSLocalAPI.activeSocketPath() == originalSocket)
        let savedAccount = model.accounts.first { $0.name == "new-account" }!
        assert(!savedAccount.isActive && savedAccount.statePath != nil)
        assert(FileManager.default.fileExists(atPath: savedAccount.statePath!))
        assert(SpawnRoot.spawns.allSatisfy { !$0.root }, "Adding an account restarted the root daemon")
        let decoded = try! JSONDecoder().decode([TSAccountItem].self, from: JSONEncoder().encode(model.accounts))
        assert(decoded.first { $0.id == savedAccount.id }?.statePath == savedAccount.statePath)

        // 只有明确选中新账户时才重启主守护进程，并加载该账户自己的凭据
        TSLocalAPI.profiles = [added]
        model.selectAccount(id: savedAccount.id)
        for _ in 0..<200 {
            if TSLocalAPI.switches.last == "new" && model.backendState == "Checking" { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        assert(SpawnRoot.spawns.last!.root)
        assert(SpawnRoot.spawns.last!.args.contains("--state=\(savedAccount.statePath!)"))
        assert(SpawnRoot.spawns.last!.args.contains("--tun=utun"))
        assert(TSLocalAPI.switches.last == "new")
        let newStatus = TSTailscaleStatus()
        newStatus.loginName = "new-account"
        TSLocalAPI.requests.last?(newStatus, nil)
        await settle()
        assert(model.isConnected && model.activeAccount?.id == savedAccount.id)

        // 切回原账户，再删除未使用的独立凭据，不能重启原连接
        TSLocalAPI.profiles = [primary, secondary]
        model.selectAccount(id: originalAccounts.first { $0.isActive }!.id)
        for _ in 0..<200 {
            if TSLocalAPI.switches.last == "primary" && model.backendState == "Checking" { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        assert(SpawnRoot.spawns.last!.args.contains("--state=/var/root/tunailscale.state"))
        TSLocalAPI.requests.last?(TSTailscaleStatus(), nil)
        await settle()
        let spawnCount = SpawnRoot.spawns.count
        model.removeAccount(id: savedAccount.id)
        assert(model.isConnected && model.accounts == originalAccounts && SpawnRoot.spawns.count == spawnCount)
        assert(!FileManager.default.fileExists(atPath: savedAccount.statePath!))

        // 超时后迟到的有效凭据也不能提交到账户列表
        TSLocalAPI.deferProfiles = true
        model.startAddAccount()
        await waitURL(5)
        TSLocalAPI.urlRequests[4]("https://login.tailscale.com/a/late-credentials", nil)
        await settle()
        assert(model.isAddingAccount && !TSLocalAPI.profileReplies.isEmpty)
        model.checkAddAccount(now: Date().addingTimeInterval(61))
        TSLocalAPI.profileReplies.last?([added], nil)
        await settle()
        assert(!model.isAddingAccount && model.isConnected && model.accounts == originalAccounts)
        TSLocalAPI.deferProfiles = false

        // 持久化路径异常时拒绝删除目录，不触碰原账户
        let unsafe = TSAccountItem(name: "unsafe", statePath: "/tmp/not-managed/tailscaled.state")
        model.accounts.append(unsafe)
        model.removeAccount(id: unsafe.id)
        assert(model.accounts.contains(where: { $0.id == unsafe.id }) && model.isConnected)
        model.accounts.removeAll { $0.id == unsafe.id }

        // 启动或浏览器失败也必须退出新增状态，不能污染现有连接
        SpawnRoot.spawnResult = Int32(ENOENT)
        model.startAddAccount()
        assert(!model.isAddingAccount && model.isConnected && model.accounts == originalAccounts)
        assert(model.additionError?.contains("errno \(ENOENT)") == true)
        assert(try! String(contentsOf: TSViewModel.additionLogURL, encoding: .utf8).contains("spawn result="))
        model.pollStatus()
        TSLocalAPI.requests.last?(TSTailscaleStatus(), nil)
        await settle()
        assert(model.additionError != nil, "Main status polling hid the addition error")
        SpawnRoot.spawnResult = 0
        ASWebAuthenticationSession.canStart = false
        model.startAddAccount()
        await waitURL(6)
        TSLocalAPI.urlRequests[5]("https://login.tailscale.com/a/not-presented", nil)
        await settle()
        assert(!model.isAddingAccount && model.isConnected && model.accounts == originalAccounts)
        ASWebAuthenticationSession.canStart = true
        model.additionError = nil

        // 同名账户的原生 ProfileID 不得被按邮箱合并
        let sameName = TSTailscaleProfile()
        sameName.name = primary.name; sameName.profileId = "same-name-other-profile"
        TSLocalAPI.profiles = [primary, secondary, sameName]
        model.pollStatus(); TSLocalAPI.requests.last?(TSTailscaleStatus(), nil); await settle()
        assert(model.accounts.filter { $0.name == primary.name }.count == 2)
        model.accounts.removeAll { $0.profileId == sameName.profileId }
        TSLocalAPI.profiles = [primary, secondary]

        // 原生切换失败必须重启回原凭据，不提交错误账户
        let beforeSwitch = SpawnRoot.spawns.count
        TSLocalAPI.switchResult = false
        model.selectAccount(id: originalAccounts.first { !$0.isActive }!.id)
        for _ in 0..<200 {
            if !model.isAuthenticating { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        assert(!model.isAuthenticating && model.activeAccount?.profileId == "primary")
        assert(SpawnRoot.spawns.count == beforeSwitch + 2, "Failed switch did not restore original daemon")
        assert(SpawnRoot.spawns.last!.args.contains("--state=/var/root/tunailscale.state"))
        assert(SpawnRoot.spawns.last!.args.contains("--statedir=/var/root/Tunailscale"))
        TSLocalAPI.switchResult = true
        TSLocalAPI.requests.last?(TSTailscaleStatus(), nil); await settle()

        // 非活动账户过期只记录，当前节点过期才在前台请求一次认证
        let inactive = model.accounts.firstIndex { !$0.isActive }!
        model.accounts[inactive].keyExpiry = Date().addingTimeInterval(-60)
        let healthy = TSTailscaleStatus()
        healthy.keyExpiry = Date().addingTimeInterval(3600)
        let urlCount = TSLocalAPI.urlRequests.count
        model.pollStatus(); TSLocalAPI.requests.last?(healthy, nil); await settle()
        assert(TSLocalAPI.urlRequests.count == urlCount && !model.isAuthenticating)
        assert(model.activeAccount?.keyExpiry == healthy.keyExpiry)
        let expired = TSTailscaleStatus()
        expired.keyExpired = true; expired.keyExpiry = Date().addingTimeInterval(-30)
        UIApplication.shared.applicationState = .background
        model.pollStatus(); TSLocalAPI.requests.last?(expired, nil); await settle()
        assert(TSLocalAPI.urlRequests.count == urlCount && !model.isConnected)
        UIApplication.shared.applicationState = .active
        model.pollStatus(); TSLocalAPI.requests.last?(expired, nil); await settle()
        assert(model.isAuthenticating && TSLocalAPI.urlRequests.count == urlCount + 1)
        TSLocalAPI.urlRequests.last?("https://login.tailscale.com/a/renew", nil); await settle()
        ASWebAuthenticationSession.sessions.last!.cancel(); await settle()
        assert(!model.isAuthenticating && model.accounts.count == 2)
        model.pollStatus(); TSLocalAPI.requests.last?(expired, nil); await settle()
        assert(TSLocalAPI.urlRequests.count == urlCount + 1, "Canceled expiry login reopened automatically")

        // 手动重试超时后忽略迟到链接；恢复健康状态后清除过期标记
        model.launchBrowserAuth()
        assert(model.isAuthenticating)
        let sessionCount = ASWebAuthenticationSession.sessions.count
        model.checkRenewal(now: Date().addingTimeInterval(61))
        TSLocalAPI.urlRequests.last?("https://login.tailscale.com/a/too-late", nil); await settle()
        assert(!model.isAuthenticating && ASWebAuthenticationSession.sessions.count == sessionCount)
        model.pollStatus(); TSLocalAPI.requests.last?(healthy, nil); await settle()
        assert(model.activeAccount?.nodeKeyExpired == false && model.isConnected)
        let noExpiry = TSTailscaleStatus()
        model.pollStatus(); TSLocalAPI.requests.last?(noExpiry, nil); await settle()
        assert(model.activeAccount?.keyExpiry == nil, "Disabled node expiry retained stale expiry date")

        // Running 但收件存储缺失时，文件入口必须迁移原后台并验证真实存储
        TSLocalAPI.draftState = "Running"
        TSLocalAPI.automaticStatus = true
        TSLocalAPI.storageReady = false
        let beforeStorage = SpawnRoot.spawns.count
        let previousDaemon = model.daemonPid
        assert(previousDaemon > 1)
        TSLocalAPI.afterStorageCheck = { TSLocalAPI.storageReady = true }
        var fileReady = false
        model.prepareFileTransfer { error in assert(error == nil); fileReady = true }
        for _ in 0..<200 {
            if fileReady { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        assert(fileReady && SpawnRoot.spawns.count == beforeStorage + 1)
        assert(SpawnRoot.reaped.last == previousDaemon, "Mode restart did not reap its exited child")
        assert(SpawnRoot.spawns.last!.args.contains("--state=/var/root/tunailscale.state"))
        assert(SpawnRoot.spawns.last!.args.contains("--statedir=/var/root/Tunailscale"))
        assert(model.activeAccount?.profileId == "primary", "Storage migration changed the account")
        assert(TSLocalAPI.storageChecks.allSatisfy { $0 == TSLocalAPI.defaultSocketPath() })
        TSLocalAPI.afterStorageCheck = nil

        // 健康后台不重启，权限错误不误当作缺目录重启
        for denied in [false, true] {
            TSLocalAPI.storageReady = !denied
            TSLocalAPI.storageError = denied ? NSError(domain: "TSLocalAPI", code: 403) : nil
            let count = SpawnRoot.spawns.count
            var finished = false
            model.prepareFileTransfer { error in
                assert((error != nil) == denied)
                finished = true
            }
            await settle()
            assert(finished && SpawnRoot.spawns.count == count && !model.isAuthenticating)
        }
        TSLocalAPI.storageError = nil

        // 新后台持续不可用也只重启一次，超时不能假报成功
        let beforeTimeout = SpawnRoot.spawns.count
        var timedOut = false
        model.prepareFileTransfer { error in
            assert((error as NSError?)?.code == Int(ETIMEDOUT))
            timedOut = true
        }
        for _ in 0..<800 {
            if timedOut { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        assert(timedOut && SpawnRoot.spawns.count == beforeTimeout + 1 && !model.isAuthenticating)
        TSLocalAPI.storageReady = true
        model.stopPolling()
        // 快速连点只能提交一次操作，拒绝在断开未完成时并发连接
        TSLocalAPI.automaticStatus = false
        model.isLoggedIn = true
        model.isConnected = true
        let beforeTaps = TSLocalAPI.requests.count
        model.toggleConnection()
        model.toggleConnection()
        assert(TSLocalAPI.requests.count == beforeTaps + 1 && model.isAuthenticating, "Repeated taps submitted conflicting connection operations")
        SpawnRoot.spawnResult = EIO
        TSLocalAPI.requests.last?(nil, NSError(domain: "TSLocalAPI", code: Int(EIO)))
        await settle()
        assert(!model.isAuthenticating, "Failed connection operation left controls blocked")
        SpawnRoot.spawnResult = 0
        model.stopPolling()
        try? FileManager.default.removeItem(atPath: TSLocalAPI.defaultSocketPath())
        // 停止服务也必须回收跟踪中的自有后台
        model.daemonPid = 555
        model.killAllDaemons()
        assert(SpawnRoot.reaped.last == 555 && model.daemonPid == 0)
        // 完整列表不截断，在线优先，名称或地址相同时保持稳定顺序
        let devices = (0..<12).map { index in
            let peer = TSTailscalePeer()
            peer.name = String(format: "Device%02d", index)
            peer.ip = "100.64.1.\(index + 1)"
            peer.online = index % 2 == 0
            return peer
        }
        model.peers = Array(devices.reversed())
        let expected = devices.filter { $0.online } + devices.filter { !$0.online }
        assert(model.orderedPeers.map(\.ip) == expected.map(\.ip))
        assert(model.peers.map(\.ip) == devices.reversed().map(\.ip), "Presentation sorting mutated source peers")
        devices[0].name = devices[2].name
        assert(model.orderedPeers.first?.ip == devices[0].ip)
        for online in [true, false] {
            devices.forEach { $0.online = online }
            assert(model.orderedPeers.count == devices.count)
        }
        model.peers = []
        assert(model.orderedPeers.isEmpty)
        print("PASS: complete peer list, online-first stable ordering, ties, all-online, all-offline and empty states")
        print("PASS: ViewModel cold start, transient errors, stale responses, mode changes, transport scope")
        print("PASS: isolated account addition, no connection changes, cancellation, deadline, late URL, inactive credential persistence, visible failures and retained redacted diagnostics")
        print("PASS: native account identity, failed-switch credential rollback, node expiry, active-only foreground reauthentication, cancellation suppression, deadline and disabled expiry")
        print("PASS: Running without Taildrop storage, same-account migration, pinned readiness, healthy reuse, permission errors and bounded restart")
    }
}
