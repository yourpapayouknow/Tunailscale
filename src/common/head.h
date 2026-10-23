/*
 * head.h - 统一系统头文件依赖引入与 XNU 内核 ABI 声明
 *
 * 规范引用来源说明：
 * - 标准C基础类型与输入输出: stdio.h, stdlib.h, string.h, unistd.h, stdbool.h, stdint.h
 * - 系统错误与时间控制: errno.h, time.h, sys/time.h, signal.h
 * - POSIX进程与生成控制: spawn.h, sys/wait.h, sys/types.h
 * - BSD网络与套接字API: sys/socket.h, netinet/in.h, arpa/inet.h, net/if.h, sys/sockio.h
 * - XNU内核网络控制与路由套接字: sys/ioctl.h, sys/sysctl.h
 */

#ifndef UTUNAILSCALE_HEAD_H
#define UTUNAILSCALE_HEAD_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <stdbool.h>
#include <stdint.h>
#include <errno.h>
#include <time.h>
#include <signal.h>
#include <spawn.h>

#include <sys/types.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <sys/sysctl.h>
#include <sys/sockio.h>

#include <netinet/in.h>
#include <netinet/ip.h>
#include <netinet/udp.h>
#include <arpa/inet.h>
#include <net/if.h>

#ifdef __APPLE__

/* --- Darwin XNU kern_control ABI 声明 --- */
#define CTLIOCGCOUNT    _IOR('N', 2, int)
#define CTLIOCGINFO     _IOWR('N', 3, struct ctl_info)
#define MAX_KCTL_NAME   96

#ifndef SYSPROTO_CONTROL
#define SYSPROTO_CONTROL 2
#endif

#ifndef AF_SYS_CONTROL
#define AF_SYS_CONTROL   2
#endif

#ifndef AF_SYSTEM
#define AF_SYSTEM 32
#endif

struct ctl_info {
    u_int32_t   ctl_id;
    char        ctl_name[MAX_KCTL_NAME];
};

struct sockaddr_ctl {
    u_char      sc_len;
    u_char      sc_family;
    u_int16_t   ss_sysaddr;
    u_int32_t   sc_id;
    u_int32_t   sc_unit;
    u_int32_t   sc_reserved[5];
};

/* --- Darwin XNU in_aliasreq ABI 声明 --- */
#ifndef SIOCAIFADDR
#define SIOCAIFADDR     _IOW('i', 26, struct in_aliasreq)
#endif

#ifndef SIOCDIFADDR
#define SIOCDIFADDR     _IOW('i', 25, struct ifreq)
#endif

struct in_aliasreq {
    char                ifra_name[IFNAMSIZ];
    struct sockaddr_in  ifra_addr;
    struct sockaddr_in  ifra_broadaddr;
    struct sockaddr_in  ifra_mask;
};
#define ifra_dstaddr    ifra_broadaddr

/* --- Darwin BSD PF_ROUTE / rt_msghdr ABI 声明 --- */
#ifndef PF_ROUTE
#define PF_ROUTE 17
#endif

#ifndef AF_ROUTE
#define AF_ROUTE 17
#endif

#define RTM_VERSION     5
#define RTM_ADD         0x1
#define RTM_DELETE      0x2
#define RTM_CHANGE      0x3
#define RTM_GET         0x4

#define RTF_UP          0x1
#define RTF_GATEWAY     0x2
#define RTF_HOST        0x4
#define RTF_STATIC      0x800

#define RTA_DST         0x1
#define RTA_GATEWAY     0x2
#define RTA_NETMASK     0x4
#define RTA_IFP         0x10
#define RTA_IFA         0x20

struct rt_metrics {
    u_int32_t   rmx_locks;
    u_int32_t   rmx_mtu;
    u_int32_t   rmx_hopcount;
    int32_t     rmx_expire;
    u_int32_t   rmx_recvpipe;
    u_int32_t   rmx_sendpipe;
    u_int32_t   rmx_ssthresh;
    u_int32_t   rmx_rtt;
    u_int32_t   rmx_rttvar;
    u_int32_t   rmx_pksent;
    u_int32_t   rmx_filler[4];
};

struct rt_msghdr {
    u_short     rtm_msglen;
    u_char      rtm_version;
    u_char      rtm_type;
    u_short     rtm_index;
    int         rtm_flags;
    int         rtm_addrs;
    pid_t       rtm_pid;
    int         rtm_seq;
    int         rtm_errno;
    int         rtm_use;
    u_int32_t   rtm_inits;
    struct rt_metrics rtm_rmx;
};

#endif /* __APPLE__ */

/* Darwin utun 协议控制宏定义 */
#ifndef UTUN_CONTROL_NAME
#define UTUN_CONTROL_NAME "com.apple.net.utun_control"
#endif

#ifndef UTUN_OPT_IFNAME
#define UTUN_OPT_IFNAME 2
#endif

#ifndef UTUN_OPT_FLAGS
#define UTUN_OPT_FLAGS 1
#endif

#endif /* UTUNAILSCALE_HEAD_H */
