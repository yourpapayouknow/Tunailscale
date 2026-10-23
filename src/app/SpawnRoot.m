/*
 * SpawnRoot.m - TrollStore 提权进程启动实现
 */

#import "SpawnRoot.h"
#include <spawn.h>
#include <dlfcn.h>
#include <sys/wait.h>
#include <sys/stat.h>

#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1

typedef int (*posix_spawnattr_set_persona_np_t)(const posix_spawnattr_t * __restrict, uid_t, uint32_t);
typedef int (*posix_spawnattr_set_persona_uid_np_t)(const posix_spawnattr_t * __restrict, uid_t);
typedef int (*posix_spawnattr_set_persona_gid_np_t)(const posix_spawnattr_t * __restrict, uid_t);

@implementation SpawnRoot

+ (int)spawnHelperBinary:(NSString *)binaryPath
                     pid:(pid_t *)outPid
                  errNum:(int *)outErrno
                  errMsg:(NSString **)outErrMsg {
    return [self spawnHelperBinary:binaryPath args:@[] environment:@{} root:YES logPath:@"/tmp/tailscaled.log" pid:outPid errNum:outErrno errMsg:outErrMsg];
}

+ (int)spawnHelperBinary:(NSString *)binaryPath
                    args:(NSArray<NSString *> *)arguments
             environment:(NSDictionary<NSString *, NSString *> *)environment
                    root:(BOOL)root
                 logPath:(NSString *)logPath
                     pid:(pid_t *)outPid
                  errNum:(int *)outErrno
                  errMsg:(NSString **)outErrMsg {
    if (!binaryPath || ![[NSFileManager defaultManager] fileExistsAtPath:binaryPath]) {
        if (outErrno) *outErrno = ENOENT;
        if (outErrMsg) *outErrMsg = [NSString stringWithFormat:@"Binary not found at path: %@", binaryPath];
        return -1;
    }

    posix_spawnattr_t attr;
    int ret = posix_spawnattr_init(&attr);
    if (ret != 0) {
        if (outErrno) *outErrno = ret;
        if (outErrMsg) *outErrMsg = [NSString stringWithFormat:@"posix_spawnattr_init failed: %s", strerror(ret)];
        return ret;
    }

    /* 建立独立进程组；此属性不提供 iOS 后台保活保证 */
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);
    posix_spawnattr_setpgroup(&attr, 0);

    /* 动态获取 Persona 属性设置函数指针 (TrollStore 规范) */
    posix_spawnattr_set_persona_np_t set_persona = (posix_spawnattr_set_persona_np_t)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_np");
    posix_spawnattr_set_persona_uid_np_t set_persona_uid = (posix_spawnattr_set_persona_uid_np_t)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_uid_np");
    posix_spawnattr_set_persona_gid_np_t set_persona_gid = (posix_spawnattr_set_persona_gid_np_t)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_gid_np");

    if (root && set_persona && set_persona_uid && set_persona_gid) {
        set_persona(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
        set_persona_uid(&attr, 0);
        set_persona_gid(&attr, 0);
    }

    /* 组装命令行参数数组 */
    NSUInteger argc = 1 + (arguments ? arguments.count : 0);
    const char **argv = (const char **)malloc(sizeof(char *) * (argc + 1));
    argv[0] = [binaryPath UTF8String];
    for (NSUInteger i = 0; i < (arguments ? arguments.count : 0); i++) {
        argv[1 + i] = [arguments[i] UTF8String];
    }
    argv[argc] = NULL;

    /* 为 Root 守护进程与 CLI 注入标准系统环境 */
    NSMutableDictionary<NSString *, NSString *> *rootEnvironment = [@{
        @"PATH": @"/var/run:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        @"HOME": root ? @"/var/root" : NSHomeDirectory(),
        @"USER": root ? @"root" : NSUserName(),
        @"TMPDIR": root ? @"/tmp" : NSTemporaryDirectory()
    } mutableCopy];
    [rootEnvironment addEntriesFromDictionary:environment];
    __attribute__((objc_precise_lifetime)) NSMutableArray<NSString *> *entries = [NSMutableArray array];
    for (NSString *key in rootEnvironment) {
        [entries addObject:[NSString stringWithFormat:@"%@=%@", key, rootEnvironment[key]]];
    }
    const char **root_env = calloc(entries.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < entries.count; i++) root_env[i] = entries[i].UTF8String;

    /* 写入本轮守护进程日志，避免旧启动记录干扰诊断 */
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    int logFlags = O_WRONLY | O_CREAT | O_APPEND | ([[binaryPath lastPathComponent] isEqualToString:@"tailscaled"] ? O_TRUNC : 0);
    posix_spawn_file_actions_addopen(&actions, 1, logPath.fileSystemRepresentation, logFlags, root ? 0644 : 0600);
    posix_spawn_file_actions_adddup2(&actions, 1, 2);

    pid_t pid = 0;
    ret = posix_spawn(&pid, [binaryPath UTF8String], &actions, &attr, (char * const *)argv, (char * const *)root_env);
    free(argv);
    free(root_env);
    posix_spawnattr_destroy(&attr);
    posix_spawn_file_actions_destroy(&actions);

    if (ret != 0) {
        if (outErrno) *outErrno = ret;
        if (outErrMsg) *outErrMsg = [NSString stringWithFormat:@"posix_spawn failed (%d): %s", ret, strerror(ret)];
        return ret;
    }

    if (outPid) *outPid = pid;
    if (outErrno) *outErrno = 0;
    if (outErrMsg) *outErrMsg = @"Success";

    return 0;
}

+ (int)chmodPath:(NSString *)path mode:(mode_t)mode {
    if (!path || path.length == 0) return -1;
    int ret = chmod([path UTF8String], mode);
    if (ret == 0) return 0;

    NSString *helperPath = [[NSBundle mainBundle] pathForResource:@"tsprobe-helper" ofType:nil];
    if (!helperPath) return ENOENT;

    pid_t p = 0;
    int err = 0;
    NSString *errStr = nil;
    NSString *modeStr = [NSString stringWithFormat:@"%o", mode];
    ret = [self spawnHelperBinary:helperPath args:@[@"chmod", modeStr, path] environment:@{} root:YES logPath:@"/tmp/tailscaled.log" pid:&p errNum:&err errMsg:&errStr];
    if (ret != 0) return ret;

    int status = 0;
    if (waitpid(p, &status, 0) < 0) return errno;
    return WIFEXITED(status) ? WEXITSTATUS(status) : ECHILD;
}

+ (int)terminateDaemonNamed:(NSString *)processName socketPath:(NSString *)sockPath {
    if (!processName || processName.length == 0) return EINVAL;
    NSString *helperPath = [[NSBundle mainBundle] pathForResource:@"tsprobe-helper" ofType:nil];
    if (!helperPath) return ENOENT;

    pid_t p = 0;
    int err = 0;
    NSString *errStr = nil;
    int ret = [self spawnHelperBinary:helperPath args:@[@"terminate", processName, sockPath ?: @""] environment:@{} root:YES logPath:@"/tmp/tailscaled.log" pid:&p errNum:&err errMsg:&errStr];
    if (ret != 0) return ret;

    int status = 0;
    if (waitpid(p, &status, 0) < 0) return errno;
    return WIFEXITED(status) ? WEXITSTATUS(status) : ECHILD;
}

/* waitpid 验证子进程归属，避免误杀其他守护进程或复用的 PID */
+ (int)terminateChild:(pid_t)pid {
    if (pid <= 1) return EINVAL;
    int status = 0;
    pid_t result;
    do { result = waitpid(pid, &status, WNOHANG); } while (result < 0 && errno == EINTR);
    if (result == pid) return 0;
    if (result < 0) return errno;
    if (kill(pid, SIGKILL) != 0 && errno != ESRCH) return errno;
    do { result = waitpid(pid, &status, 0); } while (result < 0 && errno == EINTR);
    return result == pid ? 0 : errno;
}

/* 非阻塞读取退出码，所有轮询与取消由调用方串行执行 */
+ (int)pollChild:(pid_t)pid {
    if (pid <= 1) return -EINVAL;
    int status = 0;
    pid_t result;
    do { result = waitpid(pid, &status, WNOHANG); } while (result < 0 && errno == EINTR);
    if (result == 0) return -EAGAIN;
    if (result < 0) return -errno;
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return -EAGAIN;
}

@end
