/*
 * test_localapi.m - Tailscale LocalAPI 自动化集成测试套件
 * 针对真实运行的 tailscaled Unix Socket 执行端到端接口验证与 SIGPIPE 容错测试
 */

#import <Foundation/Foundation.h>
#import "../src/tailscale/TSLocalAPI.h"

static int gPassedTests = 0;
static int gFailedTests = 0;

#define ASSERT_TEST(cond, name) do { \
    if (cond) { \
        printf("[PASS] %s\n", (name)); \
        gPassedTests++; \
    } else { \
        printf("[FAIL] %s\n", (name)); \
        gFailedTests++; \
    } \
} while(0)

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSString *sockPath = @"/tmp/test-ts.sock";
        if (argc > 1) {
            sockPath = [NSString stringWithUTF8String:argv[1]];
        }
        printf("=========================================\n");
        printf("Starting TSLocalAPI Integration Test Suite\n");
        printf("Target Socket: %s\n", [sockPath UTF8String]);
        printf("=========================================\n");

        [TSLocalAPI setCustomSocketPath:sockPath];

        dispatch_semaphore_t sem = dispatch_semaphore_create(0);

        // Test 1: fetchStatus
        printf("\n--- Test 1: fetchStatus ---\n");
        __block BOOL t1Success = NO;
        __block NSString *t1State = nil;
        [TSLocalAPI fetchStatusWithCompletion:^(TSTailscaleStatus *status, NSError *error) {
            if (error == nil && status != nil) {
                t1Success = YES;
                t1State = status.backendState;
                printf("  BackendState: %s, SelfIP: %s\n", [status.backendState UTF8String], [status.selfIp UTF8String]);
            } else {
                printf("  Error: %s\n", [[error localizedDescription] UTF8String]);
            }
            dispatch_semaphore_signal(sem);
        }];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
        ASSERT_TEST(t1Success && t1State.length > 0, "Test 1: fetchStatus returned valid status");

        // Test 2: setWantRunning (YES & NO)
        printf("\n--- Test 2: setWantRunning ---\n");
        __block BOOL t2Success = NO;
        [TSLocalAPI setWantRunning:NO completion:^(BOOL success, NSError *error) {
            t2Success = success;
            if (!success) {
                printf("  Error: %s\n", [[error localizedDescription] UTF8String]);
            }
            dispatch_semaphore_signal(sem);
        }];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
        ASSERT_TEST(t2Success, "Test 2: setWantRunning:NO succeeded (204 No Content accepted)");

        // Test 3: setControlURL
        printf("\n--- Test 3: setControlURL ---\n");
        __block BOOL t3Success = NO;
        [TSLocalAPI setControlURL:@"https://headscale.example.com" completion:^(BOOL success, NSError *error) {
            t3Success = success;
            if (!success) {
                printf("  Error: %s\n", [[error localizedDescription] UTF8String]);
            }
            dispatch_semaphore_signal(sem);
        }];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
        ASSERT_TEST(t3Success, "Test 3: setControlURL succeeded via /start endpoint");

        // Test 4: setMagicDns
        printf("\n--- Test 4: setMagicDns ---\n");
        __block BOOL t4Success = NO;
        [TSLocalAPI setMagicDns:YES completion:^(BOOL success, NSError *error) {
            t4Success = success;
            if (!success) {
                printf("  Error: %s\n", [[error localizedDescription] UTF8String]);
            }
            dispatch_semaphore_signal(sem);
        }];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
        ASSERT_TEST(t4Success, "Test 4: setMagicDns:YES succeeded via /start endpoint");

        // Test 5: listProfiles
        printf("\n--- Test 5: listProfiles ---\n");
        __block BOOL t5Success = NO;
        __block NSUInteger t5Count = 0;
        [TSLocalAPI listProfilesWithCompletion:^(NSArray<TSTailscaleProfile *> *profiles, NSError *error) {
            if (error == nil && profiles != nil) {
                t5Success = YES;
                t5Count = profiles.count;
                printf("  Profiles found: %lu\n", (unsigned long)profiles.count);
                for (TSTailscaleProfile *p in profiles) {
                    printf("    Profile ID: %s, Name: %s, Tailnet: %s\n", [p.profileId UTF8String], [p.name UTF8String], [p.tailnet UTF8String]);
                }
            } else {
                printf("  Error: %s\n", [[error localizedDescription] UTF8String]);
            }
            dispatch_semaphore_signal(sem);
        }];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
        ASSERT_TEST(t5Success, "Test 5: listProfiles returned successfully");

        // Test 6: newProfile
        printf("\n--- Test 6: newProfile ---\n");
        __block BOOL t6Success = NO;
        [TSLocalAPI newProfileWithCompletion:^(BOOL success, NSError *error) {
            t6Success = success;
            if (!success) {
                printf("  Error: %s\n", [[error localizedDescription] UTF8String]);
            }
            dispatch_semaphore_signal(sem);
        }];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
        ASSERT_TEST(t6Success, "Test 6: newProfile created via PUT /profiles/");

        // Test 7: logout
        printf("\n--- Test 7: logout ---\n");
        __block BOOL t7Success = NO;
        [TSLocalAPI logoutWithCompletion:^(BOOL success, NSError *error) {
            t7Success = success;
            if (!success) {
                printf("  Error: %s\n", [[error localizedDescription] UTF8String]);
            }
            dispatch_semaphore_signal(sem);
        }];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
        ASSERT_TEST(t7Success, "Test 7: logout succeeded via POST /logout (204 No Content accepted)");

        // Test 8: Empty key rejection validation
        printf("\n--- Test 8: Empty AuthKey validation ---\n");
        __block BOOL t8EmptyRejected = NO;
        [TSLocalAPI loginWithAuthKey:@"" completion:^(BOOL success, NSString *msg) {
            if (!success) {
                t8EmptyRejected = YES;
                printf("  Correctly rejected empty AuthKey: %s\n", [msg UTF8String]);
            }
            dispatch_semaphore_signal(sem);
        }];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
        ASSERT_TEST(t8EmptyRejected, "Test 8: loginWithAuthKey correctly rejects empty string");

        // Test 9: Broken Socket & SIGPIPE Resiliency
        printf("\n--- Test 9: Non-existent socket error handling (SIGPIPE test) ---\n");
        [TSLocalAPI setCustomSocketPath:@"/tmp/non-existent-test-ts.sock"];
        __block BOOL t9HandledSafely = NO;
        [TSLocalAPI fetchStatusWithCompletion:^(TSTailscaleStatus *status, NSError *error) {
            if (error != nil) {
                t9HandledSafely = YES;
                printf("  Safely returned error without crash: %s\n", [[error localizedDescription] UTF8String]);
            }
            dispatch_semaphore_signal(sem);
        }];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
        ASSERT_TEST(t9HandledSafely, "Test 9: Broken socket handled safely without crash or SIGPIPE termination");

        // Test 10: Real interactive login and AuthURL generation
        printf("\n--- Test 10: Real requestLoginUrlWithCompletion (Wait for auth URL) ---\n");
        [TSLocalAPI setCustomSocketPath:sockPath];
        __block BOOL t10Success = NO;
        __block NSString *t10Url = nil;
        [TSLocalAPI requestLoginUrlWithCompletion:^(NSString *authUrl, NSError *error) {
            if (error == nil && authUrl != nil && [authUrl hasPrefix:@"https://"]) {
                t10Success = YES;
                t10Url = authUrl;
                printf("  Successfully received real AuthURL: %s\n", [authUrl UTF8String]);
            } else {
                printf("  Failed or timeout: %s\n", [[error localizedDescription] UTF8String]);
            }
            dispatch_semaphore_signal(sem);
        }];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC));
        ASSERT_TEST(t10Success && t10Url.length > 0, "Test 10: requestLoginUrl successfully polled and retrieved valid AuthURL");

        printf("\n=========================================\n");
        printf("Test Summary: %d PASSED, %d FAILED\n", gPassedTests, gFailedTests);
        printf("=========================================\n");

        if (gFailedTests > 0) {
            exit(1);
        }
    }
    return 0;
}
