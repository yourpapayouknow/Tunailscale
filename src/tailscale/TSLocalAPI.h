/*
 * TSLocalAPI.h - Tailscale LocalAPI Unix Domain Socket 客户端
 */

#import <Foundation/Foundation.h>

#define TAILSCALE_SOCK_PATH "/tmp/tailscaled.sock"

NS_ASSUME_NONNULL_BEGIN

@interface TSTailscalePeer : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, readonly) NSString *displayName;
@property (nonatomic, copy) NSString *ip;
@property (nonatomic, copy) NSString *os;
@property (nonatomic, assign) BOOL online;
@property (nonatomic, assign) BOOL taildropAvailable;
@property (nonatomic, copy) NSArray<NSString *> *peerAPIURLs;
@end

@interface TSTailscaleProfile : NSObject
@property (nonatomic, copy) NSString *serverUrl;
@property (nonatomic, copy) NSString *nodeID;
@property (nonatomic, copy) NSString *profileId;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *tailnet;
@property (nonatomic, assign) BOOL isCurrent;
@end

@interface TSTailscaleStatus : NSObject
@property (nonatomic, copy) NSString *backendState; /* Running, NeedsLogin, Stopped */
@property (nonatomic, copy) NSString *selfIp;
@property (nonatomic, copy, nullable) NSString *selfName;
@property (nonatomic, copy, nullable) NSString *loginName;
@property (nonatomic, copy, nullable) NSString *tailnetName;
@property (nonatomic, copy, nullable) NSString *authUrl;
@property (nonatomic, strong, nullable) NSDate *keyExpiry;
@property (nonatomic, assign) BOOL keyExpired;
@property (nonatomic, strong) NSArray<TSTailscalePeer *> *peers;
@end

@interface TSLocalAPI : NSObject

/* 主 App 和扩展复用系统解析的共享容器 */
+ (nullable NSURL *)sharedContainer;
/* 配置/获取当前通信使用的共享 Unix Socket 路径 */
+ (void)setCustomSocketPath:(nullable NSString *)path;
+ (NSString *)defaultSocketPath;
+ (NSString *)activeSocketPath;

/* 获取当前 Tailscale 状态与节点信息 */
+ (void)fetchStatusWithCompletion:(void(^)(TSTailscaleStatus * _Nullable status, NSError * _Nullable error))completion;

/* 独立认证会话固定使用自己的 socket，不切换全局客户端 */
+ (void)fetchStatusForSocket:(NSString *)path completion:(void(^)(TSTailscaleStatus * _Nullable status, NSError * _Nullable error))completion NS_SWIFT_NAME(fetchStatus(socketPath:completion:));
/* 检查实际收件存储；NO 且无错误仅表示官方明确报告未配置存储 */
+ (void)checkTaildropForSocket:(NSString *)path completion:(void(^)(BOOL ready, NSError * _Nullable error))completion NS_SWIFT_NAME(checkTaildrop(socketPath:completion:));
+ (void)requestLoginUrlForSocket:(NSString *)path completion:(void(^)(NSString * _Nullable authUrl, NSError * _Nullable error))completion NS_SWIFT_NAME(requestLoginUrl(socketPath:completion:));
+ (void)listProfilesForSocket:(NSString *)path completion:(void(^)(NSArray<TSTailscaleProfile *> *profiles, NSError * _Nullable error))completion NS_SWIFT_NAME(listProfiles(socketPath:completion:));
+ (void)setControlURL:(NSString *)url socketPath:(NSString *)path completion:(void(^)(BOOL success, NSError * _Nullable error))completion;

/* 发起交互式登录请求获取授权 URL */
+ (void)requestLoginUrlWithCompletion:(void(^)(NSString * _Nullable authUrl, NSError * _Nullable error))completion;

/* 使用 AuthKey 预共享密钥直接登录入网 (走官方 POST /localapi/v0/start) */
+ (void)loginWithAuthKey:(NSString *)authKey completion:(void(^)(BOOL success, NSString *msg))completion;

/* 设置网络连接运行状态 (WantRunning: YES 连接, NO 断开网络保留账号，走官方 POST /localapi/v0/start) */
+ (void)setWantRunning:(BOOL)wantRunning completion:(void(^)(BOOL success, NSError * _Nullable error))completion;

/* 设置 MagicDNS 域名解析状态 (走官方 POST /localapi/v0/start) */
+ (void)setMagicDns:(BOOL)enabled completion:(void(^)(BOOL success, NSError * _Nullable error))completion;

/* 设置自定义协调服务器地址 (ControlURL, 如 Headscale，走官方 POST /localapi/v0/start) */
+ (void)setControlURL:(NSString *)controlUrl completion:(void(^)(BOOL success, NSError * _Nullable error))completion;

/* 彻底注销账号并删除节点凭据 (Log Out) */
+ (void)logoutWithCompletion:(void(^)(BOOL success, NSError * _Nullable error))completion;

/* 官方原生多账户 Profiles 管理 */
+ (void)listProfilesWithCompletion:(void(^)(NSArray<TSTailscaleProfile *> *profiles, NSError * _Nullable error))completion;
+ (void)newProfileWithCompletion:(void(^)(BOOL success, NSError * _Nullable error))completion;
+ (void)switchProfile:(NSString *)profileId completion:(void(^)(BOOL success, NSError * _Nullable error))completion;
+ (void)deleteProfile:(NSString *)profileId completion:(void(^)(BOOL success, NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
