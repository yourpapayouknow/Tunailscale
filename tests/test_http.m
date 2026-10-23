/* 通过独立 Unix socket 验证真实 HTTP 边界，不连接实际后台 */
#import "../src/tailscale/TSLocalAPI.h"
#include <assert.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

@interface TSLocalAPI (HTTPAudit)
+ (void)sendRequestToSocketPath:(NSString *)socket method:(NSString *)method path:(NSString *)path body:(NSData *)body completion:(void(^)(NSData *, NSInteger, NSError *))completion;
@end

/* 每次使用独立监听端点和受控字节响应 */
static BOOL exchange(NSString *wire, BOOL valid, NSString *expected) {
    NSString *path = [@"/tmp/ts-http-" stringByAppendingString:NSUUID.UUID.UUIDString];
    int server = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un addr = {0}; addr.sun_family = AF_UNIX;
    strlcpy(addr.sun_path, path.UTF8String, sizeof(addr.sun_path));
    assert(bind(server, (struct sockaddr *)&addr, sizeof(addr)) == 0 && listen(server, 1) == 0);
    dispatch_group_t group = dispatch_group_create();
    dispatch_group_async(group, dispatch_get_global_queue(0, 0), ^{
        int client = accept(server, NULL, NULL); assert(client >= 0);
        char request[1024]; assert(read(client, request, sizeof(request)) > 0);
        NSData *bytes = [wire dataUsingEncoding:NSUTF8StringEncoding];
        size_t sent = 0;
        while (sent < bytes.length) { ssize_t n = write(client, (const char *)bytes.bytes + sent, bytes.length - sent); assert(n > 0); sent += n; }
        close(client);
    });
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block BOOL result = NO;
    [TSLocalAPI sendRequestToSocketPath:path method:@"GET" path:@"/localapi/v0/status" body:nil completion:^(NSData *data, NSInteger code, NSError *error) {
        result = valid ? (!error && code == 200 && [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] isEqualToString:expected]) : (error != nil);
        dispatch_semaphore_signal(done);
    }];
    assert(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0);
    assert(dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
    close(server); assert(unlink(path.UTF8String) == 0);
    return result;
}

/* 覆盖完整、截断、非法状态行及分块结束边界 */
int main(void) {
    @autoreleasepool {
        BOOL good = YES;
        good &= exchange(@"HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\n{}", YES, @"{}");
        good &= exchange(@"HTTP/1.0 200 OK\r\nContent-Length: 4\r\n\r\n{}", NO, nil);
        good &= exchange(@"garbage\r\n\r\n{}", NO, nil);
        good &= exchange(@"HTTP/1.0 200 OK\r\nContent-Length: -2\r\n\r\n{}", NO, nil);
        good &= exchange(@"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n0\r\n\r\n", YES, @"{}");
        good &= exchange(@"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n", NO, nil);
        good &= exchange(@"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n", YES, @"");
        assert(good);
        puts("PASS: bounded HTTP headers, status, content length, complete and truncated chunks");
    }
}
