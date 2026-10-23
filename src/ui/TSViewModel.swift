//
//  TSViewModel.swift
//  TSNativeTailscale UI
//
//  主界面与多账户状态管理 ViewModel (纯Swift)
//  真实零假数据状态管理：真实检测登录、自动同步账户、无预埋假数据
//

import SwiftUI
import Combine
#if canImport(UIKit)
import AuthenticationServices

// 为系统认证会话提供当前窗口
private final class TSAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }
        return windows.first(where: { $0.isKeyWindow }) ?? windows.first ?? ASPresentationAnchor()
    }
}
#endif

/* 区分无 TUN 认证进程与原生 utun 建网进程 */
private enum TSDaemonMode {
    case auth
    case tunnel

    var tunName: String {
        self == .auth ? "userspace-networking" : "utun"
    }

    var socketPath: String {
        self == .auth ? "/var/run/tunailscale-auth.sock" : TSLocalAPI.defaultSocketPath()
    }
}

// 新增账户拥有独立凭据和短 socket 路径
private struct TSAccountDraft {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tunailscale/Accounts")
    }
    let id = UUID()
    let directory: URL
    let socketDirectory: URL
    let deadline = Date().addingTimeInterval(60)
    var pid: pid_t = 0
    var statePath: String { directory.appendingPathComponent("tailscaled.state").path }
    var socketPath: String { socketDirectory.appendingPathComponent("ts.sock").path }

    // 只接受本 App 私有根目录内的原生 UUID 凭据路径
    static func managedDirectory(_ path: String) -> URL? {
        let state = URL(fileURLWithPath: path)
        let directory = state.deletingLastPathComponent()
        let resolved = directory.resolvingSymlinksInPath()
        guard state.lastPathComponent == "tailscaled.state", UUID(uuidString: directory.lastPathComponent) != nil,
              resolved.deletingLastPathComponent() == root.resolvingSymlinksInPath(),
              resolved.lastPathComponent == directory.lastPathComponent,
              state.resolvingSymlinksInPath() == resolved.appendingPathComponent("tailscaled.state") else { return nil }
        return directory
    }

    // 创建仅供本次新增认证使用的目录
    init() throws {
        directory = Self.root.appendingPathComponent(id.uuidString)
        socketDirectory = URL(fileURLWithPath: "/tmp/tsadd-\(id.uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            try FileManager.default.createDirectory(at: socketDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}

@MainActor
public final class TSViewModel: ObservableObject {
    @Published public var isConnected: Bool = false
    @Published public var isLoggedIn: Bool = false
    @Published public var backendState: String = "Checking" // Running, NeedsLogin, Stopped, Unavailable
    @Published public var accountTitle: String = "Not Connected"
    @Published public var accountSubtitle: String = "Not Connected"
    @Published public var deviceIp: String = "--"
    @Published public var peers: [TSTailscalePeer] = []
    @Published public var daemonPid: pid_t = 0
    @Published public var latestAuthUrl: String = ""
    @Published public var isAuthenticating: Bool = false
    @Published public var errorMessage: String? = nil
    @Published public var additionError: String? = nil
    static let additionLogURL = TSLogs.additionURL

    // 多账户列表与当前配置 (初始为空，不预埋任何假账号)
    @Published public var accounts: [TSAccountItem] = []
    @Published public var customCoordinationServer: String = ""
    @Published public var enableMagicDns: Bool = true

    private var pollTimer: Timer?
    private var pendingPoll: UUID?
    private var pollGeneration = 0
    @Published private var addition: TSAccountDraft?
    private var additionTimer: Timer?
    private var additionBrowser: ASWebAuthenticationSession?
    private let additionPresenter = TSAuthPresenter()
    private var additionReady = false
    private var additionPending = false
    private var additionTrace = ""
    private var expiryAttempts = Set<String>()
    private var renewal: (id: UUID, accountID: String, socket: String, deadline: Date)?
    private var renewalBrowser: ASWebAuthenticationSession?
    private var renewalTimer: Timer?
    private var renewalLease: TSAccountLease?
    private var sharedSocketPath: String?
    public var isAddingAccount: Bool { addition != nil }
    private let accountsStorageKey = "TS_STORED_ACCOUNTS_KEY"
    private let serverStorageKey = "TS_CUSTOM_SERVER_KEY"
    private let magicDnsStorageKey = "TS_MAGIC_DNS_KEY"

    public init() {
        let sockPath = TSLocalAPI.defaultSocketPath()
        TSLocalAPI.setCustomSocketPath(sockPath)
        loadStoredSettings()
        setupLifecycleObservers()
        startPolling()
    }

    // 未取得实时状态时不显示已断开
    public var connectionTitle: String {
        if backendState == "Checking" { return TSLocalization.tr("Checking...") }
        if backendState == "Unavailable" { return TSLocalization.tr("Status Unavailable") }
        if backendState == "Starting" { return TSLocalization.tr("Connecting...") }
        return TSLocalization.tr(isConnected ? "Connected" : "Not Connected")
    }

    // 官方协调服务跳过当前网络反复重置的 HTTP 升级路径
    var daemonEnvironment: [String: String] {
        daemonEnvironment(for: customCoordinationServer)
    }

    // 为所选账户的协调服务器使用同一环境规则
    private func daemonEnvironment(for server: String) -> [String: String] {
        URL(string: server)?.host == "controlplane.tailscale.com"
            ? ["TS_FORCE_NOISE_443": "1"] : [:]
    }

    private func setupLifecycleObservers() {
        // 回到前台：恢复轮询并刷新状态
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.startPolling()
            }
        }
        // 切入后台或锁屏：立即彻底暂停轮询定时器，杜绝 CPU 唤醒与电量损耗
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stopPolling()
            }
        }
    }

    public func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        pollGeneration += 1
        pendingPoll = nil
    }

    // 读取持久化账户与服务器设置
    private func loadStoredSettings() {
        if let data = UserDefaults.standard.data(forKey: accountsStorageKey),
           let savedAccounts = try? JSONDecoder().decode([TSAccountItem].self, from: data) {
            self.accounts = savedAccounts
        } else {
            // 真实未登录状态，初始为空！
            self.accounts = []
        }

        self.customCoordinationServer = UserDefaults.standard.string(forKey: serverStorageKey) ?? "https://controlplane.tailscale.com"
        if UserDefaults.standard.object(forKey: magicDnsStorageKey) != nil {
            self.enableMagicDns = UserDefaults.standard.bool(forKey: magicDnsStorageKey)
        } else {
            self.enableMagicDns = true
        }
        updateAccountHeaderForInitialState()
    }

    private func updateAccountHeaderForInitialState() {
        if let active = activeAccount {
            self.isLoggedIn = true
            self.accountTitle = active.name
            self.accountSubtitle = isConnected ? TSLocalization.tr("Connected") : TSLocalization.tr("Not Connected")
        } else {
            self.isLoggedIn = false
            self.accountTitle = TSLocalization.tr("Not Connected")
            self.accountSubtitle = TSLocalization.tr("Not Connected")
        }
    }

    public func saveAccounts() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: accountsStorageKey)
        }
        do {
            let socket = TSLocalAPI.activeSocketPath()
            try TSShareState.save(account: activeAccount, socket: socket)
            sharedSocketPath = socket
        }
        catch { errorMessage = error.localizedDescription }
    }

    public var activeAccount: TSAccountItem? {
        accounts.first { $0.isActive }
    }

    // 首页完整展示设备，在线优先且同状态按名称与地址稳定排序
    var orderedPeers: [TSTailscalePeer] {
        peers.sorted {
            if $0.online != $1.online { return $0.online }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.ip < $1.ip : order == .orderedAscending
        }
    }

    public func selectAccount(id: String) {
        guard !isAddingAccount, !isAuthenticating else { return }
        guard let target = accounts.first(where: { $0.id == id }), activeAccount?.id != id else { return }
        if let path = target.statePath, TSAccountDraft.managedDirectory(path) == nil {
            errorMessage = "拒绝加载账户目录之外的凭据"
            return
        }
        let lease: TSAccountLease?
        do { lease = try TSAccountLease.acquire(exclusive: true) }
        catch { errorMessage = error.localizedDescription; return }
        let wasConnected = isConnected
        let previous = activeAccount
        self.isConnected = false
        self.deviceIp = "--"

        // 如果该账户具有原生 ProfileID，直接通过 LocalAPI 进行原生无缝切换
        if !target.profileId.isEmpty {
            isAuthenticating = true
            stopPolling()
            // 失败时重新加载原凭据，不让下一轮状态把目标误记为原账户
            let rollback: (Error) -> Void = { [weak self] failure in
                guard let self = self else { lease?.release(); return }
                self.startDaemon(mode: wasConnected ? .tunnel : .auth, account: previous, lease: lease) { [weak self] restoreError in
                    lease?.release()
                    guard let self = self else { return }
                    self.isAuthenticating = false
                    self.errorMessage = failure.localizedDescription + (restoreError.map { "\n恢复原账户失败: \($0.localizedDescription)" } ?? "")
                    if restoreError == nil { self.startPolling() }
                }
            }
            // 独立状态文件仅在用户明确切换账户时加载
            startDaemon(mode: wasConnected ? .tunnel : .auth, account: target, lease: lease) { [weak self] error in
                guard let self = self else { return }
                if let error = error {
                    rollback(error)
                    return
                }
                TSLocalAPI.switchProfile(target.profileId) { [weak self] success, error in
                    Task { @MainActor [weak self] in
                        guard let self = self else { lease?.release(); return }
                        if success {
                            lease?.release()
                            // 只有后台确认切换成功才提交活动账户与共享快照
                            for index in self.accounts.indices { self.accounts[index].isActive = self.accounts[index].id == id }
                            self.setCustomServer(target.serverUrl)
                            self.accountTitle = target.name
                            self.isLoggedIn = true
                            self.saveAccounts()
                            self.isAuthenticating = false
                            self.startPolling()
                        } else {
                            rollback(error ?? TSShareState.failure("账户切换失败"))
                        }
                    }
                }
            }
        } else {
            // 旧记录没有 ProfileID 时重新走官方交互登录，不猜测 CLI 名称
            lease?.release()
            launchBrowserAuth()
        }
    }

    public func removeAccount(id: String) {
        guard !isAddingAccount, !isAuthenticating, let target = accounts.first(where: { $0.id == id }) else { return }
        let lease: TSAccountLease?
        do { lease = try TSAccountLease.acquire(exclusive: true) }
        catch { errorMessage = error.localizedDescription; return }
        // 未使用的独立凭据只从本 App 管理的 UUID 目录中移除
        if !target.isActive, let path = target.statePath {
            guard let directory = TSAccountDraft.managedDirectory(path) else {
                errorMessage = "拒绝删除账户目录之外的凭据"
                return
            }
            do {
                try FileManager.default.removeItem(at: directory)
                accounts.removeAll { $0.id == id }
                saveAccounts()
            } catch { errorMessage = error.localizedDescription }
            return
        }
        if accounts.count == 1 {
            lease?.release()
            performFullLogout()
            return
        }

        let finishRemoval = { [weak self] in
            guard let self = self else { return }
            self.accounts.removeAll { $0.id == id }
            self.saveAccounts()
            lease?.release()
            if target.isActive, let first = self.accounts.first {
                self.selectAccount(id: first.id)
            } else { self.startPolling() }
        }
        guard !target.profileId.isEmpty else {
            finishRemoval()
            return
        }

        stopPolling()
        ensureDaemonRunning(mode: isConnected ? .tunnel : .auth, lease: lease) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                lease?.release()
                self.errorMessage = error.localizedDescription
                self.startPolling()
                return
            }
            TSLocalAPI.deleteProfile(target.profileId) { [weak self] success, error in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    if success {
                        finishRemoval()
                    } else {
                        lease?.release()
                        self.errorMessage = error?.localizedDescription ?? "账户删除失败"
                        self.startPolling()
                    }
                }
            }
        }
    }

    // 独立启动新增认证，并记录入口和失败阶段
    public func startAddAccount() {
        guard !isAddingAccount else { return }
        additionTrace = ""
        additionError = nil
        recordAddition("begin uid=\(getuid()) euid=\(geteuid()) authenticating=\(isAuthenticating)")
        guard !isAuthenticating else {
            additionError = "已有认证正在进行，请稍后再试"
            recordAddition("blocked: another authentication is in progress")
            return
        }
        do {
            var draft = try TSAccountDraft()
            recordAddition("directories ready: \(draft.socketPath)")
            addition = draft
            additionReady = false
            additionPending = false
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.checkAddAccount() }
            }
            additionTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            let path = Bundle.main.path(forResource: "tailscaled", ofType: nil)
                ?? (Bundle.main.bundlePath as NSString).appendingPathComponent("tailscaled")
            var spawnError: Int32 = 0
            var message: NSString?
            let result = SpawnRoot.spawnHelperBinary(path, args: ["--tun=userspace-networking", "--port=0", "--socket=\(draft.socketPath)", "--state=\(draft.statePath)", "--statedir=\(draft.directory.appendingPathComponent("daemon").path)", "--no-logs-no-support"], environment: daemonEnvironment, root: false, logPath: draft.socketDirectory.appendingPathComponent("tailscaled.log").path, pid: &draft.pid, errNum: &spawnError, errMsg: &message)
            addition = draft
            recordAddition("spawn result=\(result) errno=\(spawnError) pid=\(draft.pid)")
            guard result == 0 else {
                finishAddition(message: "新增认证进程启动失败 (errno \(spawnError)): \(message as String? ?? "未知错误")")
                return
            }
            waitForSocketReady(socketPath: draft.socketPath) { [weak self] error in
                guard let self = self, self.additionActive(draft.id) else { return }
                if let error = error { self.finishAddition(message: "新增认证进程未就绪: \(error.localizedDescription)"); return }
                self.recordAddition("LocalAPI ready; configuring control server")
                TSLocalAPI.setControlURL(self.customCoordinationServer, socketPath: draft.socketPath) { [weak self] success, error in
                    Task { @MainActor [weak self] in
                        guard let self = self, self.additionActive(draft.id) else { return }
                        guard success else { self.finishAddition(message: error?.localizedDescription ?? "设置新增账户服务器失败"); return }
                        self.recordAddition("requesting authorization URL")
                        TSLocalAPI.requestLoginUrl(socketPath: draft.socketPath) { [weak self] value, error in
                            Task { @MainActor [weak self] in
                                guard let self = self, self.additionActive(draft.id) else { return }
                                guard let value = value, let url = URL(string: value), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else {
                                    self.finishAddition(message: "新增账户授权失败: \(error?.localizedDescription ?? "未获取到授权 URL")")
                                    return
                                }
                                self.showAddition(url, id: draft.id)
                            }
                        }
                    }
                }
            }
        } catch {
            let failure = error as NSError
            let message = "创建新增账户目录失败: \(failure.localizedDescription) (\(failure.domain) \(failure.code))"
            additionError = message
            recordAddition(message)
        }
    }

    // 仅保留最近一次新增诊断，隐藏临时授权链接，不改写主守护进程日志
    private func recordAddition(_ event: String) {
        let safe = TSLogs.redacted(event)
        additionTrace += "\(Date()) [AddAccount] \(safe)\n"
        if !FileManager.default.createFile(atPath: Self.additionLogURL.path, contents: Data(additionTrace.utf8), attributes: [.posixPermissions: 0o600]) {
            NSLog("Unable to save additional account diagnostics")
        }
    }

    // 取消仅清理新增会话，不修改当前账户与连接
    public func cancelAddAccount() { finishAddition() }

    // 拒绝取消、超时或上一轮认证的迟到回包
    private func additionActive(_ id: UUID) -> Bool {
        guard let draft = addition, draft.id == id else { return false }
        guard Date() < draft.deadline else {
            finishAddition(message: TSLocalization.tr("Adding account timed out"))
            return false
        }
        return true
    }

    // 系统浏览器提供明确的取消回调，成功以本地有效 Profile 为准
    private func showAddition(_ url: URL, id: UUID) {
        recordAddition("authorization URL received; opening authentication window")
        let browser = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { [weak self] _, error in
            Task { @MainActor [weak self] in
                guard let self = self, self.additionActive(id) else { return }
                self.finishAddition(message: (error as NSError?)?.code == ASWebAuthenticationSessionError.canceledLogin.rawValue ? nil : error?.localizedDescription)
            }
        }
        browser.presentationContextProvider = additionPresenter
        additionBrowser = browser
        guard browser.start() else { finishAddition(message: "无法打开新增账户认证窗口"); return }
        additionReady = true
        recordAddition("authentication window started; waiting for credentials")
        checkAddAccount()
    }

    // 检查新增会话的截止时间及凭据，不把临时状态发布到主页
    func checkAddAccount(now: Date = Date()) {
        guard let draft = addition else { return }
        guard now < draft.deadline else { finishAddition(message: TSLocalization.tr("Adding account timed out")); return }
        guard additionReady, !additionPending else { return }
        additionPending = true
        TSLocalAPI.fetchStatus(socketPath: draft.socketPath) { [weak self] status, error in
            Task { @MainActor [weak self] in
                guard let self = self, self.additionActive(draft.id) else { return }
                guard error == nil, status?.backendState == "Running" else { self.additionPending = false; return }
                TSLocalAPI.listProfiles(socketPath: draft.socketPath) { [weak self] profiles, error in
                    Task { @MainActor [weak self] in
                        guard let self = self, self.additionActive(draft.id) else { return }
                        self.additionPending = false
                        guard error == nil, let profile = profiles.first(where: { $0.isCurrent && !$0.profileId.isEmpty && !$0.name.isEmpty }) else { return }
                        if self.accounts.contains(where: { $0.name == profile.name && $0.serverUrl == self.customCoordinationServer && $0.tailnet == profile.tailnet }) {
                            self.finishAddition(message: TSLocalization.tr("Account already added"))
                            return
                        }
                        self.accounts.append(TSAccountItem(name: profile.name, tailnet: profile.tailnet, serverUrl: profile.serverUrl.isEmpty ? self.customCoordinationServer : profile.serverUrl, profileId: profile.profileId, statePath: draft.statePath, keyExpiry: status?.keyExpiry, nodeKeyExpired: status?.keyExpired, nodeID: profile.nodeID))
                        self.saveAccounts()
                        self.finishAddition(keepState: true)
                    }
                }
            }
        }
    }

    // 回收自有子进程后再删除临时文件；成功账户保留独立凭据
    private func finishAddition(keepState: Bool = false, message: String? = nil) {
        guard let draft = addition else { return }
        recordAddition("finish: \(message ?? (keepState ? "credentials saved" : "canceled"))")
        if let log = try? String(contentsOf: draft.socketDirectory.appendingPathComponent("tailscaled.log"), encoding: .utf8) {
            recordAddition("isolated daemon log:\n\(log)")
        }
        addition = nil
        additionTimer?.invalidate()
        additionTimer = nil
        additionReady = false
        additionPending = false
        let browser = additionBrowser
        additionBrowser = nil
        browser?.cancel()
        if let message = message { additionError = message }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = draft.pid > 0 ? SpawnRoot.terminateChild(draft.pid) : 0
            guard result == 0 else {
                Task { @MainActor [weak self] in self?.additionError = "清理新增认证进程失败 (errno \(result))" }
                return
            }
            do {
                try FileManager.default.removeItem(at: draft.socketDirectory)
                if !keepState { try FileManager.default.removeItem(at: draft.directory) }
            } catch {
                Task { @MainActor [weak self] in self?.additionError = "清理新增认证文件失败: \(error.localizedDescription)" }
            }
        }
    }

    public func setCustomServer(_ urlStr: String) {
        self.customCoordinationServer = urlStr
        UserDefaults.standard.set(urlStr, forKey: serverStorageKey)
    }

    // 控制台跳转 (原版 View admin console...)
    public func openAdminConsole() {
        let targetUrlStr: String
        if !customCoordinationServer.isEmpty && customCoordinationServer != "https://controlplane.tailscale.com" {
            targetUrlStr = customCoordinationServer
        } else {
            targetUrlStr = "https://login.tailscale.com/admin"
        }

        if let url = URL(string: targetUrlStr) {
            UIApplication.shared.open(url)
        }
    }

    public func startPolling() {
        stopPolling()
        backendState = "Checking"
        accountSubtitle = TSLocalization.tr("Checking...")
        pollStatus()
        let timer = Timer(timeInterval: 3.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollStatus()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.pollTimer = timer
    }

    // 停止本App后台并释放原生隧道
    public func killAllDaemons() {
        cancelAddAccount()
        endRenewal()
        stopPolling()
        let authResult = SpawnRoot.terminateDaemonNamed("tailscaled", socketPath: TSDaemonMode.auth.socketPath)
        let tunnelResult = SpawnRoot.terminateDaemonNamed("tailscaled", socketPath: TSDaemonMode.tunnel.socketPath)
        // 回收本 App 已结束的子进程，不等待或终止其他进程
        if daemonPid > 1, SpawnRoot.pollChild(daemonPid) != -EAGAIN { daemonPid = 0 }
        if authResult != 0 || tunnelResult != 0 {
            self.errorMessage = "停止 tailscaled 失败 (auth=\(authResult), tunnel=\(tunnelResult))"
        }
        TSLocalAPI.setCustomSocketPath(TSDaemonMode.tunnel.socketPath)
        self.isConnected = false
        self.backendState = "Stopped"
        self.accountSubtitle = TSLocalization.tr("Not Connected")
        self.deviceIp = "--"
        self.peers = []
    }

    public func pollStatus() {
        // 同一轮仅发出一个请求，模式切换后忽略旧 socket 的回包
        guard pendingPoll == nil else { return }
        let request = UUID()
        let generation = pollGeneration
        let socketPath = TSLocalAPI.activeSocketPath()
        pendingPoll = request
        TSLocalAPI.fetchStatus { [weak self] status, error in
            Task { @MainActor [weak self] in
                guard let self = self, self.pendingPoll == request else { return }
                self.pendingPoll = nil
                guard TSLocalAPI.activeSocketPath() == socketPath else { return }
                guard error == nil, let status = status else {
                    // socket 确认不存在/无监听者才判为断开，超时等错误保留未知状态
                    let socketError = error as NSError?
                    let stopped = socketError?.domain == "TSLocalAPI"
                        && [Int(ENOENT), Int(ECONNREFUSED)].contains(socketError?.code ?? 0)
                    self.backendState = stopped ? "Stopped" : "Unavailable"
                    if !stopped, let err = error {
                        self.errorMessage = "Socket: \(err.localizedDescription)"
                    } else if self.errorMessage?.hasPrefix("Socket: ") == true {
                        self.errorMessage = nil
                    }
                    if stopped {
                        self.isConnected = false
                        self.deviceIp = "--"
                        self.peers = []
                    }
                    self.accountSubtitle = self.connectionTitle
                    return
                }

                if self.errorMessage?.hasPrefix("Socket: ") == true { self.errorMessage = nil }
                self.latestAuthUrl = status.authUrl ?? ""
                self.backendState = status.backendState
                let tunnelActive = socketPath == TSDaemonMode.tunnel.socketPath

                if status.backendState == "Running" {
                    self.isConnected = tunnelActive
                    self.isLoggedIn = true
                    let ip = status.selfIp
                    self.deviceIp = tunnelActive ? ip : "--"

                    // 如果检测到了实际登录的真实账户名 (如真实的邮箱或登录名)，自动记录同步
                    if let realName = status.loginName, !realName.isEmpty {
                        self.accountTitle = realName
                    } else if let hostName = status.selfName, !hostName.isEmpty {
                        self.accountTitle = hostName
                    } else if let active = self.activeAccount {
                        self.accountTitle = active.name
                    } else {
                        self.accountTitle = ip
                    }
                    self.accountSubtitle = TSLocalization.tr(tunnelActive ? "Connected" : "Not Connected")
                } else if status.backendState == "NeedsLogin" {
                    self.isConnected = false
                    self.isLoggedIn = false
                    self.accountTitle = TSLocalization.tr("Not Connected")
                    self.accountSubtitle = TSLocalization.tr("Needs Login")
                    self.deviceIp = "--"
                } else {
                    self.isConnected = false
                    self.accountTitle = TSLocalization.tr("Not Connected")
                    self.accountSubtitle = TSLocalization.tr(status.backendState == "Stopped" ? "Not Connected" : "Starting")
                    self.deviceIp = "--"
                }

                self.peers = status.peers

                // 同步官方原生多 Profile 列表
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    do {
                        let profiles = try await TSLocalAPI.listProfiles()
                        guard self.pollGeneration == generation, TSLocalAPI.activeSocketPath() == socketPath else { return }
                        self.syncProfiles(profiles)
                        self.checkExpiry(status)
                    } catch {
                        self.errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    // 只更新当前原生账户的有效期；其他账户保留上次已知结果
    private func checkExpiry(_ status: TSTailscaleStatus) {
        guard let account = activeAccount, let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        if let login = status.loginName, !login.isEmpty, login != account.name { return }
        let expiry = status.backendState == "Running" ? status.keyExpiry : (status.keyExpiry ?? account.keyExpiry)
        let expired = status.keyExpired || expiry.map { $0 <= Date() } == true
            || (status.backendState != "Running" && account.nodeKeyExpired == true)
        if accounts[index].keyExpiry != expiry || accounts[index].nodeKeyExpired != expired {
            accounts[index].keyExpiry = expiry
            accounts[index].nodeKeyExpired = expired
            saveAccounts()
        }
        if !expired {
            if status.backendState == "Running" {
                expiryAttempts = expiryAttempts.filter { !$0.hasPrefix(account.id + "|") }
                if renewal?.accountID == account.id { endRenewal() }
            }
            return
        }
        isConnected = false
        accountSubtitle = "节点密钥已过期"
        let key = account.id + "|" + (expiry.map { String($0.timeIntervalSince1970) } ?? "expired")
        guard UIApplication.shared.applicationState == .active, !isAddingAccount, !isAuthenticating, additionError == nil,
              !expiryAttempts.contains(key) else { return }
        if renewAccount(account.id, reportFailure: false) { expiryAttempts.insert(key) }
    }

    // 在当前 socket 上重新认证，不切换 Profile 或重启其他账户
    @discardableResult
    private func renewAccount(_ accountID: String, reportFailure: Bool = true) -> Bool {
        guard !isAuthenticating, !isAddingAccount else { return false }
        do { renewalLease = try TSAccountLease.acquire(exclusive: true) }
        catch { if reportFailure { errorMessage = error.localizedDescription }; return false }
        let request = (id: UUID(), accountID: accountID, socket: TSLocalAPI.activeSocketPath(), deadline: Date().addingTimeInterval(60))
        renewal = request
        isAuthenticating = true
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkRenewal() }
        }
        renewalTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        TSLocalAPI.requestLoginUrl(socketPath: request.socket) { [weak self] value, error in
            Task { @MainActor [weak self] in
                guard let self = self, self.renewal?.id == request.id else { return }
                self.checkRenewal()
                guard self.renewal?.id == request.id else { return }
                guard let value = value, let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                    self.endRenewal(error?.localizedDescription ?? "未获取到重新认证链接")
                    return
                }
                let browser = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { [weak self] _, error in
                    Task { @MainActor [weak self] in
                        guard let self = self, self.renewal?.id == request.id else { return }
                        self.endRenewal((error as NSError?)?.code == ASWebAuthenticationSessionError.canceledLogin.rawValue ? nil : error?.localizedDescription)
                    }
                }
                browser.presentationContextProvider = self.additionPresenter
                self.renewalBrowser = browser
                if !browser.start() { self.endRenewal("无法打开重新认证窗口") }
            }
        }
        return true
    }

    // 回到前台后也拒绝过期或已切换账户的认证结果
    func checkRenewal(now: Date = Date()) {
        guard let renewal = renewal else { return }
        if renewal.accountID != activeAccount?.id || renewal.socket != TSLocalAPI.activeSocketPath() { endRenewal(); return }
        if now >= renewal.deadline { endRenewal("重新认证已超时，请手动重试") }
    }

    // 取消和超时不删除账户，同一密钥取消后不循环弹出认证
    private func endRenewal(_ message: String? = nil) {
        guard renewal != nil else { return }
        renewal = nil
        renewalTimer?.invalidate()
        renewalTimer = nil
        renewalLease?.release()
        renewalLease = nil
        let browser = renewalBrowser
        renewalBrowser = nil
        isAuthenticating = false
        browser?.cancel()
        if let message = message { errorMessage = message }
    }

    // 一次性同步真实当前 Profile，其他账户不争抢主页状态
    private func syncProfiles(_ profiles: [TSTailscaleProfile]) {
        let statePath = activeAccount?.statePath
        var updated = accounts
        var currentIndex: Int?
        for profile in profiles where !profile.name.isEmpty && !profile.profileId.isEmpty {
            let index: Int
            if let existing = updated.firstIndex(where: { $0.statePath == statePath && ($0.profileId == profile.profileId || ($0.profileId.isEmpty && $0.name == profile.name)) }) {
                index = existing
                updated[index].profileId = profile.profileId
                updated[index].tailnet = profile.tailnet
                if !profile.serverUrl.isEmpty { updated[index].serverUrl = profile.serverUrl }
                updated[index].nodeID = profile.nodeID
            } else {
                index = updated.count
                updated.append(TSAccountItem(name: profile.name, tailnet: profile.tailnet, serverUrl: profile.serverUrl.isEmpty ? customCoordinationServer : profile.serverUrl, profileId: profile.profileId, statePath: statePath, nodeID: profile.nodeID))
            }
            if profile.isCurrent { currentIndex = index }
        }
        if let index = currentIndex {
            for i in updated.indices { updated[i].isActive = i == index }
        }
        if accounts != updated || sharedSocketPath != TSLocalAPI.activeSocketPath() { accounts = updated; saveAccounts() }
    }

    // 文件入口固定当前账户，等待后台准备完成后才启动领取
    public func prepareFileTransfer(completion: @escaping (Error?) -> Void) {
        guard isConnected, let account = activeAccount, !isAuthenticating else {
            completion(TSShareState.failure("请先连接当前账户，或等待当前认证完成"))
            return
        }
        isAuthenticating = true
        stopPolling()
        let finish: (Error?) -> Void = { [weak self] error in
            guard let self = self else { return }
            self.isAuthenticating = false
            if UIApplication.shared.applicationState == .active { self.startPolling() }
            guard self.activeAccount?.id == account.id else {
                completion(TSShareState.failure("当前账户已改变，请重新打开文件传输"))
                return
            }
            completion(error)
        }
        ensureDaemonRunning(mode: .tunnel) { [weak self] error in
            if let error = error { finish(error); return }
            self?.waitForFileStorage(socketPath: TSDaemonMode.tunnel.socketPath, completion: finish)
        }
    }

    // 给已重启后台有限的初始化时间，不因持续配置失败无限重启
    func waitForFileStorage(socketPath: String, attempts: Int = 30, completion: @escaping (Error?) -> Void) {
        TSLocalAPI.checkTaildrop(socketPath: socketPath) { [weak self] ready, error in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard TSLocalAPI.activeSocketPath() == socketPath else { completion(TSShareState.failure("后台连接已改变，请重试")); return }
                if ready || error != nil { completion(error); return }
                guard attempts > 1 else {
                    completion(NSError(domain: "TSNativeTailscale", code: Int(ETIMEDOUT), userInfo: [NSLocalizedDescriptionKey: "后台尚未启用 Taildrop 存储，请检查运行日志中的 --statedir 启动参数"]))
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.waitForFileStorage(socketPath: socketPath, attempts: attempts - 1, completion: completion)
                }
            }
        }
    }

    // 确保认证或建网模式的特权守护进程已就绪
    private func ensureDaemonRunning(mode: TSDaemonMode, lease: TSAccountLease? = nil, completion: @escaping (Error?) -> Void) {
        let sockPath = mode.socketPath
        TSLocalAPI.setCustomSocketPath(sockPath)

        guard FileManager.default.fileExists(atPath: sockPath) else {
            startDaemon(mode: mode, lease: lease, completion: completion)
            return
        }

        let chmodResult = SpawnRoot.chmodPath(sockPath, mode: 0o666)
        guard chmodResult == 0 else {
            completion(NSError(domain: "TSNativeTailscale", code: Int(chmodResult), userInfo: [NSLocalizedDescriptionKey: "无法授权 LocalAPI socket (errno \(chmodResult))"]))
            return
        }

        // 验证同模式 socket 确实由存活进程托管
        TSLocalAPI.fetchStatus { [weak self] status, error in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if error == nil, let status = status {
                    self.backendState = status.backendState
                    guard status.backendState == "Running" else { completion(nil); return }
                    // 存活的旧进程不会自动取得新版本的 --statedir 配置
                    TSLocalAPI.checkTaildrop(socketPath: sockPath) { [weak self] ready, storageError in
                        Task { @MainActor [weak self] in
                            guard let self = self else { return }
                            guard TSLocalAPI.activeSocketPath() == sockPath else { completion(TSShareState.failure("后台连接已改变，请重试")); return }
                            // 文件权限或传输错误交由文件入口报告，不能阻断普通连接操作
                            if ready || storageError != nil { completion(nil); return }
                            self.startDaemon(mode: mode, lease: lease) { [weak self] error in
                                if let error = error { completion(error); return }
                                self?.waitForFileStorage(socketPath: sockPath, completion: completion)
                            }
                        }
                    }
                    return
                }
                self.startDaemon(mode: mode, lease: lease, completion: completion)
            }
        }
    }

    // 清理旧模式并启动指定模式的 tailscaled
    private func startDaemon(mode: TSDaemonMode, account: TSAccountItem? = nil, lease: TSAccountLease? = nil, completion: @escaping (Error?) -> Void) {
        let selected = account ?? activeAccount
        if let path = selected?.statePath, TSAccountDraft.managedDirectory(path) == nil {
            completion(NSError(domain: "TSNativeTailscale", code: Int(EINVAL), userInfo: [NSLocalizedDescriptionKey: "拒绝加载账户目录之外的凭据"]))
            return
        }
        let ownLease: TSAccountLease?
        do { ownLease = lease == nil ? try TSAccountLease.acquire(exclusive: true) : nil }
        catch { completion(error); return }
        var daemonPath = Bundle.main.path(forResource: "tailscaled", ofType: nil)
        if daemonPath == nil {
            daemonPath = (Bundle.main.bundlePath as NSString).appendingPathComponent("tailscaled")
        }
        guard let finalPath = daemonPath, FileManager.default.fileExists(atPath: finalPath) else {
            completion(NSError(domain: "TSNativeTailscale", code: Int(ENOENT), userInfo: [NSLocalizedDescriptionKey: "App 内缺少 tailscaled"]))
            return
        }

        let authResult = SpawnRoot.terminateDaemonNamed("tailscaled", socketPath: TSDaemonMode.auth.socketPath)
        let tunnelResult = SpawnRoot.terminateDaemonNamed("tailscaled", socketPath: TSDaemonMode.tunnel.socketPath)
        // 切换模式前回收已经结束的自有后台
        if daemonPid > 1, SpawnRoot.pollChild(daemonPid) != -EAGAIN { daemonPid = 0 }
        guard authResult == 0, tunnelResult == 0 else {
            completion(NSError(domain: "TSNativeTailscale", code: Int(authResult != 0 ? authResult : tunnelResult), userInfo: [NSLocalizedDescriptionKey: "无法清理旧 tailscaled (auth=\(authResult), tunnel=\(tunnelResult))"]))
            return
        }

        let sockPath = mode.socketPath
        TSLocalAPI.setCustomSocketPath(sockPath)
        let daemonArgs = [
            "--tun=\(mode.tunName)",
            "--port=0",
            "--socket=\(sockPath)",
            "--state=\(selected?.statePath ?? "/var/root/tunailscale.state")",
            "--statedir=\(selected?.statePath.map { URL(fileURLWithPath: $0).deletingLastPathComponent().appendingPathComponent("daemon").path } ?? "/var/root/Tunailscale")",
            "--no-logs-no-support"
        ]
        var pid: pid_t = 0
        var spawnErr: Int32 = 0
        var errMsg: NSString? = nil
        self.backendState = "Starting"
        let ret = SpawnRoot.spawnHelperBinary(finalPath, args: daemonArgs, environment: daemonEnvironment(for: selected?.serverUrl ?? customCoordinationServer), root: true, logPath: "/tmp/tailscaled.log", pid: &pid, errNum: &spawnErr, errMsg: &errMsg)
        guard ret == 0 else {
            self.backendState = "Stopped"
            completion(NSError(domain: "TSNativeTailscale", code: Int(spawnErr), userInfo: [NSLocalizedDescriptionKey: errMsg as String? ?? "tailscaled 启动失败"]))
            return
        }
        self.daemonPid = pid
        waitForSocketReady(socketPath: sockPath) { error in
            ownLease?.release()
            completion(error)
        }
    }

    // 等待 socket 节点出现并验证 LocalAPI 可访问
    private func waitForSocketReady(socketPath sock: String, completion: @escaping (Error?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            for _ in 0..<30 {
                if FileManager.default.fileExists(atPath: sock) {
                    let chmodResult = SpawnRoot.chmodPath(sock, mode: 0o666)
                    if chmodResult != 0 {
                        DispatchQueue.main.async {
                            completion(NSError(domain: "TSNativeTailscale", code: Int(chmodResult), userInfo: [NSLocalizedDescriptionKey: "无法授权 LocalAPI socket (errno \(chmodResult))"]))
                        }
                        return
                    }
                    break
                }
                usleep(200000)
            }

            guard FileManager.default.fileExists(atPath: sock) else {
                DispatchQueue.main.async {
                    completion(NSError(domain: "TSNativeTailscale", code: Int(ETIMEDOUT), userInfo: [NSLocalizedDescriptionKey: "tailscaled 未创建 LocalAPI socket"]))
                }
                return
            }

            TSLocalAPI.fetchStatus(socketPath: sock) { status, error in
                DispatchQueue.main.async {
                    if status != nil, error == nil {
                        completion(nil)
                    } else {
                        completion(error ?? NSError(domain: "TSNativeTailscale", code: Int(EIO), userInfo: [NSLocalizedDescriptionKey: "tailscaled LocalAPI 未就绪"]))
                    }
                }
            }
        }
    }

    public func setMagicDns(enabled: Bool) {
        self.enableMagicDns = enabled
        UserDefaults.standard.set(enabled, forKey: magicDnsStorageKey)
        guard FileManager.default.fileExists(atPath: TSLocalAPI.activeSocketPath()) else { return }
        TSLocalAPI.setMagicDns(enabled) { [weak self] success, error in
            guard !success else { return }
            Task { @MainActor [weak self] in
                self?.errorMessage = error?.localizedDescription ?? "MagicDNS 设置失败"
            }
        }
    }

    public func toggleConnection() {
        // 开关与主按钮共用互斥状态，拒绝连接过程中的重复提交
        guard !isAuthenticating else { return }
        if !isLoggedIn {
            // 未登录：直接引导登录授权
            launchBrowserAuth()
            return
        }

        // 暂停轮询定时器，确保过渡期内绝不被后台定时器打扰
        stopPolling()

        isAuthenticating = true

        if isConnected {
            // 即时乐观响应：立即切换为断开展示，防止开关反弹跳跃
            self.isConnected = false
            self.accountSubtitle = TSLocalization.tr("Not Connected")
            self.deviceIp = "--"

            ensureDaemonRunning(mode: .tunnel) { [weak self] error in
                guard let self = self else { return }
                if let error = error {
                    self.isAuthenticating = false
                    self.errorMessage = error.localizedDescription
                    self.startPolling()
                    return
                }
                // 仅断开网络 (保留账号凭据)
                TSLocalAPI.setWantRunning(false) { [weak self] success, runError in
                    Task { @MainActor [weak self] in
                        if !success {
                            self?.errorMessage = runError?.localizedDescription ?? "断开 Tailscale 网络失败"
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            self?.isAuthenticating = false
                            self?.startPolling()
                        }
                    }
                }
            }
        } else {
            // 即时乐观响应：进入正在连接过渡态
            self.accountSubtitle = TSLocalization.tr("Connecting...")

            ensureDaemonRunning(mode: .tunnel) { [weak self] error in
                guard let self = self else { return }
                if let error = error {
                    self.isAuthenticating = false
                    self.errorMessage = error.localizedDescription
                    self.accountSubtitle = TSLocalization.tr("Not Connected")
                    self.startPolling()
                    return
                }

                // 建网后应用持久化 DNS 设置，再启动数据面
                TSLocalAPI.setMagicDns(self.enableMagicDns) { [weak self] dnsSuccess, dnsError in
                    guard let self = self else { return }
                    if !dnsSuccess {
                        Task { @MainActor [weak self] in
                            self?.isAuthenticating = false
                            self?.errorMessage = dnsError?.localizedDescription ?? "MagicDNS 设置失败"
                            self?.startPolling()
                        }
                        return
                    }
                    TSLocalAPI.setWantRunning(true) { [weak self] success, runError in
                        Task { @MainActor [weak self] in
                            guard let self = self else { return }
                            if !success {
                                self.errorMessage = runError?.localizedDescription ?? "启动 Tailscale 网络失败"
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                self.isAuthenticating = false
                                self.startPolling()
                            }
                        }
                    }
                }
            }
        }
    }

    public func loginWithAuthKey(_ key: String) {
        let cleanKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty, !isAuthenticating, !isAddingAccount else { return }
        let lease: TSAccountLease?
        do { lease = try TSAccountLease.acquire(exclusive: true) }
        catch { errorMessage = error.localizedDescription; return }

        self.isAuthenticating = true
        self.accountSubtitle = TSLocalization.tr("Connecting...")
        stopPolling()

        ensureDaemonRunning(mode: .auth, lease: lease) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                lease?.release()
                self.isAuthenticating = false
                self.errorMessage = error.localizedDescription
                self.startPolling()
                return
            }

            TSLocalAPI.login(withAuthKey: cleanKey) { [weak self] success, msg in
                Task { @MainActor [weak self] in
                    lease?.release()
                    guard let self = self else { return }
                    self.isAuthenticating = false
                    if !success {
                        self.errorMessage = msg
                        self.accountSubtitle = TSLocalization.tr("Needs Login")
                        self.startPolling()
                        return
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        self.startPolling()
                    }
                }
            }
        }
    }

    public func loginWithCustomServer(_ serverUrl: String) {
        let cleanUrl = serverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanUrl.isEmpty, !isAuthenticating, !isAddingAccount else { return }
        let lease: TSAccountLease?
        do { lease = try TSAccountLease.acquire(exclusive: true) }
        catch { errorMessage = error.localizedDescription; return }
        setCustomServer(cleanUrl)
        stopPolling()

        ensureDaemonRunning(mode: .auth, lease: lease) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                lease?.release()
                self.errorMessage = error.localizedDescription
                self.startPolling()
                return
            }
            TSLocalAPI.setControlURL(cleanUrl) { [weak self] success, error in
                Task { @MainActor [weak self] in
                    lease?.release()
                    guard let self = self else { return }
                    guard success else {
                        self.errorMessage = error?.localizedDescription ?? "协调服务器设置失败"
                        self.startPolling()
                        return
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.launchBrowserAuth()
                    }
                }
            }
        }
    }

    // 彻底登出 (账户页 Log Out)
    public func performFullLogout() {
        guard !isAddingAccount, !isAuthenticating else { return }
        let lease: TSAccountLease?
        do { lease = try TSAccountLease.acquire(exclusive: true) }
        catch { errorMessage = error.localizedDescription; return }
        self.isAuthenticating = true
        stopPolling()
        ensureDaemonRunning(mode: .auth, lease: lease) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                lease?.release()
                self.isAuthenticating = false
                self.errorMessage = error.localizedDescription
                self.startPolling()
                return
            }
            TSLocalAPI.logout { [weak self] success, error in
                Task { @MainActor [weak self] in
                    lease?.release()
                    guard let self = self else { return }
                    self.isAuthenticating = false
                    guard success else {
                        self.errorMessage = error?.localizedDescription ?? "退出登录失败"
                        self.startPolling()
                        return
                    }
                    self.accounts = []
                    self.saveAccounts()
                    self.isConnected = false
                    self.isLoggedIn = false
                    self.backendState = "Stopped"
                    self.accountTitle = TSLocalization.tr("Not Connected")
                    self.accountSubtitle = TSLocalization.tr("Not Connected")
                    self.deviceIp = "--"
                    self.peers = []
                    self.latestAuthUrl = ""
                    self.killAllDaemons()
                }
            }
        }
    }

    // 重新认证与浏览器授权登录 (Reauthenticate & Browser Login)
    public func launchBrowserAuth() {
        guard !isAuthenticating, !isAddingAccount else { return }
        if let account = activeAccount, FileManager.default.fileExists(atPath: TSLocalAPI.activeSocketPath()) {
            renewAccount(account.id)
            return
        }
        let lease: TSAccountLease?
        do { lease = try TSAccountLease.acquire(exclusive: true) }
        catch { errorMessage = error.localizedDescription; return }
        self.isAuthenticating = true
        self.errorMessage = nil
        self.accountSubtitle = TSLocalization.tr("Connecting...")
        stopPolling()

        ensureDaemonRunning(mode: .auth, lease: lease) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                lease?.release()
                self.isAuthenticating = false
                self.accountSubtitle = TSLocalization.tr("Needs Login")
                self.errorMessage = error.localizedDescription
                self.startPolling()
                return
            }

            // 官方单一链路：login-interactive 后从 status 获取 AuthURL
            TSLocalAPI.requestLoginUrl { [weak self] authUrl, error in
                Task { @MainActor [weak self] in
                    lease?.release()
                    guard let self = self else { return }
                    if let urlStr = authUrl, let url = URL(string: urlStr) {
                        self.isAuthenticating = false
                        self.latestAuthUrl = urlStr
                        UIApplication.shared.open(url, options: [:]) { [weak self] opened in
                            guard !opened else { return }
                            Task { @MainActor [weak self] in
                                self?.accountSubtitle = TSLocalization.tr("Needs Login")
                                self?.errorMessage = "系统浏览器无法打开授权 URL: \(urlStr)"
                                self?.startPolling()
                            }
                        }
                        return
                    }
                    self.isAuthenticating = false
                    self.accountSubtitle = TSLocalization.tr("Needs Login")
                    self.errorMessage = error?.localizedDescription ?? "未获取到授权 URL"
                    self.startPolling()
                }
            }
        }
    }

    deinit {
        pollTimer?.invalidate()
        additionTimer?.invalidate()
        renewalTimer?.invalidate()
    }
}
