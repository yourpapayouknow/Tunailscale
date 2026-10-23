/* 验证真实 LocalAPI 解析、当前账户及独立 socket，不连接实际节点 */
#import "../src/tailscale/TSLocalAPI.h"
#include <assert.h>

static NSString *scenario;
static NSString *draftSocket = @"/tmp/test-auth-isolated.sock";

@interface ScopedAPI : TSLocalAPI
@end
@implementation ScopedAPI
/* 使用与真机共享容器等长的路径验证原生 socket 位置 */
+ (NSURL *)sharedContainer {
    return [NSURL fileURLWithPath:@"/private/var/mobile/Containers/Shared/AppGroup/00000000-0000-0000-0000-000000000000" isDirectory:YES];
}
/* 拦截固定 socket 的底层 HTTP 请求 */
+ (void)sendRequestToSocketPath:(NSString *)socket method:(NSString *)method path:(NSString *)path body:(NSData *)body completion:(void(^)(NSData *, NSInteger, NSError *))completion {
    assert([socket isEqualToString:draftSocket]);
    /* 异常状态不能伪装成有效连接或触发字典下标崩溃 */
    if ([path isEqualToString:@"/localapi/v0/status"] && [scenario hasPrefix:@"status-"]) {
        NSString *body = [scenario isEqualToString:@"status-array"] ? @"[]" : @"{\"BackendState\":\"Running\"}";
        completion([body dataUsingEncoding:NSUTF8StringEncoding], [scenario isEqualToString:@"status-http"] ? 503 : 200, nil);
        return;
    }
    NSDictionary *selfInfo = @{@"User": @2, @"Expired": @YES, @"KeyExpiry": @"2026-10-17T06:00:00.123Z"};
    if ([path isEqualToString:@"/localapi/v0/files/"]) {
        assert([method isEqualToString:@"GET"] && body == nil);
        if ([scenario isEqualToString:@"storage-missing"]) {
            completion([@"Taildrop disabled; no storage directory\n" dataUsingEncoding:NSUTF8StringEncoding], 500, nil);
        } else if ([scenario isEqualToString:@"storage-permission"]) {
            completion([@"file access denied\n" dataUsingEncoding:NSUTF8StringEncoding], 403, nil);
        } else if ([scenario isEqualToString:@"storage-other-error"]) {
            completion([@"disk error" dataUsingEncoding:NSUTF8StringEncoding], 500, nil);
        } else if ([scenario isEqualToString:@"storage-null"]) {
            completion([@"null\n" dataUsingEncoding:NSUTF8StringEncoding], 200, nil);
        } else if ([scenario isEqualToString:@"storage-malformed"]) {
            completion([@"{}" dataUsingEncoding:NSUTF8StringEncoding], 200, nil);
        } else if ([scenario isEqualToString:@"storage-transport"]) {
            completion(nil, 0, [NSError errorWithDomain:@"TSLocalAPI" code:ETIMEDOUT userInfo:nil]);
        } else { completion([@"[]\n" dataUsingEncoding:NSUTF8StringEncoding], 200, nil); }
        return;
    }
    if ([scenario isEqualToString:@"invalid-expiry"]) selfInfo = @{@"KeyExpiry": [NSNull null]};
    if ([scenario isEqualToString:@"zero-expiry"]) selfInfo = @{@"KeyExpiry": @"0001-01-01T00:00:00Z"};
    if ([scenario isEqualToString:@"plain-expiry"]) selfInfo = @{@"KeyExpiry": @"2027-01-01T00:00:00Z"};
    if ([scenario isEqualToString:@"malformed-expiry"]) selfInfo = @{@"KeyExpiry": @"invalid", @"Expired": @"yes"};
    id payload = @{@"BackendState": @"Running", @"Self": selfInfo,
                   @"User": @{@"1": @{@"LoginName": @"not-self"}, @"2": @{@"LoginName": @"self-account"}},
                   @"Peer": @{@"one": @{@"TailscaleIPs": @[@"100.64.0.2"], @"TaildropTarget": @1, @"PeerAPIURL": @[@"http://100.64.0.2:1234", @3, NSNull.null]},
                              @"offline": @{@"TailscaleIPs": @[@"100.64.0.3"], @"TaildropTarget": @5},
                              @"foreign": @{@"TailscaleIPs": @[@"100.64.0.4"], @"TaildropTarget": @9}},
                   @"AuthURL": @"https://login.tailscale.com/a/test"};
    if ([path isEqualToString:@"/localapi/v0/profiles/"]) {
        if ([scenario isEqualToString:@"http-error"]) { completion([NSData data], 500, nil); return; }
        payload = @[@{@"ID": @"a", @"Name": @"nickname", @"ControlURL": @"https://headscale.example", @"NodeID": @"node-a", @"UserProfile": @{@"LoginName": @"account-a"}},
                    @{@"ID": @"b", @"Name": @"account-b"}];
    } else if ([path isEqualToString:@"/localapi/v0/profiles/current"]) {
        payload = @{@"ID": @"b"};
    } else if ([path isEqualToString:@"/localapi/v0/login-interactive"]) {
        assert([method isEqualToString:@"POST"]);
        // 全局 socket 在请求中途改变，后续 URL 轮询仍须使用原 socket
        [TSLocalAPI setCustomSocketPath:@"/tmp/new-primary.sock"];
        completion([NSData data], 204, nil);
        return;
    } else if ([path isEqualToString:@"/localapi/v0/start"]) {
        NSDictionary *request = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
        assert([request[@"UpdatePrefs"][@"ControlURL"] isEqualToString:@"https://headscale.example"]);
        completion([NSData data], 204, nil);
        return;
    }
    completion([NSJSONSerialization dataWithJSONObject:payload options:0 error:nil], 200, nil);
}
@end

/* 覆盖多用户、自定义账户名、当前 Profile 与异步 URL 轮询 */
int main(void) {
    @autoreleasepool {
        NSString *sharedSocket = [[ScopedAPI sharedContainer] URLByAppendingPathComponent:@"ts.sock"].path;
        assert([[ScopedAPI defaultSocketPath] isEqualToString:sharedSocket]);
        assert([sharedSocket lengthOfBytesUsingEncoding:NSUTF8StringEncoding] < 104);
        /* 短名称只用于显示，不改原名称或发送地址 */
        TSTailscalePeer *device = [TSTailscalePeer new];
        device.ip = @"100.64.0.2";
        device.name = @"desktop.tail42012.ts.net.";
        assert([device.displayName isEqualToString:@"desktop"]);
        assert([device.name isEqualToString:@"desktop.tail42012.ts.net."]);
        assert([device.ip isEqualToString:@"100.64.0.2"]);
        device.name = @"中文设备";
        assert([device.displayName isEqualToString:@"中文设备"]);
        device.name = @"";
        assert([device.displayName isEqualToString:device.ip]);
        [TSLocalAPI setCustomSocketPath:@"/tmp/primary.sock"];
        BOOL safeStatus = YES;
        for (NSString *value in @[@"status-http", @"status-array"]) {
            scenario = value;
            __block BOOL rejected = NO;
            @try {
                [ScopedAPI fetchStatusForSocket:draftSocket completion:^(TSTailscaleStatus *status, NSError *error) {
                    rejected = status == nil && error != nil;
                }];
            } @catch (NSException *exception) { fprintf(stderr, "FAIL: status parser raised %s\n", exception.name.UTF8String); }
            if (!rejected) fprintf(stderr, "FAIL: %s was not rejected safely\n", value.UTF8String);
            safeStatus &= rejected;
        }
        assert(safeStatus);
        for (NSString *value in @[@"storage-ready", @"storage-null", @"storage-missing", @"storage-permission", @"storage-other-error", @"storage-malformed", @"storage-transport"]) {
            scenario = value;
            [ScopedAPI checkTaildropForSocket:draftSocket completion:^(BOOL ready, NSError *error) {
                BOOL enabled = [value isEqualToString:@"storage-ready"] || [value isEqualToString:@"storage-null"];
                assert(ready == enabled);
                assert((error == nil) == (enabled || [value isEqualToString:@"storage-missing"]));
            }];
        }
        scenario = nil;
        __block BOOL checked = NO;
        [ScopedAPI fetchStatusForSocket:draftSocket completion:^(TSTailscaleStatus *status, NSError *error) {
            assert(!error && [status.loginName isEqualToString:@"self-account"]);
            assert(status.keyExpired && status.keyExpiry != nil);
            assert(status.peers.count == 3);
            for (TSTailscalePeer *peer in status.peers) {
                assert(peer.taildropAvailable == ![peer.ip isEqualToString:@"100.64.0.4"]);
                assert(peer.peerAPIURLs.count == ([peer.ip isEqualToString:@"100.64.0.2"] ? 1 : 0));
            }
            checked = YES;
        }];
        assert(checked);
        for (NSString *value in @[@"invalid-expiry", @"zero-expiry", @"malformed-expiry", @"plain-expiry"]) {
            scenario = value;
            [ScopedAPI fetchStatusForSocket:draftSocket completion:^(TSTailscaleStatus *status, NSError *error) {
                assert(!error && !status.keyExpired);
                assert((status.keyExpiry != nil) == [value isEqualToString:@"plain-expiry"]);
            }];
        }
        scenario = nil;
        checked = NO;
        [ScopedAPI listProfilesForSocket:draftSocket completion:^(NSArray<TSTailscaleProfile *> *profiles, NSError *error) {
            assert(!error && profiles.count == 2);
            assert([profiles[0].name isEqualToString:@"account-a"]);
            assert([profiles[0].serverUrl isEqualToString:@"https://headscale.example"] && [profiles[0].nodeID isEqualToString:@"node-a"]);
            assert(!profiles[0].isCurrent && profiles[1].isCurrent);
            checked = YES;
        }];
        assert(checked);
        scenario = @"http-error";
        checked = NO;
        [ScopedAPI listProfilesForSocket:draftSocket completion:^(NSArray<TSTailscaleProfile *> *profiles, NSError *error) {
            assert(error && profiles.count == 0);
            checked = YES;
        }];
        assert(checked);
        scenario = nil;
        [ScopedAPI setControlURL:@"https://headscale.example" socketPath:draftSocket completion:^(BOOL success, NSError *error) {
            assert(success && !error);
        }];
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        __block BOOL login = NO;
        [ScopedAPI requestLoginUrlForSocket:draftSocket completion:^(NSString *url, NSError *error) {
            assert(!error && [url isEqualToString:@"https://login.tailscale.com/a/test"]);
            login = YES;
            dispatch_semaphore_signal(sem);
        }];
        assert(dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) == 0);
        assert(login && [[TSLocalAPI activeSocketPath] isEqualToString:@"/tmp/new-primary.sock"]);
        puts("PASS: LocalAPI pinned sockets, current profile, self identity, HTTP errors, login URL isolation");
    }
}
