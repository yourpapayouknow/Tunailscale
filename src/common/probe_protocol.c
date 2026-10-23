/*
 * probe_protocol.c - 探针协议序列化与通用辅助函数
 */

#include "probe_protocol.h"

/* 获取当前ISO时间戳 */
void prbgetiso(char *buffer, size_t max_len) {
    time_t now = time(NULL);
    struct tm tm_buf;
    gmtime_r(&now, &tm_buf);
    strftime(buffer, max_len, "%Y-%m-%dT%H:%M:%SZ", &tm_buf);
}

/* 序列化测试报告至JSON */
int prbrprttojson(const ProbeStepReport *rpt, char *out_json, size_t max_len) {
    if (!rpt || !out_json || max_len == 0) {
        return -1;
    }
    return snprintf(out_json, max_len,
        "{\n"
        "  \"test\": \"%s\",\n"
        "  \"result\": \"%s\",\n"
        "  \"timestamp\": \"%s\",\n"
        "  \"pid\": %d,\n"
        "  \"uid\": %u,\n"
        "  \"euid\": %u,\n"
        "  \"syscall\": \"%s\",\n"
        "  \"return_value\": %d,\n"
        "  \"errno\": %d,\n"
        "  \"error_string\": \"%s\",\n"
        "  \"interface\": \"%s\",\n"
        "  \"details\": \"%s\",\n"
        "  \"uptime\": %llu\n"
        "}",
        rpt->test,
        rpt->result,
        rpt->timestamp,
        (int)rpt->pid,
        (unsigned int)rpt->uid,
        (unsigned int)rpt->euid,
        rpt->syscall,
        rpt->return_value,
        rpt->err_no,
        rpt->error_string,
        rpt->ifname,
        rpt->details,
        (unsigned long long)rpt->uptime_sec
    );
}
