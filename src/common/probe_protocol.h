/*
 * probe_protocol.h - 探针IPC命令与结构化报告协议定义
 */

#ifndef UTUNAILSCALE_PROBE_PROTOCOL_H
#define UTUNAILSCALE_PROBE_PROTOCOL_H

#include "head.h"

#define PROBE_DEFAULT_PORT 28848
#define PROBE_AUTH_TOKEN_LEN 32
#define PROBE_IFNAME_MAX 32
#define PROBE_MSG_MAX 2048

/* 测试关卡命令字 */
typedef enum {
    PROBE_CMD_PING = 1,
    PROBE_CMD_GET_STATUS = 2,
    PROBE_CMD_CREATE_UTUN = 3,
    PROBE_CMD_CONFIG_ADDR = 4,
    PROBE_CMD_CONFIG_ROUTE = 5,
    PROBE_CMD_READ_PACKET = 6,
    PROBE_CMD_STOP_CLEAN = 7
} ProbeCommandType;

/* 结构化测试报告项 */
typedef struct {
    char test[32];          /* 关卡名: P1-root-helper, P2-utun-create 等 */
    char result[16];        /* PASS | FAIL | SKIPPED | NOT_TESTED */
    char timestamp[32];     /* ISO-8601 时间戳 */
    pid_t pid;              /* 当前进程 PID */
    uid_t uid;              /* 当前 UID */
    uid_t euid;             /* 当前 EUID (必须为0方可算 PASS) */
    char syscall[32];       /* 调用的系统调用名，如 connect, ioctl */
    int return_value;       /* 系统调用返回值 */
    int err_no;             /* 真实 errno */
    char error_string[128]; /* strerror 结果 */
    char ifname[PROBE_IFNAME_MAX]; /* 接口名，如 utun3 */
    char details[256];      /* 实测观察细节 */
    uint64_t uptime_sec;    /* 系统/进程运行秒数 */
} ProbeStepReport;

/* 报文捕获详情 (P5) */
typedef struct {
    uint32_t packet_len;
    uint32_t af_family;     /* Darwin utun 前4字节协议族 */
    char src_ip[64];
    char dst_ip[64];
    uint16_t src_port;
    uint16_t dst_port;
    char payload_preview[64];
} ProbePacketInfo;

/* 获取当前 ISO-8601 时间戳 */
void prbgetiso(char *buffer, size_t max_len);

/* 格式化生成结构化 JSON 报告 */
int prbrprttojson(const ProbeStepReport *rpt, char *out_json, size_t max_len);

#endif /* UTUNAILSCALE_PROBE_PROTOCOL_H */
