// App 与系统分享扩展共享当前账户元数据和原生文件锁，不共享密钥正文
import Foundation
import Darwin

struct TSShareState: Codable {
    let account: TSAccountItem
    let socket: String

    // 由系统解析共享容器，不硬编码容器 UUID
    static var container: URL? {
        #if os(iOS)
        return TSLocalAPI.sharedContainer()
        #else
        return nil
        #endif
    }

    // 原子更新无密钥快照，未登录时移除旧的共享入口
    static func save(account: TSAccountItem?, socket: String) throws {
        #if os(iOS)
        guard let container = container else { throw failure("系统分享数据容器不可用") }
        let file = container.appendingPathComponent("active-account.json")
        if let account = account, !account.profileId.isEmpty {
            let data = try JSONEncoder().encode(TSShareState(account: account, socket: socket))
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } else if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        #endif
    }

    // 读取快照后仍需向后台验证真实当前 Profile
    static func load() throws -> TSShareState {
        guard let container = container else { throw failure("请先打开App完成连接") }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: container.appendingPathComponent("active-account.json")))
    }

    // 用原生 Profile、节点及控制服务器核对账户，拒绝迟到的旧账户快照
    func matches(_ profile: TSTailscaleProfile) -> Bool {
        profile.isCurrent && profile.profileId == account.profileId && profile.name == account.name
            && (profile.serverUrl.isEmpty || profile.serverUrl == account.serverUrl)
            && (account.nodeID == nil || account.nodeID?.isEmpty == true || profile.nodeID == account.nodeID)
    }

    // 统一生成可展示的本地错误
    static func failure(_ message: String) -> NSError {
        NSError(domain: "TSNativeTailscale", code: Int(EBUSY), userInfo: [NSLocalizedDescriptionKey: message])
    }
}

// 分享传输持共享锁，账户变更持独占锁，防止传输期间跨 Tailnet 切换
final class TSAccountLease {
    private var descriptor: Int32

    // 在共享容器内创建原生 flock，宿主测试可指定独立临时文件
    init(file: URL, exclusive: Bool) throws {
        // 传输锁由 CLI 继承，包含 App 被关闭后也不能切走正在传输的账户
        descriptor = open(file.path, O_CREAT | O_RDWR | (exclusive ? O_CLOEXEC : 0), 0o600)
        guard descriptor >= 0 else { throw TSShareState.failure("无法创建账户操作锁 (errno \(errno))") }
        if flock(descriptor, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) != 0 {
            close(descriptor)
            descriptor = -1
            throw TSShareState.failure("账户正在认证或传输，请完成或取消后重试")
        }
    }

    // 正式 iOS 必须有共享容器；macOS 单元宿主不模拟容器权限
    static func acquire(exclusive: Bool) throws -> TSAccountLease? {
        #if os(iOS)
        guard let container = TSShareState.container else { throw TSShareState.failure("系统分享数据容器不可用") }
        return try TSAccountLease(file: container.appendingPathComponent("account.lock"), exclusive: exclusive)
        #else
        return nil
        #endif
    }

    // 提前释放锁后才交付异步完成事件
    func release() {
        if descriptor >= 0 { close(descriptor); descriptor = -1 }
    }

    deinit { release() }
}
