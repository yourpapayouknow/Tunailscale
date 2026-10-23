/*
 * tsprobe_helper.c - TrollStore 原生 root helper 守护进程
 */

#include "../common/head.h"
#include "../common/probe_protocol.h"
#include "../common/utun_sys.h"
#include <sys/un.h>
#include <mach-o/dyld.h>
#include <limits.h>
#include <os/log.h>

#define HELPER_LOG_PATH "/tmp/tsprobe_helper.log"
#define HELPER_UNIX_SOCK "/tmp/tsprobe.sock"

static int g_utun_fd = -1;
static char g_ifname[PROBE_IFNAME_MAX] = {0};
static char g_routed_ip[64] = {0};
static time_t g_start_time = 0;
static volatile sig_atomic_t g_running = 1;

/* 记录清理失败阶段，不输出进程参数或凭据 */
static int prcfail(const char *stage, pid_t pid, int error, size_t size) {
    os_log_error(OS_LOG_DEFAULT, "[TSCleanup] stage=%{public}s pid=%d uid=%u euid=%u errno=%d bytes=%zu",
                 stage, pid, getuid(), geteuid(), error, size);
    return error;
}

/* 核对内核报告的可执行路径和完整 socket 参数 */
static int prcmatch(pid_t pid, const char *binary, const char *socket, bool *matches) {
    *matches = false;
    int mib[3] = {CTL_KERN, KERN_PROCARGS2, pid};
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0) return prcfail("argv-size", pid, errno, size);
    if (size <= sizeof(int)) return prcfail("argv-size", pid, EINVAL, size);
    char *args = malloc(size);
    if (!args) return ENOMEM;
    if (sysctl(mib, 3, args, &size, NULL, 0) != 0) { int error = errno; free(args); return prcfail("argv-read", pid, error, size); }
    if (size <= sizeof(int)) { free(args); return prcfail("argv-read", pid, EINVAL, size); }
    int argc = 0;
    memcpy(&argc, args, sizeof(argc));
    if (argc < 1) { free(args); return prcfail("argv-layout", pid, EINVAL, size); }
    char *cursor = args + sizeof(argc), *end = args + size;
    char *nul = memchr(cursor, 0, end - cursor);
    char resolved[PATH_MAX];
    if (!nul || !realpath(cursor, resolved) || strcmp(resolved, binary) != 0) { free(args); return 0; }
    cursor = nul + 1;
    while (cursor < end && !*cursor) cursor++;
    bool socketFlag = false;
    for (int i = 0; i < argc && cursor < end; i++) {
        nul = memchr(cursor, 0, end - cursor);
        if (!nul) break;
        if ((socketFlag && strcmp(cursor, socket) == 0)
            || (strncmp(cursor, "--socket=", 9) == 0 && strcmp(cursor + 9, socket) == 0)) *matches = true;
        socketFlag = strcmp(cursor, "--socket") == 0;
        cursor = nul + 1;
    }
    free(args);
    return 0;
}

/* 只终止本 App 包内、指定 socket 的后台并清理 socket */
static int trmproc(const char *name, const char *sock_path) {
    if (geteuid() != 0 || !name || name[0] == '\0') {
        return EPERM;
    }
    if (strcmp(name, "tailscaled") != 0 || !sock_path || !*sock_path) return EINVAL;
    char helper[PATH_MAX], binary[PATH_MAX];
    uint32_t capacity = sizeof(helper);
    if (_NSGetExecutablePath(helper, &capacity) != 0 || !realpath(helper, binary)) return prcfail("bundle-path", getpid(), EINVAL, capacity);
    char *basename = strrchr(binary, '/');
    if (!basename || (size_t)(basename - binary) + strlen(name) + 2 > sizeof(binary)) return EINVAL;
    strcpy(basename + 1, name);

    int result = 0;
    bool killed = false;
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t size = 0;
    if (sysctl(mib, 4, NULL, &size, NULL, 0) != 0) {
        result = prcfail("list-size", getpid(), errno, size);
    } else if (size > 0) {
        struct kinfo_proc *procs = malloc(size);
        if (!procs) {
            result = ENOMEM;
        } else {
            if (sysctl(mib, 4, procs, &size, NULL, 0) != 0) {
                result = prcfail("list-read", getpid(), errno, size);
            } else {
                int count = (int)(size / sizeof(struct kinfo_proc));
                for (int i = 0; i < count; i++) {
                    if (strcmp(procs[i].kp_proc.p_comm, name) == 0) {
                        pid_t pid = procs[i].kp_proc.p_pid;
                        /* 已退出进程没有可读参数，也不再持有隧道或 socket */
                        if (procs[i].kp_proc.p_stat == SZOMB) {
                            os_log(OS_LOG_DEFAULT, "[TSCleanup] stage=skip-exited pid=%d", pid);
                            continue;
                        }
                        if (pid > 1 && pid != getpid()) {
                            bool matches = false;
                            int error = prcmatch(pid, binary, sock_path, &matches);
                            if (error) {
                                os_log_error(OS_LOG_DEFAULT, "[TSCleanup] stage=inspect pid=%d state=%d errno=%d", pid, procs[i].kp_proc.p_stat, error);
                                if (error != ESRCH) result = error;
                                continue;
                            }
                            if (!matches) continue;
                            if (kill(pid, SIGKILL) == 0) {
                                killed = true;
                            } else if (errno != ESRCH) {
                                result = prcfail("signal", pid, errno, 0);
                            }
                        }
                    }
                }
            }
            free(procs);
        }
    }

    if (killed) {
        usleep(150000);
    }

    if (result == 0 && unlink(sock_path) != 0 && errno != ENOENT) {
        result = prcfail("socket-unlink", getpid(), errno, 0);
    }
    return result;
}

/* 以 root 权限修改文件权限 */
static int chmroot(const char *mode_str, const char *path) {
    if (geteuid() != 0 || !mode_str || !path) {
        return EPERM;
    }
    char *end = NULL;
    long mode = strtol(mode_str, &end, 8);
    if (!end || *end != '\0' || mode < 0 || mode > 07777) {
        return EINVAL;
    }
    return chmod(path, (mode_t)mode) == 0 ? 0 : errno;
}

/* 信号退出清理回调 */
static void sigclnhnd(int sig) {
    (void)sig;
    g_running = 0;
}

/* 执行资源清理 */
static void hlprclnres(void) {
    if (strlen(g_routed_ip) > 0) {
        utndelroute(g_routed_ip, NULL);
        g_routed_ip[0] = '\0';
    }
    if (g_utun_fd >= 0) {
        utnclose(g_utun_fd, g_ifname);
        g_utun_fd = -1;
        g_ifname[0] = '\0';
    }
    unlink(HELPER_UNIX_SOCK);
}

/* 处理客户端命令请求 */
static void hndclicmd(int client_fd) {
    char in_buf[PROBE_MSG_MAX];
    memset(in_buf, 0, sizeof(in_buf));
    ssize_t rb = read(client_fd, in_buf, sizeof(in_buf) - 1);
    if (rb <= 0) {
        close(client_fd);
        return;
    }

    int cmd = atoi(in_buf);
    ProbeStepReport report;
    memset(&report, 0, sizeof(report));
    report.pid = getpid();
    report.uid = getuid();
    report.euid = geteuid();
    report.uptime_sec = (uint64_t)(time(NULL) - g_start_time);
    prbgetiso(report.timestamp, sizeof(report.timestamp));

    char resp_buf[PROBE_MSG_MAX];
    memset(resp_buf, 0, sizeof(resp_buf));

    switch (cmd) {
        case PROBE_CMD_PING:
        case PROBE_CMD_GET_STATUS: {
            strncpy(report.test, (cmd == PROBE_CMD_PING) ? "P1-root-helper" : "P6-background-alive", sizeof(report.test) - 1);
            strncpy(report.result, (geteuid() == 0) ? "PASS" : "FAIL", sizeof(report.result) - 1);
            strncpy(report.syscall, "geteuid", sizeof(report.syscall) - 1);
            report.return_value = (int)geteuid();
            report.err_no = 0;
            strncpy(report.ifname, g_ifname, sizeof(report.ifname) - 1);
            snprintf(report.details, sizeof(report.details),
                     "Helper active: euid=%u, utun_fd=%d, ifname=%s, uptime=%llus",
                     (unsigned int)geteuid(), g_utun_fd, g_ifname, (unsigned long long)report.uptime_sec);
            prbrprttojson(&report, resp_buf, sizeof(resp_buf));
            break;
        }

        case PROBE_CMD_CREATE_UTUN: {
            if (g_utun_fd >= 0) {
                strncpy(report.test, "P2-utun-create", sizeof(report.test) - 1);
                strncpy(report.result, "PASS", sizeof(report.result) - 1);
                strncpy(report.ifname, g_ifname, sizeof(report.ifname) - 1);
                snprintf(report.details, sizeof(report.details), "Reusing existing utun %s (fd=%d)", g_ifname, g_utun_fd);
            } else {
                g_utun_fd = utnopen(g_ifname, sizeof(g_ifname), &report);
            }
            prbrprttojson(&report, resp_buf, sizeof(resp_buf));
            break;
        }

        case PROBE_CMD_CONFIG_ADDR: {
            if (g_utun_fd < 0 || strlen(g_ifname) == 0) {
                strncpy(report.test, "P3-config-addr", sizeof(report.test) - 1);
                strncpy(report.result, "SKIPPED", sizeof(report.result) - 1);
                snprintf(report.details, sizeof(report.details), "Cannot config address: utun not created");
            } else {
                utncfgaddr(g_ifname, "198.18.0.1", "255.255.255.252", "198.18.0.2", &report);
            }
            prbrprttojson(&report, resp_buf, sizeof(resp_buf));
            break;
        }

        case PROBE_CMD_CONFIG_ROUTE: {
            if (g_utun_fd < 0 || strlen(g_ifname) == 0) {
                strncpy(report.test, "P4-temp-route", sizeof(report.test) - 1);
                strncpy(report.result, "SKIPPED", sizeof(report.result) - 1);
                snprintf(report.details, sizeof(report.details), "Cannot config route: utun not created");
            } else {
                utncfgroute(g_ifname, "198.18.0.2", &report);
                strncpy(g_routed_ip, "198.18.0.2", sizeof(g_routed_ip) - 1);
            }
            prbrprttojson(&report, resp_buf, sizeof(resp_buf));
            break;
        }

        case PROBE_CMD_READ_PACKET: {
            if (g_utun_fd < 0) {
                strncpy(report.test, "P5-packet-verify", sizeof(report.test) - 1);
                strncpy(report.result, "SKIPPED", sizeof(report.result) - 1);
                snprintf(report.details, sizeof(report.details), "Cannot read packet: utun not created");
            } else {
                ProbePacketInfo pinfo;
                utnreadpkt(g_utun_fd, 8, &pinfo, &report);
            }
            prbrprttojson(&report, resp_buf, sizeof(resp_buf));
            break;
        }

        case PROBE_CMD_STOP_CLEAN: {
            hlprclnres();
            strncpy(report.test, "P-cleanup", sizeof(report.test) - 1);
            strncpy(report.result, "PASS", sizeof(report.result) - 1);
            snprintf(report.details, sizeof(report.details), "Cleaned utun and routes successfully");
            prbrprttojson(&report, resp_buf, sizeof(resp_buf));
            write(client_fd, resp_buf, strlen(resp_buf));
            close(client_fd);
            g_running = 0;
            return;
        }

        default: {
            snprintf(resp_buf, sizeof(resp_buf), "{\"error\":\"Unknown command %d\"}", cmd);
            break;
        }
    }

    write(client_fd, resp_buf, strlen(resp_buf));
    close(client_fd);
}

/* 主进程入口 */
int main(int argc, char *argv[]) {
    g_start_time = time(NULL);

    /* 执行一次性 root 文件与进程操作 */
    if (argc == 4 && strcmp(argv[1], "terminate") == 0) {
        return trmproc(argv[2], argv[3]);
    }
    if (argc == 4 && strcmp(argv[1], "chmod") == 0) {
        return chmroot(argv[2], argv[3]);
    }

    /* 重定向 stdout 与 stderr 到日志文件以便排查 */
    FILE *log_fp = fopen(HELPER_LOG_PATH, "a");
    if (log_fp) {
        dup2(fileno(log_fp), STDOUT_FILENO);
        dup2(fileno(log_fp), STDERR_FILENO);
        setlinebuf(stdout);
        setlinebuf(stderr);
    }

    printf("[tsprobe-helper] Started at %ld, PID=%d, UID=%d, EUID=%d\n", (long)g_start_time, getpid(), getuid(), geteuid());

    /* 安装信号处理器与超时 TTL (20分钟) */
    signal(SIGTERM, sigclnhnd);
    signal(SIGINT, sigclnhnd);
    signal(SIGALRM, sigclnhnd);
    alarm(1200);

    /* 创建 TCP 127.0.0.1 套接字 */
    int tcp_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (tcp_fd >= 0) {
        int opt = 1;
        setsockopt(tcp_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
        struct sockaddr_in srv_addr;
        memset(&srv_addr, 0, sizeof(srv_addr));
        srv_addr.sin_len = sizeof(srv_addr);
        srv_addr.sin_family = AF_INET;
        srv_addr.sin_port = htons(PROBE_DEFAULT_PORT);
        inet_pton(AF_INET, "127.0.0.1", &srv_addr.sin_addr);

        if (bind(tcp_fd, (struct sockaddr *)&srv_addr, sizeof(srv_addr)) < 0) {
            printf("[tsprobe-helper] TCP bind 127.0.0.1 failed: %s\n", strerror(errno));
            close(tcp_fd);
            tcp_fd = -1;
        } else if (listen(tcp_fd, 4) < 0) {
            printf("[tsprobe-helper] TCP listen failed: %s\n", strerror(errno));
            close(tcp_fd);
            tcp_fd = -1;
        } else {
            printf("[tsprobe-helper] Listening on TCP 127.0.0.1:%d\n", PROBE_DEFAULT_PORT);
        }
    }

    /* 创建本地 Unix Domain Socket */
    unlink(HELPER_UNIX_SOCK);
    int un_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (un_fd >= 0) {
        struct sockaddr_un un_addr;
        memset(&un_addr, 0, sizeof(un_addr));
        un_addr.sun_family = AF_UNIX;
        strncpy(un_addr.sun_path, HELPER_UNIX_SOCK, sizeof(un_addr.sun_path) - 1);

        if (bind(un_fd, (struct sockaddr *)&un_addr, sizeof(un_addr)) < 0) {
            printf("[tsprobe-helper] Unix socket bind failed: %s\n", strerror(errno));
            close(un_fd);
            un_fd = -1;
        } else if (listen(un_fd, 4) < 0) {
            printf("[tsprobe-helper] Unix socket listen failed: %s\n", strerror(errno));
            close(un_fd);
            un_fd = -1;
        } else {
            chmod(HELPER_UNIX_SOCK, 0777);
            printf("[tsprobe-helper] Listening on Unix socket %s\n", HELPER_UNIX_SOCK);
        }
    }

    if (tcp_fd < 0 && un_fd < 0) {
        printf("[tsprobe-helper] Both TCP and Unix sockets failed to initialize!\n");
        return 1;
    }

    printf("[tsprobe-helper] Service loop ready.\n");

    while (g_running) {
        fd_set fds;
        FD_ZERO(&fds);
        int max_fd = -1;
        if (tcp_fd >= 0) {
            FD_SET(tcp_fd, &fds);
            if (tcp_fd > max_fd) max_fd = tcp_fd;
        }
        if (un_fd >= 0) {
            FD_SET(un_fd, &fds);
            if (un_fd > max_fd) max_fd = un_fd;
        }

        struct timeval tv = { .tv_sec = 2, .tv_usec = 0 };
        int sel = select(max_fd + 1, &fds, NULL, NULL, &tv);
        if (sel <= 0) {
            continue;
        }

        if (tcp_fd >= 0 && FD_ISSET(tcp_fd, &fds)) {
            struct sockaddr_in client_addr;
            socklen_t client_len = sizeof(client_addr);
            int client_fd = accept(tcp_fd, (struct sockaddr *)&client_addr, &client_len);
            if (client_fd >= 0) {
                hndclicmd(client_fd);
            }
        }

        if (un_fd >= 0 && FD_ISSET(un_fd, &fds)) {
            struct sockaddr_un un_client;
            socklen_t un_len = sizeof(un_client);
            int client_fd = accept(un_fd, (struct sockaddr *)&un_client, &un_len);
            if (client_fd >= 0) {
                hndclicmd(client_fd);
            }
        }
    }

    hlprclnres();
    if (tcp_fd >= 0) close(tcp_fd);
    if (un_fd >= 0) close(un_fd);
    printf("[tsprobe-helper] Exiting cleanly.\n");
    return 0;
}
