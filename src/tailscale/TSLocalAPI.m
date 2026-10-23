/*
 * TSLocalAPI.m - Tailscale LocalAPI Unix Domain Socket 客户端实现
 */

#import "TSLocalAPI.h"
#import <TargetConditionals.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

@implementation TSTailscalePeer
/* 界面共用短设备名，原始名称与传输地址保持不变 */
- (NSString *)displayName {
    NSString *host = [self.name componentsSeparatedByString:@"."].firstObject;
    return host.length > 0 ? host : self.ip;
}
@end

@implementation TSTailscaleProfile
@end

@implementation TSTailscaleStatus
@end

static NSString *sCustomSocketPath = nil;

@implementation TSLocalAPI

#include <netinet/in.h>
#include <arpa/inet.h>

+ (void)setCustomSocketPath:(NSString *)path {
    sCustomSocketPath = [path copy];
}

/* 共享容器同时授权主 App 和分享扩展的原生 IPC */
+ (NSURL *)sharedContainer {
#if TARGET_OS_IPHONE
    return [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:@"group.com.iwmei.tunailscale"];
#else
    return nil;
#endif
}

+ (NSString *)defaultSocketPath {
    /* 宿主测试保留旧路径；iOS 使用 App Group 内的短 socket 名 */
    return [[self sharedContainer] URLByAppendingPathComponent:@"ts.sock"].path ?: @"/var/run/tailscaled.sock";
}

+ (NSString *)activeSocketPath {
    if (sCustomSocketPath && sCustomSocketPath.length > 0) {
        return sCustomSocketPath;
    }
    return [self defaultSocketPath];
}

/* 向 Unix Socket 发送原生 HTTP 请求并读取完整响应体 (内置就绪探测与重试) */
+ (void)sendRequestToSocketPath:(NSString *)sockPath
                         method:(NSString *)method
                           path:(NSString *)path
                           body:(NSData *)body
                     completion:(void(^)(NSData *respData, NSInteger statusCode, NSError *err))completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        /* 所有传输与协议失败只回调一次，不把残缺响应当成成功 */
        void (^fail)(NSInteger, NSString *) = ^(NSInteger code, NSString *message) {
            if (completion) completion(nil, 0, [NSError errorWithDomain:@"TSLocalAPI" code:code userInfo:@{NSLocalizedDescriptionKey:message}]);
        };
        if (!sockPath.length || [sockPath lengthOfBytesUsingEncoding:NSUTF8StringEncoding] >= sizeof(((struct sockaddr_un *)0)->sun_path)) {
            fail(ENAMETOOLONG, @"Invalid LocalAPI socket path");
            return;
        }
        int sock = -1;
        int lastErr = 0;
        int maxRetries = 15; /* 15 * 200ms = 3.0 秒就绪等待期 */

        for (int retry = 0; retry < maxRetries; retry++) {
            sock = socket(AF_UNIX, SOCK_STREAM, 0);
            if (sock < 0) {
                lastErr = errno;
                break;
            }

            /* 核心网络保护：严密禁用 SIGPIPE，杜绝后台服务异常断开时导致主 App 瞬间闪退 */
            int nosigpipe = 1;
            setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, sizeof(nosigpipe));

            struct timeval tv = { .tv_sec = 6, .tv_usec = 0 };
            setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
            setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

            struct sockaddr_un addr;
            memset(&addr, 0, sizeof(addr));
            addr.sun_family = AF_UNIX;
            strncpy(addr.sun_path, [sockPath UTF8String], sizeof(addr.sun_path) - 1);

            if (connect(sock, (struct sockaddr *)&addr, sizeof(addr)) == 0) {
                lastErr = 0;
                break;
            }

            lastErr = errno;
            close(sock);
            sock = -1;

            if ((lastErr == ENOENT || lastErr == ECONNREFUSED) && retry < maxRetries - 1) {
                usleep(200000); /* 200ms */
                continue;
            }
            break;
        }

        if (sock < 0) {
            if (completion) completion(nil, 0, [NSError errorWithDomain:@"TSLocalAPI" code:lastErr userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"Cannot connect to %s: %s", [sockPath UTF8String], strerror(lastErr)]}]);
            return;
        }

        /* 构造基础 HTTP 1.0 请求 (HTTP/1.0 规范不使用 Chunked，保证 EOF 截断纯净响应) */
        NSMutableString *httpHead = [NSMutableString string];
        [httpHead appendFormat:@"%@ %@ HTTP/1.0\r\n", method, path];
        [httpHead appendString:@"Host: local-tailscaled.sock\r\n"];
        [httpHead appendString:@"User-Agent: TSNativeTailscale/1.0\r\n"];
        [httpHead appendString:@"Connection: close\r\n"];
        if (body && body.length > 0) {
            [httpHead appendFormat:@"Content-Length: %lu\r\n", (unsigned long)body.length];
            [httpHead appendString:@"Content-Type: application/json\r\n"];
        } else if ([method isEqualToString:@"POST"] || [method isEqualToString:@"PUT"]) {
            [httpHead appendString:@"Content-Length: 0\r\n"];
        }
        [httpHead appendString:@"\r\n"];

        NSMutableData *request = [[httpHead dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
        if (body.length) [request appendData:body];
        size_t sent = 0;
        while (sent < request.length) {
            ssize_t count = write(sock, (const char *)request.bytes + sent, request.length - sent);
            if (count < 0 && errno == EINTR) continue;
            if (count <= 0) {
                int error = count < 0 ? errno : EIO;
                close(sock); fail(error, @"Unable to send complete LocalAPI request"); return;
            }
            sent += count;
        }
        shutdown(sock, SHUT_WR);

        /* 接收完整响应 */
        NSMutableData *fullResp = [NSMutableData data];
        uint8_t buffer[4096];
        ssize_t bytesRead = 0;
        while (true) {
            bytesRead = read(sock, buffer, sizeof(buffer));
            if (bytesRead < 0 && errno == EINTR) continue;
            if (bytesRead < 0) {
                int error = errno;
                close(sock); fail(error, @"Unable to read complete LocalAPI response"); return;
            }
            if (bytesRead == 0) break;
            [fullResp appendBytes:buffer length:bytesRead];
        }
        close(sock);

        if (fullResp.length == 0) {
            if (completion) completion(nil, 0, [NSError errorWithDomain:@"TSLocalAPI" code:EIO userInfo:@{NSLocalizedDescriptionKey:@"Empty response from tailscaled"}]);
            return;
        }

        /* 解析 HTTP 状态行与 Body */
        NSData *separator = [@"\r\n\r\n" dataUsingEncoding:NSASCIIStringEncoding];
        NSRange headEnd = [fullResp rangeOfData:separator options:0 range:NSMakeRange(0, fullResp.length)];
        if (headEnd.location == NSNotFound) { fail(EINVAL, @"Malformed HTTP header"); return; }
        NSString *header = [[NSString alloc] initWithData:[fullResp subdataWithRange:NSMakeRange(0, headEnd.location)] encoding:NSASCIIStringEncoding];
        NSInteger statusCode = 0;
        char proto[16];
        if (!header || sscanf(header.UTF8String, "%15s %ld", proto, &statusCode) != 2
            || (strcmp(proto, "HTTP/1.0") && strcmp(proto, "HTTP/1.1")) || statusCode < 100 || statusCode > 599) {
            fail(EINVAL, @"Malformed HTTP status"); return;
        }
        NSMutableDictionary *fields = [NSMutableDictionary dictionary];
        for (NSString *line in [header componentsSeparatedByString:@"\r\n"]) {
            NSRange colon = [line rangeOfString:@":"];
            if (colon.location != NSNotFound) fields[[line substringToIndex:colon.location].lowercaseString] = [[line substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        }
        NSUInteger bodyOffset = NSMaxRange(headEnd);
        NSData *bodyData = [fullResp subdataWithRange:NSMakeRange(bodyOffset, fullResp.length - bodyOffset)];
        /* 分块响应必须读到结束块，所有查找都限定在 NSData 范围内 */
        if ([fields[@"transfer-encoding"] caseInsensitiveCompare:@"chunked"] == NSOrderedSame && fields[@"transfer-encoding"]) {
            NSMutableData *dechunked = [NSMutableData data];
            NSData *newline = [@"\r\n" dataUsingEncoding:NSASCIIStringEncoding];
            NSUInteger cursor = 0;
            while (cursor < bodyData.length) {
                NSRange line = [bodyData rangeOfData:newline options:0 range:NSMakeRange(cursor, bodyData.length - cursor)];
                if (line.location == NSNotFound) break;
                NSString *size = [[NSString alloc] initWithData:[bodyData subdataWithRange:NSMakeRange(cursor, line.location - cursor)] encoding:NSASCIIStringEncoding];
                NSScanner *scanner = [NSScanner scannerWithString:[size componentsSeparatedByString:@";"].firstObject ?: @""];
                unsigned long long count = 0;
                if (![scanner scanHexLongLong:&count] || !scanner.isAtEnd) break;
                cursor = NSMaxRange(line);
                if (count == 0) {
                    if (bodyData.length - cursor >= 2 && memcmp((const char *)bodyData.bytes + cursor, "\r\n", 2) == 0) {
                        if (completion) completion(dechunked, statusCode, nil);
                        return;
                    }
                    break;
                }
                if (count > bodyData.length - cursor || bodyData.length - cursor - count < 2) break;
                [dechunked appendData:[bodyData subdataWithRange:NSMakeRange(cursor, (NSUInteger)count)]];
                cursor += count;
                if (memcmp((const char *)bodyData.bytes + cursor, "\r\n", 2)) break;
                cursor += 2;
            }
            fail(EINVAL, @"Incomplete chunked HTTP response"); return;
        } else if (fields[@"transfer-encoding"]) {
            fail(EINVAL, @"Unsupported HTTP transfer encoding"); return;
        }
        if (fields[@"content-length"]) {
            NSString *length = fields[@"content-length"];
            NSScanner *scanner = [NSScanner scannerWithString:length];
            unsigned long long count = 0;
            if ([length hasPrefix:@"-"] || ![scanner scanUnsignedLongLong:&count] || !scanner.isAtEnd || count != bodyData.length) {
                fail(EINVAL, @"Incomplete HTTP body or invalid Content-Length"); return;
            }
        }
        if (completion) completion(bodyData, statusCode, nil);
    });
}

/* 获取状态与节点信息 */
+ (void)fetchStatusWithCompletion:(void(^)(TSTailscaleStatus *status, NSError *error))completion {
    [self fetchStatusForSocket:[self activeSocketPath] completion:completion];
}

/* 从固定会话读取状态 */
+ (void)fetchStatusForSocket:(NSString *)sockPath completion:(void(^)(TSTailscaleStatus *status, NSError *error))completion {
    [self sendRequestToSocketPath:sockPath method:@"GET" path:@"/localapi/v0/status" body:nil completion:^(NSData *respData, NSInteger statusCode, NSError *err) {
        if (err || statusCode != 200) {
            if (!err) err = [NSError errorWithDomain:@"TSLocalAPI" code:statusCode userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"状态读取失败 (HTTP %ld)", (long)statusCode]}];
            if (completion) completion(nil, err);
            return;
        }

        NSError *jsonErr = nil;
        NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:respData options:0 error:&jsonErr];
        if (jsonErr || ![dict isKindOfClass:NSDictionary.class]) {
            if (completion) completion(nil, jsonErr ?: [NSError errorWithDomain:@"TSLocalAPI" code:EINVAL userInfo:nil]);
            return;
        }

        TSTailscaleStatus *st = [[TSTailscaleStatus alloc] init];
        
        id backendStateVal = dict[@"BackendState"];
        if (backendStateVal && [backendStateVal isKindOfClass:[NSString class]]) {
            st.backendState = (NSString *)backendStateVal;
        } else {
            st.backendState = @"Stopped";
        }

        id authUrlVal = dict[@"AuthURL"];
        if (authUrlVal && [authUrlVal isKindOfClass:[NSString class]]) {
            st.authUrl = (NSString *)authUrlVal;
        }

        id ipsVal = dict[@"TailscaleIPs"];
        if (ipsVal && [ipsVal isKindOfClass:[NSArray class]]) {
            NSArray *ips = (NSArray *)ipsVal;
            if (ips.count > 0 && [ips.firstObject isKindOfClass:[NSString class]]) {
                st.selfIp = ips.firstObject;
            } else {
                st.selfIp = @"--";
            }
        } else {
            st.selfIp = @"--";
        }

        id selfVal = dict[@"Self"];
        if (selfVal && [selfVal isKindOfClass:[NSDictionary class]]) {
            NSDictionary *selfObj = (NSDictionary *)selfVal;
            /* 读取本机节点密钥有效期，不读取或保存 AuthKey */
            st.keyExpired = [selfObj[@"Expired"] isKindOfClass:NSNumber.class] && [selfObj[@"Expired"] boolValue];
            if ([selfObj[@"KeyExpiry"] isKindOfClass:NSString.class]) {
                NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
                formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
                st.keyExpiry = [formatter dateFromString:selfObj[@"KeyExpiry"]];
                if (!st.keyExpiry) {
                    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
                    st.keyExpiry = [formatter dateFromString:selfObj[@"KeyExpiry"]];
                }
                if (st.keyExpiry && st.keyExpiry.timeIntervalSince1970 <= 0) st.keyExpiry = nil;
            }
            id dnsName = selfObj[@"DNSName"];
            id hostName = selfObj[@"HostName"];
            if (dnsName && [dnsName isKindOfClass:[NSString class]] && [(NSString *)dnsName length] > 0) {
                st.selfName = (NSString *)dnsName;
            } else if (hostName && [hostName isKindOfClass:[NSString class]]) {
                st.selfName = (NSString *)hostName;
            }
        }

        id userVal = dict[@"User"];
        if (userVal && [userVal isKindOfClass:[NSDictionary class]]) {
            NSDictionary *userDict = (NSDictionary *)userVal;
            id selfUser = [selfVal isKindOfClass:[NSDictionary class]] ? selfVal[@"User"] : nil;
            id profile = selfUser ? userDict[[selfUser description]] : nil;
            if (!profile && userDict.count == 1) profile = userDict.allValues.firstObject;
            if ([profile isKindOfClass:[NSDictionary class]] && [profile[@"LoginName"] isKindOfClass:[NSString class]]) {
                st.loginName = profile[@"LoginName"];
            }
        }

        id tailnetVal = dict[@"CurrentTailnet"];
        if (tailnetVal && [tailnetVal isKindOfClass:[NSDictionary class]]) {
            id tailnetName = tailnetVal[@"Name"];
            if (tailnetName && [tailnetName isKindOfClass:[NSString class]]) {
                st.tailnetName = (NSString *)tailnetName;
            }
        }

        NSMutableArray<TSTailscalePeer *> *peers = [NSMutableArray array];
        id peerVal = dict[@"Peer"];
        if (peerVal && [peerVal isKindOfClass:[NSDictionary class]]) {
            NSDictionary *peerDict = (NSDictionary *)peerVal;
            for (id key in peerDict) {
                id pVal = peerDict[key];
                if (!pVal || ![pVal isKindOfClass:[NSDictionary class]]) continue;
                NSDictionary *p = (NSDictionary *)pVal;
                TSTailscalePeer *item = [[TSTailscalePeer alloc] init];
                
                id dnsName = p[@"DNSName"];
                id hostName = p[@"HostName"];
                if (dnsName && [dnsName isKindOfClass:[NSString class]] && [(NSString *)dnsName length] > 0) {
                    item.name = (NSString *)dnsName;
                } else if (hostName && [hostName isKindOfClass:[NSString class]]) {
                    item.name = (NSString *)hostName;
                } else if ([key isKindOfClass:[NSString class]]) {
                    item.name = (NSString *)key;
                } else {
                    item.name = @"Peer";
                }

                id pIpsVal = p[@"TailscaleIPs"];
                if (pIpsVal && [pIpsVal isKindOfClass:[NSArray class]]) {
                    NSArray *pIps = (NSArray *)pIpsVal;
                    item.ip = (pIps.count > 0 && [pIps.firstObject isKindOfClass:[NSString class]]) ? pIps.firstObject : @"--";
                } else {
                    item.ip = @"--";
                }

                id osVal = p[@"OS"];
                item.os = (osVal && [osVal isKindOfClass:[NSString class]]) ? (NSString *)osVal : @"Unknown";
                
                id onlineVal = p[@"Online"];
                item.online = (onlineVal && [onlineVal respondsToSelector:@selector(boolValue)]) ? [onlineVal boolValue] : NO;
                /* 官方 TaildropTarget 1 为可发送，5 为暂时离线但允许探测 */
                id target = p[@"TaildropTarget"];
                item.taildropAvailable = [target isKindOfClass:NSNumber.class] && ([target integerValue] == 1 || [target integerValue] == 5);
                /* 仅保留后台提供的原生 PeerAPI 接收地址 */
                id urls = p[@"PeerAPIURL"];
                item.peerAPIURLs = [urls isKindOfClass:NSArray.class] ? [urls filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id value, NSDictionary *bindings) { return [value isKindOfClass:NSString.class]; }]] : @[];
                
                [peers addObject:item];
            }
        }
        st.peers = peers;
        if (completion) completion(st, nil);
    }];
}

/* 只有真实收件接口可用才判定存储就绪，不把任意 HTTP 错误当成配置缺失 */
+ (void)checkTaildropForSocket:(NSString *)sockPath completion:(void(^)(BOOL, NSError *))completion {
    [self sendRequestToSocketPath:sockPath method:@"GET" path:@"/localapi/v0/files/" body:nil completion:^(NSData *data, NSInteger code, NSError *error) {
        if (error) { completion(NO, error); return; }
        NSString *body = [[NSString alloc] initWithData:data ?: [NSData data] encoding:NSUTF8StringEncoding] ?: @"";
        if (code == 500 && [[body stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] isEqualToString:@"Taildrop disabled; no storage directory"]) {
            completion(NO, nil);
            return;
        }
        if (code == 200) {
            NSError *parseError = nil;
            id files = [NSJSONSerialization JSONObjectWithData:data ?: [NSData data] options:NSJSONReadingFragmentsAllowed error:&parseError];
            if ([files isKindOfClass:NSArray.class] || files == NSNull.null) { completion(YES, nil); return; }
            completion(NO, parseError ?: [NSError errorWithDomain:@"TSLocalAPI" code:EINVAL userInfo:@{NSLocalizedDescriptionKey: @"收件存储返回了无效响应"}]);
            return;
        }
        completion(NO, [NSError errorWithDomain:@"TSLocalAPI" code:code userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"检查 Taildrop 存储失败 (HTTP %ld): %@", (long)code, body]}]);
    }];
}

/* 发起交互式登录请求并获取授权 URL */
+ (void)requestLoginUrlWithCompletion:(void(^)(NSString *authUrl, NSError *error))completion {
    [self requestLoginUrlForSocket:[self activeSocketPath] completion:completion];
}

/* 在固定会话中发起登录并等待 URL */
+ (void)requestLoginUrlForSocket:(NSString *)sockPath completion:(void(^)(NSString *authUrl, NSError *error))completion {
    [self sendRequestToSocketPath:sockPath method:@"POST" path:@"/localapi/v0/login-interactive" body:nil completion:^(NSData *respData, NSInteger statusCode, NSError *err) {
        if (err) {
            if (completion) completion(nil, err);
            return;
        }
        if (statusCode < 200 || statusCode >= 300) {
            NSString *bodyStr = respData ? [[NSString alloc] initWithData:respData encoding:NSUTF8StringEncoding] : @"";
            NSString *errMsg = [NSString stringWithFormat:@"login-interactive HTTP %ld: %@", (long)statusCode, bodyStr];
            if (completion) completion(nil, [NSError errorWithDomain:@"TSLocalAPI" code:statusCode userInfo:@{NSLocalizedDescriptionKey: errMsg}]);
            return;
        }

        /* 官方与远程控制面通信生成密钥通常需要 1~5 秒，启动平滑自适应轮询 */
        __block int attempts = 0;
        const int maxAttempts = 35;
        
        __block void (^pollBlock)(void) = nil;
        pollBlock = [^{
            attempts++;
            [self fetchStatusForSocket:sockPath completion:^(TSTailscaleStatus *status, NSError *fetchErr) {
                if (status && status.authUrl.length > 0) {
                    if (completion) completion(status.authUrl, nil);
                    pollBlock = nil;
                } else if (fetchErr && [fetchErr.domain isEqualToString:@"TSLocalAPI"] && (fetchErr.code == ENOENT || fetchErr.code == ECONNREFUSED)) {
                    if (completion) completion(nil, fetchErr);
                    pollBlock = nil;
                } else if (attempts < maxAttempts) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(300 * NSEC_PER_MSEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                        if (pollBlock) pollBlock();
                    });
                } else {
                    NSString *state = status.backendState ?: @"Unknown";
                    NSString *detail = [NSString stringWithFormat:@"获取授权URL超时 (状态: %@)", state];
                    if (completion) completion(nil, [NSError errorWithDomain:@"TSLocalAPI" code:ETIMEDOUT userInfo:@{NSLocalizedDescriptionKey: detail}]);
                    pollBlock = nil;
                }
            }];
        } copy];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(300 * NSEC_PER_MSEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            if (pollBlock) pollBlock();
        });
    }];
}

/* 使用 AuthKey 入网 (官方标准: POST /localapi/v0/start 带 ipn.Options.AuthKey) */
+ (void)loginWithAuthKey:(NSString *)authKey completion:(void(^)(BOOL success, NSString *msg))completion {
    if (!authKey || authKey.length == 0) {
        if (completion) completion(NO, @"AuthKey不能为空");
        return;
    }

    NSString *cleanKey = [authKey stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSDictionary *payload = @{
        @"AuthKey": cleanKey,
        @"UpdatePrefs": @{
            @"WantRunning": @(YES)
        }
    };
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];

    [self sendRequestToSocketPath:[self activeSocketPath] method:@"POST" path:@"/localapi/v0/start" body:bodyData completion:^(NSData *respData, NSInteger statusCode, NSError *err) {
        if (err) {
            if (completion) completion(NO, err.localizedDescription);
            return;
        }
        BOOL ok = (statusCode >= 200 && statusCode < 300);
        if (completion) completion(ok, [NSString stringWithFormat:@"HTTP %ld", (long)statusCode]);
    }];
}

/* 设置网络运行状态 (官方标准: POST /localapi/v0/start 带 UpdatePrefs.WantRunning) */
+ (void)setWantRunning:(BOOL)wantRunning completion:(void(^)(BOOL success, NSError *error))completion {
    NSDictionary *payload = @{
        @"UpdatePrefs": @{
            @"WantRunning": @(wantRunning)
        }
    };
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];

    [self sendRequestToSocketPath:[self activeSocketPath] method:@"POST" path:@"/localapi/v0/start" body:bodyData completion:^(NSData *respData, NSInteger statusCode, NSError *err) {
        if (err) {
            if (completion) completion(NO, err);
            return;
        }
        BOOL ok = (statusCode >= 200 && statusCode < 300);
        if (completion) completion(ok, nil);
    }];
}

/* 设置 MagicDNS 状态 (官方标准: POST /localapi/v0/start 带 UpdatePrefs.CorpDNS) */
+ (void)setMagicDns:(BOOL)enabled completion:(void(^)(BOOL success, NSError *error))completion {
    NSDictionary *payload = @{
        @"UpdatePrefs": @{
            @"CorpDNS": @(enabled)
        }
    };
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];

    [self sendRequestToSocketPath:[self activeSocketPath] method:@"POST" path:@"/localapi/v0/start" body:bodyData completion:^(NSData *respData, NSInteger statusCode, NSError *err) {
        if (err) {
            if (completion) completion(NO, err);
            return;
        }
        BOOL ok = (statusCode >= 200 && statusCode < 300);
        if (completion) completion(ok, nil);
    }];
}

/* 设置自定义协调服务器 (官方标准: POST /localapi/v0/start 带 UpdatePrefs.ControlURL) */
+ (void)setControlURL:(NSString *)controlUrl completion:(void(^)(BOOL success, NSError *error))completion {
    [self setControlURL:controlUrl socketPath:[self activeSocketPath] completion:completion];
}

/* 修改固定认证会话的协调服务器 */
+ (void)setControlURL:(NSString *)controlUrl socketPath:(NSString *)sockPath completion:(void(^)(BOOL success, NSError *error))completion {
    if (!controlUrl || controlUrl.length == 0) {
        if (completion) completion(NO, [NSError errorWithDomain:@"TSLocalAPI" code:EINVAL userInfo:@{NSLocalizedDescriptionKey:@"ControlURL is empty"}]);
        return;
    }
    NSString *cleanUrl = [controlUrl stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSDictionary *payload = @{
        @"UpdatePrefs": @{
            @"ControlURL": cleanUrl
        }
    };
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];

    [self sendRequestToSocketPath:sockPath method:@"POST" path:@"/localapi/v0/start" body:bodyData completion:^(NSData *respData, NSInteger statusCode, NSError *err) {
        if (err) {
            if (completion) completion(NO, err);
            return;
        }
        BOOL ok = (statusCode >= 200 && statusCode < 300);
        if (completion) completion(ok, nil);
    }];
}

/* 彻底注销账号与删除凭据 (Log Out) */
+ (void)logoutWithCompletion:(void(^)(BOOL success, NSError *error))completion {
    [self sendRequestToSocketPath:[self activeSocketPath] method:@"POST" path:@"/localapi/v0/logout" body:nil completion:^(NSData *respData, NSInteger statusCode, NSError *err) {
        BOOL ok = (err == nil && statusCode >= 200 && statusCode < 300);
        if (completion) completion(ok, err);
    }];
}

/* 官方原生多账户 Profiles 管理 */
+ (void)listProfilesWithCompletion:(void(^)(NSArray<TSTailscaleProfile *> *profiles, NSError *error))completion {
    [self listProfilesForSocket:[self activeSocketPath] completion:completion];
}

/* 同步账户列表及真实当前账户 */
+ (void)listProfilesForSocket:(NSString *)sockPath completion:(void(^)(NSArray<TSTailscaleProfile *> *profiles, NSError *error))completion {
    [self sendRequestToSocketPath:sockPath method:@"GET" path:@"/localapi/v0/profiles/" body:nil completion:^(NSData *respData, NSInteger statusCode, NSError *err) {
        if (err || !respData || statusCode != 200) {
            if (completion) completion(@[], err ?: [NSError errorWithDomain:@"TSLocalAPI" code:statusCode userInfo:nil]);
            return;
        }

        NSError *jsonErr = nil;
        NSArray *arr = [NSJSONSerialization JSONObjectWithData:respData options:0 error:&jsonErr];
        if (![arr isKindOfClass:[NSArray class]]) {
            if (completion) completion(@[], jsonErr ?: [NSError errorWithDomain:@"TSLocalAPI" code:EINVAL userInfo:nil]);
            return;
        }

        NSMutableArray<TSTailscaleProfile *> *result = [NSMutableArray array];
        for (id item in arr) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *dict = (NSDictionary *)item;
            TSTailscaleProfile *prof = [[TSTailscaleProfile alloc] init];
            id idVal = dict[@"ID"];
            prof.profileId = (idVal && [idVal isKindOfClass:[NSString class]]) ? (NSString *)idVal : @"";
            prof.serverUrl = [dict[@"ControlURL"] isKindOfClass:NSString.class] ? dict[@"ControlURL"] : @"";
            prof.nodeID = [dict[@"NodeID"] isKindOfClass:NSString.class] ? dict[@"NodeID"] : @"";
            
            id nameVal = dict[@"Name"];
            id user = dict[@"UserProfile"];
            if ([user isKindOfClass:[NSDictionary class]] && [user[@"LoginName"] isKindOfClass:[NSString class]] && [user[@"LoginName"] length] > 0) {
                nameVal = user[@"LoginName"];
            }
            prof.name = (nameVal && [nameVal isKindOfClass:[NSString class]]) ? (NSString *)nameVal : @"";
            
            id netProfVal = dict[@"NetworkProfile"];
            if (netProfVal && [netProfVal isKindOfClass:[NSDictionary class]]) {
                NSDictionary *netProf = (NSDictionary *)netProfVal;
                id domain = netProf[@"DomainName"];
                id display = netProf[@"DisplayName"];
                if (domain && [domain isKindOfClass:[NSString class]] && [(NSString *)domain length] > 0) {
                    prof.tailnet = (NSString *)domain;
                } else if (display && [display isKindOfClass:[NSString class]] && [(NSString *)display length] > 0) {
                    prof.tailnet = (NSString *)display;
                } else {
                    prof.tailnet = @"tailnet";
                }
            } else {
                prof.tailnet = @"tailnet";
            }
            [result addObject:prof];
        }
        [self sendRequestToSocketPath:sockPath method:@"GET" path:@"/localapi/v0/profiles/current" body:nil completion:^(NSData *data, NSInteger code, NSError *currentError) {
            NSError *parseError = nil;
            id current = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseError] : nil;
            if (currentError || code != 200 || ![current isKindOfClass:[NSDictionary class]]) {
                if (completion) completion(@[], currentError ?: parseError ?: [NSError errorWithDomain:@"TSLocalAPI" code:code == 200 ? EINVAL : code userInfo:nil]);
                return;
            }
            for (TSTailscaleProfile *profile in result) {
                profile.isCurrent = profile.profileId.length > 0 && [profile.profileId isEqual:current[@"ID"]];
            }
            if (completion) completion(result, nil);
        }];
    }];
}

+ (void)newProfileWithCompletion:(void(^)(BOOL success, NSError *error))completion {
    [self sendRequestToSocketPath:[self activeSocketPath] method:@"PUT" path:@"/localapi/v0/profiles/" body:nil completion:^(NSData *respData, NSInteger statusCode, NSError *err) {
        BOOL ok = (err == nil && statusCode >= 200 && statusCode < 300);
        if (completion) completion(ok, err);
    }];
}

+ (void)switchProfile:(NSString *)profileId completion:(void(^)(BOOL success, NSError *error))completion {
    if (!profileId || profileId.length == 0) {
        if (completion) completion(NO, nil);
        return;
    }
    NSString *path = [NSString stringWithFormat:@"/localapi/v0/profiles/%@", profileId];
    [self sendRequestToSocketPath:[self activeSocketPath] method:@"POST" path:path body:nil completion:^(NSData *respData, NSInteger statusCode, NSError *err) {
        BOOL ok = (err == nil && statusCode >= 200 && statusCode < 300);
        if (completion) completion(ok, err);
    }];
}

+ (void)deleteProfile:(NSString *)profileId completion:(void(^)(BOOL success, NSError *error))completion {
    if (!profileId || profileId.length == 0) {
        if (completion) completion(NO, nil);
        return;
    }
    NSString *path = [NSString stringWithFormat:@"/localapi/v0/profiles/%@", profileId];
    [self sendRequestToSocketPath:[self activeSocketPath] method:@"DELETE" path:path body:nil completion:^(NSData *respData, NSInteger statusCode, NSError *err) {
        BOOL ok = (err == nil && statusCode >= 200 && statusCode < 300);
        if (completion) completion(ok, err);
    }];
}

@end
