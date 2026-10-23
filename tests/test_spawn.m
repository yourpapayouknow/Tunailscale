/* 拦截实际 spawn，验证真实 SpawnRoot 的参数和环境且不启动特权进程 */
#import "../src/app/SpawnRoot.h"
#include <spawn.h>
#include <assert.h>
#include <dlfcn.h>
#include <signal.h>
#include <unistd.h>
#include <sys/file.h>

static bool expectedHTTPS;
static bool expectedArgument;
static int calls;
static bool expectedRoot = true;

/* 检查传给内核的 argv/envp */
int ts_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *actions,
             const posix_spawnattr_t *attr, char *const argv[], char *const envp[]) {
    (void)actions;
    (void)attr;
    assert(strcmp(path, "/usr/bin/true") == 0);
    assert(strcmp(argv[0], path) == 0);
    if (expectedArgument) assert(argv[1] && strcmp(argv[1], "--version") == 0 && !argv[2]);
    else assert(!argv[1]);
    bool home = false, user = false, tmp = false, searchPath = false, https = false;
    int count = 0;
    for (; envp[count]; count++) {
        assert(count < 8);
        home |= strcmp(envp[count], [[@"HOME=" stringByAppendingString:expectedRoot ? @"/var/root" : NSHomeDirectory()] UTF8String]) == 0;
        user |= strcmp(envp[count], [[@"USER=" stringByAppendingString:expectedRoot ? @"root" : NSUserName()] UTF8String]) == 0;
        tmp |= strcmp(envp[count], [[@"TMPDIR=" stringByAppendingString:expectedRoot ? @"/tmp" : NSTemporaryDirectory()] UTF8String]) == 0;
        searchPath |= strncmp(envp[count], "PATH=/var/run:", 14) == 0;
        https |= strcmp(envp[count], "TS_FORCE_NOISE_443=1") == 0;
    }
    assert(home && user && tmp && searchPath && https == expectedHTTPS);
    assert(count == (expectedHTTPS ? 5 : 4));
    *pid = 42;
    calls++;
    return 0;
}

/* 检查官方服务参数、普通 helper 环境和缺失二进制错误 */
int main(void) {
    @autoreleasepool {
        pid_t pid = 0;
        int error = 0;
        NSString *message = nil;
        expectedHTTPS = expectedArgument = true;
        assert([SpawnRoot spawnHelperBinary:@"/usr/bin/true" args:@[@"--version"]
                     environment:@{@"TS_FORCE_NOISE_443": @"1"} root:YES logPath:@"/tmp/test-spawn.log" pid:&pid errNum:&error errMsg:&message] == 0);
        assert(pid == 42 && error == 0 && calls == 1);
        expectedHTTPS = expectedArgument = false;
        assert([SpawnRoot spawnHelperBinary:@"/usr/bin/true" pid:&pid errNum:&error errMsg:&message] == 0);
        assert(calls == 2);
        expectedRoot = false;
        assert([SpawnRoot spawnHelperBinary:@"/usr/bin/true" args:@[] environment:@{} root:NO logPath:@"/tmp/test-spawn.log" pid:&pid errNum:&error errMsg:&message] == 0);
        assert(calls == 3);
        assert([SpawnRoot spawnHelperBinary:@"/missing-test-binary" pid:&pid errNum:&error errMsg:&message] == -1);
        assert(error == ENOENT && calls == 3);
        assert([SpawnRoot terminateChild:0] == EINVAL);
        assert([SpawnRoot terminateChild:getpid()] == ECHILD);
        // 实际创建普通用户子进程，确认回收后不能再次按复用 PID 发送信号
        typedef int (*spawn_fn)(pid_t *, const char *, const posix_spawn_file_actions_t *, const posix_spawnattr_t *, char *const[], char *const[]);
        spawn_fn realSpawn = (spawn_fn)dlsym(RTLD_DEFAULT, "posix_spawn");
        char *childArgs[] = {"/bin/sleep", "30", NULL};
        char *childEnv[] = {NULL};
        assert(realSpawn && realSpawn(&pid, "/bin/sleep", NULL, NULL, childArgs, childEnv) == 0);
        assert([SpawnRoot pollChild:0] == -EINVAL);
        assert([SpawnRoot pollChild:getpid()] == -ECHILD);
        assert([SpawnRoot pollChild:pid] == -EAGAIN);
        assert([SpawnRoot terminateChild:pid] == 0);
        assert([SpawnRoot terminateChild:pid] == ECHILD);
        assert(kill(pid, 0) == -1 && errno == ESRCH);
        char *exitArgs[] = {"/usr/bin/true", NULL};
        assert(realSpawn(&pid, "/usr/bin/true", NULL, NULL, exitArgs, childEnv) == 0);
        int code;
        do { code = [SpawnRoot pollChild:pid]; if (code == -EAGAIN) usleep(10000); } while (code == -EAGAIN);
        assert(code == 0 && [SpawnRoot pollChild:pid] == -ECHILD);
        // 父 App 退出后 CLI 持有的共享锁仍须阻止切换账户
        NSString *lockPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
        int inherited = open(lockPath.fileSystemRepresentation, O_CREAT | O_RDWR, 0600);
        assert(inherited >= 0 && flock(inherited, LOCK_SH | LOCK_NB) == 0);
        assert(realSpawn(&pid, "/bin/sleep", NULL, NULL, childArgs, childEnv) == 0);
        close(inherited);
        int switching = open(lockPath.fileSystemRepresentation, O_RDWR);
        assert(switching >= 0 && flock(switching, LOCK_EX | LOCK_NB) == -1 && errno == EWOULDBLOCK);
        assert([SpawnRoot terminateChild:pid] == 0);
        assert(flock(switching, LOCK_EX | LOCK_NB) == 0);
        close(switching);
        unlink(lockPath.fileSystemRepresentation);
        puts("PASS: native SpawnRoot argv, root environment, HTTPS override, helper isolation, missing binary");
    }
}
