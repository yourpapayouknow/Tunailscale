// 账户元数据不包含密钥，原生凭据仅保存在独立 state 文件中
import Foundation

public struct TSAccountItem: Codable, Identifiable, Equatable {
    public var id: String { "\(statePath ?? "legacy")|\(profileId.isEmpty ? name : profileId)" }
    public var name: String
    public var tailnet: String
    public var serverUrl: String
    public var isActive: Bool
    public var profileId: String
    public var statePath: String?
    public var keyExpiry: Date?
    public var nodeKeyExpired: Bool?
    public var nodeID: String?
    public var isExpired: Bool { nodeKeyExpired == true || keyExpiry.map { $0 <= Date() } == true }

    // 兼容没有独立路径和有效期的旧账户记录
    public init(name: String, tailnet: String = "tailnet", serverUrl: String = "https://controlplane.tailscale.com", isActive: Bool = false, profileId: String = "", statePath: String? = nil, keyExpiry: Date? = nil, nodeKeyExpired: Bool? = nil, nodeID: String? = nil) {
        self.name = name
        self.tailnet = tailnet
        self.serverUrl = serverUrl
        self.isActive = isActive
        self.profileId = profileId
        self.statePath = statePath
        self.keyExpiry = keyExpiry
        self.nodeKeyExpired = nodeKeyExpired
        self.nodeID = nodeID
    }
}
