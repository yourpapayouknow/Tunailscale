/*
 * cli.c - TSNativeProbe 命令行入口工具
 */

#include "../src/common/head.h"
#include "../src/common/probe_protocol.h"
#include "../src/common/utun_sys.h"

/* 打印使用说明 */
static void prnusg(const char *prog) {
    printf("Usage: %s <command>\n", prog);
    printf("Commands:\n");
    printf("  status          - Probe current UID/EUID and environment\n");
    printf("  create-utun     - Create native utun interface and display fd\n");
    printf("  config-addr     - Configure 198.18.0.1/30 on given utun\n");
    printf("  config-route    - Configure 198.18.0.2/32 route\n");
    printf("  read-packet     - Intercept packet on utun fd with timeout\n");
}

/* CLI 主函数入口 */
int main(int argc, char *argv[]) {
    if (argc < 2) {
        prnusg(argv[0]);
        return 1;
    }

    const char *cmd = argv[1];
    ProbeStepReport rpt;
    memset(&rpt, 0, sizeof(rpt));
    char json_buf[1024];

    if (strcmp(cmd, "status") == 0) {
        strncpy(rpt.test, "P1-cli-status", sizeof(rpt.test) - 1);
        prbgetiso(rpt.timestamp, sizeof(rpt.timestamp));
        rpt.pid = getpid();
        rpt.uid = getuid();
        rpt.euid = geteuid();
        strncpy(rpt.result, (rpt.euid == 0) ? "PASS" : "FAIL", sizeof(rpt.result) - 1);
        strncpy(rpt.syscall, "geteuid", sizeof(rpt.syscall) - 1);
        rpt.return_value = (int)rpt.euid;
        snprintf(rpt.details, sizeof(rpt.details), "CLI status: UID=%u, EUID=%u", rpt.uid, rpt.euid);
        prbrprttojson(&rpt, json_buf, sizeof(json_buf));
        printf("%s\n", json_buf);
        return (rpt.euid == 0) ? 0 : 1;
    } else if (strcmp(cmd, "create-utun") == 0) {
        char ifname[PROBE_IFNAME_MAX] = {0};
        int fd = utnopen(ifname, sizeof(ifname), &rpt);
        prbrprttojson(&rpt, json_buf, sizeof(json_buf));
        printf("%s\n", json_buf);
        if (fd >= 0) {
            /* 保持10秒后关闭 (符合文档实施顺序) */
            sleep(10);
            utnclose(fd, ifname);
        }
        return (fd >= 0) ? 0 : 1;
    } else if (strcmp(cmd, "config-addr") == 0) {
        const char *ifname = (argc >= 3) ? argv[2] : "utun0";
        int ret = utncfgaddr(ifname, "198.18.0.1", "255.255.255.252", "198.18.0.2", &rpt);
        prbrprttojson(&rpt, json_buf, sizeof(json_buf));
        printf("%s\n", json_buf);
        return ret;
    } else if (strcmp(cmd, "config-route") == 0) {
        const char *ifname = (argc >= 3) ? argv[2] : "utun0";
        int ret = utncfgroute(ifname, "198.18.0.2", &rpt);
        prbrprttojson(&rpt, json_buf, sizeof(json_buf));
        printf("%s\n", json_buf);
        return ret;
    } else {
        fprintf(stderr, "Unknown command: %s\n", cmd);
        prnusg(argv[0]);
        return 1;
    }
}
