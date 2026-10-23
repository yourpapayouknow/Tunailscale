/* 只读取本测试进程的真实 Darwin 参数，不发送信号或操作后台 */
#include <assert.h>
#include <errno.h>
#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <unistd.h>
#include <mach-o/dyld.h>
#include <os/log.h>
static int prcmatch(pid_t, const char *, const char *, bool *);

/* 验证内核参数格式、路径别名与两种官方参数形式 */
int main(void) {
    char path[PATH_MAX], binary[PATH_MAX]; uint32_t size = sizeof(path);
    assert(_NSGetExecutablePath(path, &size) == 0 && realpath(path, binary));
    bool matches = false;
    assert(prcmatch(getpid(), binary, "/tmp/audit-main.sock", &matches) == 0 && matches);
    assert(prcmatch(getpid(), binary, "/tmp/audit-main.sock.extra", &matches) == 0 && !matches);
    assert(prcmatch(getpid(), "/different/app/tailscaled", "/tmp/audit-main.sock", &matches) == 0 && !matches);
    /* 保留自己的已退出子进程，核验真实内核的僵尸参数错误 */
    pid_t child = fork();
    assert(child >= 0);
    if (child == 0) _exit(0);
    struct kinfo_proc process = {0};
    int mib[] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, child};
    for (int i = 0; i < 100 && process.kp_proc.p_stat != SZOMB; i++) {
        size_t length = sizeof(process);
        assert(sysctl(mib, 4, &process, &length, NULL, 0) == 0);
        usleep(1000);
    }
    int error = prcmatch(child, binary, "/tmp/audit-main.sock", &matches);
    int status = 0;
    assert(waitpid(child, &status, 0) == child);
    printf("Darwin exited-child evidence: state=%d errno=%d\n", process.kp_proc.p_stat, error);
    assert(process.kp_proc.p_stat == SZOMB && error == EINVAL && !matches);
    puts("PASS: real Darwin argv, canonical executable identity and exact socket matching");
}
