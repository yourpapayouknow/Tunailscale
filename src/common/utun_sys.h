/*
 * utun_sys.h - Darwin 原生 utun 控制与路由底层系统调用封装
 */

#ifndef UTUNAILSCALE_UTUN_SYS_H
#define UTUNAILSCALE_UTUN_SYS_H

#include "head.h"
#include "probe_protocol.h"

/* 创建原生utun设备并保留fd */
int utnopen(char *out_ifname, size_t max_len, ProbeStepReport *rpt);

/* 安全关闭utun设备 */
int utnclose(int fd, const char *ifname);

/* 配置接口IPv4地址与掩码并启动接口 */
int utncfgaddr(const char *ifname, const char *ip_str, const char *mask_str, const char *dst_str, ProbeStepReport *rpt);

/* 检查并添加目标主机路由 */
int utncfgroute(const char *ifname, const char *dst_ip, ProbeStepReport *rpt);

/* 清理目标主机路由 */
int utndelroute(const char *dst_ip, ProbeStepReport *rpt);

/* 从utun监听并读取跨进程测试UDP报文 */
int utnreadpkt(int fd, int timeout_sec, ProbePacketInfo *pkt_info, ProbeStepReport *rpt);

#endif /* UTUNAILSCALE_UTUN_SYS_H */
