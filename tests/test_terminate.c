/* 使用受控进程表验证清理范围，不调用真实 kill 或 unlink */
#include <assert.h>
#include <errno.h>
#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <signal.h>
#include <unistd.h>
#include <os/log.h>

static int killed[16], count, unlinked, inspectError;
static bool exited;
static const char *target = "/tmp/our-main.sock";
static const char *binary = "/Apps/TSNativeTailscale.app/tailscaled";

/* 伪造本 App helper 的可执行路径 */
static int tstexec(char *path, uint32_t *size) {
    const char *value = "/Apps/TSNativeTailscale.app/tsprobe-helper";
    if (*size <= strlen(value)) return -1;
    strcpy(path, value);
    return 0;
}

/* 保留合成路径，不访问真实磁盘 */
static char *tstrlpth(const char *path, char *resolved) { return strcpy(resolved, path); }

/* 提供同名进程、不同 App、独立认证与相似 socket */
static int tstsysctl(int *mib, u_int len, void *out, size_t *size, void *value, size_t valueSize) {
    (void)len; (void)value; (void)valueSize;
    if (mib[1] == KERN_ARGMAX) { *(int *)out = 4096; *size = sizeof(int); return 0; }
    if (mib[1] == KERN_PROCARGS2) {
        if (mib[2] == 6 || (mib[2] == 2 && exited)) { errno = EINVAL; return -1; }
        if (mib[2] == 4 && inspectError) { errno = inspectError; return -1; }
        char args[4096] = {0};
        int argc = 2;
        memcpy(args, &argc, sizeof(argc));
        const char *exec = mib[2] == 3 ? "/Apps/Other.app/tailscaled" : binary;
        size_t cursor = sizeof(argc);
        memcpy(args + cursor, exec, strlen(exec) + 1); cursor += strlen(exec) + 2;
        memcpy(args + cursor, exec, strlen(exec) + 1); cursor += strlen(exec) + 1;
        const char *socket = mib[2] == 4 ? "/tmp/draft.sock" : mib[2] == 5 ? "/tmp/our-main.sock.extra" : target;
        cursor += snprintf(args + cursor, sizeof(args) - cursor, "--socket=%s", socket) + 1;
        if (out) { assert(*size >= cursor); memcpy(out, args, cursor); }
        *size = cursor;
        return 0;
    }
    struct kinfo_proc procs[5] = {0};
    for (int i = 0; i < 5; i++) { strcpy(procs[i].kp_proc.p_comm, "tailscaled"); procs[i].kp_proc.p_pid = i + 2; }
    procs[4].kp_proc.p_stat = SZOMB;
    if (exited) procs[0].kp_proc.p_stat = SZOMB;
    if (out) memcpy(out, procs, sizeof(procs));
    *size = sizeof(procs);
    return 0;
}

/* 记录拟终止的 PID，绝不发送系统信号 */
static int tstkill(pid_t pid, int sig) { assert(sig == SIGKILL); killed[count++] = pid; exited = true; return 0; }
/* 只核对合成 socket，不删除真实文件 */
static int tstunlink(const char *path) { assert(strcmp(path, target) == 0); unlinked++; return 0; }
/* 模拟特权身份 */
static uid_t tstuid(void) { return 0; }
/* 固定测试进程标识 */
static pid_t tstpid(void) { return 99; }
/* 跳过模拟终止后的等待 */
static int tstwait(useconds_t value) { (void)value; return 0; }

#define sysctl tstsysctl
#define kill tstkill
#define unlink tstunlink
#define geteuid tstuid
#define getpid tstpid
#define usleep tstwait
#define _NSGetExecutablePath tstexec
#define realpath tstrlpth
static int trmproc(const char *, const char *);

/* 只允许清理本 App、匹配 socket 的一个进程 */
int main(void) {
    assert(trmproc("tailscaled", target) == 0);
    assert(count == 1 && killed[0] == 2);
    assert(trmproc("tailscaled", target) == 0 && count == 1 && unlinked == 2);
    inspectError = EPERM;
    assert(trmproc("tailscaled", target) == EPERM && count == 1 && unlinked == 2);
    puts("PASS: repeated cleanup skips exited processes, preserves inspection failures and excludes other apps, isolated authentication and similar socket names");
}
