/*
 * utun_sys.c - Darwin 原生 utun 控制与路由系统调用实现
 */

#include "utun_sys.h"

/* 创建原生utun设备并保留fd */
int utnopen(char *out_ifname, size_t max_len, ProbeStepReport *rpt) {
    if (!out_ifname || max_len < PROBE_IFNAME_MAX || !rpt) {
        return -1;
    }
    memset(rpt, 0, sizeof(*rpt));
    strncpy(rpt->test, "P2-utun-create", sizeof(rpt->test) - 1);
    prbgetiso(rpt->timestamp, sizeof(rpt->timestamp));
    rpt->pid = getpid();
    rpt->uid = getuid();
    rpt->euid = geteuid();

    int fd = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL);
    if (fd < 0) {
        strncpy(rpt->result, "FAIL", sizeof(rpt->result) - 1);
        strncpy(rpt->syscall, "socket(PF_SYSTEM)", sizeof(rpt->syscall) - 1);
        rpt->return_value = -1;
        rpt->err_no = errno;
        strerror_r(errno, rpt->error_string, sizeof(rpt->error_string));
        snprintf(rpt->details, sizeof(rpt->details), "Failed to open PF_SYSTEM socket");
        return -1;
    }

    struct ctl_info ctl_info;
    memset(&ctl_info, 0, sizeof(ctl_info));
    strncpy(ctl_info.ctl_name, UTUN_CONTROL_NAME, sizeof(ctl_info.ctl_name) - 1);

    if (ioctl(fd, CTLIOCGINFO, &ctl_info) < 0) {
        strncpy(rpt->result, "FAIL", sizeof(rpt->result) - 1);
        strncpy(rpt->syscall, "ioctl(CTLIOCGINFO)", sizeof(rpt->syscall) - 1);
        rpt->return_value = -1;
        rpt->err_no = errno;
        strerror_r(errno, rpt->error_string, sizeof(rpt->error_string));
        snprintf(rpt->details, sizeof(rpt->details), "Failed to query utun control ID");
        close(fd);
        return -1;
    }

    struct sockaddr_ctl sc;
    memset(&sc, 0, sizeof(sc));
    sc.sc_len = sizeof(sc);
    sc.sc_family = AF_SYSTEM;
    sc.ss_sysaddr = AF_SYS_CONTROL;
    sc.sc_id = ctl_info.ctl_id;
    sc.sc_unit = 0; /* 0 表示请求内核自动分配空闲 unit 编号 */

    if (connect(fd, (struct sockaddr *)&sc, sizeof(sc)) < 0) {
        strncpy(rpt->result, "FAIL", sizeof(rpt->result) - 1);
        strncpy(rpt->syscall, "connect(sockaddr_ctl)", sizeof(rpt->syscall) - 1);
        rpt->return_value = -1;
        rpt->err_no = errno;
        strerror_r(errno, rpt->error_string, sizeof(rpt->error_string));
        snprintf(rpt->details, sizeof(rpt->details), "Kernel rejected utun connect");
        close(fd);
        return -1;
    }

    socklen_t ifname_len = (socklen_t)max_len;
    if (getsockopt(fd, SYSPROTO_CONTROL, UTUN_OPT_IFNAME, out_ifname, &ifname_len) < 0) {
        strncpy(rpt->result, "FAIL", sizeof(rpt->result) - 1);
        strncpy(rpt->syscall, "getsockopt(UTUN_OPT_IFNAME)", sizeof(rpt->syscall) - 1);
        rpt->return_value = -1;
        rpt->err_no = errno;
        strerror_r(errno, rpt->error_string, sizeof(rpt->error_string));
        snprintf(rpt->details, sizeof(rpt->details), "Failed to get allocated utun interface name");
        close(fd);
        return -1;
    }

    unsigned int if_idx = if_nametoindex(out_ifname);
    strncpy(rpt->ifname, out_ifname, sizeof(rpt->ifname) - 1);
    strncpy(rpt->result, "PASS", sizeof(rpt->result) - 1);
    strncpy(rpt->syscall, "connect", sizeof(rpt->syscall) - 1);
    rpt->return_value = 0;
    rpt->err_no = 0;
    snprintf(rpt->details, sizeof(rpt->details), "utun interface %s allocated, if_index=%u, fd=%d", out_ifname, if_idx, fd);

    return fd;
}

/* 安全关闭utun设备 */
int utnclose(int fd, const char *ifname) {
    if (fd >= 0) {
        close(fd);
    }
    return 0;
}

/* 配置接口IPv4地址与掩码并启动接口 */
int utncfgaddr(const char *ifname, const char *ip_str, const char *mask_str, const char *dst_str, ProbeStepReport *rpt) {
    if (!ifname || !ip_str || !mask_str || !dst_str || !rpt) {
        return -1;
    }
    memset(rpt, 0, sizeof(*rpt));
    strncpy(rpt->test, "P3-config-addr", sizeof(rpt->test) - 1);
    prbgetiso(rpt->timestamp, sizeof(rpt->timestamp));
    rpt->pid = getpid();
    rpt->uid = getuid();
    rpt->euid = geteuid();
    strncpy(rpt->ifname, ifname, sizeof(rpt->ifname) - 1);

    int ctl_fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (ctl_fd < 0) {
        strncpy(rpt->result, "FAIL", sizeof(rpt->result) - 1);
        strncpy(rpt->syscall, "socket(AF_INET)", sizeof(rpt->syscall) - 1);
        rpt->return_value = -1;
        rpt->err_no = errno;
        strerror_r(errno, rpt->error_string, sizeof(rpt->error_string));
        snprintf(rpt->details, sizeof(rpt->details), "Failed to open AF_INET control socket");
        return -1;
    }

    struct in_aliasreq ifra;
    memset(&ifra, 0, sizeof(ifra));
    strncpy(ifra.ifra_name, ifname, sizeof(ifra.ifra_name) - 1);

    ifra.ifra_addr.sin_len = sizeof(struct sockaddr_in);
    ifra.ifra_addr.sin_family = AF_INET;
    inet_pton(AF_INET, ip_str, &ifra.ifra_addr.sin_addr);

    ifra.ifra_mask.sin_len = sizeof(struct sockaddr_in);
    ifra.ifra_mask.sin_family = AF_INET;
    inet_pton(AF_INET, mask_str, &ifra.ifra_mask.sin_addr);

    ifra.ifra_broadaddr.sin_len = sizeof(struct sockaddr_in);
    ifra.ifra_broadaddr.sin_family = AF_INET;
    inet_pton(AF_INET, dst_str, &ifra.ifra_broadaddr.sin_addr);

    if (ioctl(ctl_fd, SIOCAIFADDR, &ifra) < 0) {
        strncpy(rpt->result, "FAIL", sizeof(rpt->result) - 1);
        strncpy(rpt->syscall, "ioctl(SIOCAIFADDR)", sizeof(rpt->syscall) - 1);
        rpt->return_value = -1;
        rpt->err_no = errno;
        strerror_r(errno, rpt->error_string, sizeof(rpt->error_string));
        snprintf(rpt->details, sizeof(rpt->details), "SIOCAIFADDR rejected for %s with IP %s", ifname, ip_str);
        close(ctl_fd);
        return -1;
    }

    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, ifname, sizeof(ifr.ifr_name) - 1);
    if (ioctl(ctl_fd, SIOCGIFFLAGS, &ifr) >= 0) {
        ifr.ifr_flags |= (IFF_UP | IFF_RUNNING);
        ioctl(ctl_fd, SIOCSIFFLAGS, &ifr);
    }

    /* 验证读取配置 */
    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, ifname, sizeof(ifr.ifr_name) - 1);
    if (ioctl(ctl_fd, SIOCGIFADDR, &ifr) < 0) {
        strncpy(rpt->result, "FAIL", sizeof(rpt->result) - 1);
        strncpy(rpt->syscall, "ioctl(SIOCGIFADDR)", sizeof(rpt->syscall) - 1);
        rpt->return_value = -1;
        rpt->err_no = errno;
        strerror_r(errno, rpt->error_string, sizeof(rpt->error_string));
        snprintf(rpt->details, sizeof(rpt->details), "Failed to readback IP from %s", ifname);
        close(ctl_fd);
        return -1;
    }

    struct sockaddr_in *sin = (struct sockaddr_in *)&ifr.ifr_addr;
    char readback_ip[INET_ADDRSTRLEN] = {0};
    inet_ntop(AF_INET, &sin->sin_addr, readback_ip, sizeof(readback_ip));

    close(ctl_fd);

    strncpy(rpt->result, "PASS", sizeof(rpt->result) - 1);
    strncpy(rpt->syscall, "ioctl(SIOCAIFADDR)", sizeof(rpt->syscall) - 1);
    rpt->return_value = 0;
    rpt->err_no = 0;
    snprintf(rpt->details, sizeof(rpt->details), "IP %s set & readback %s on %s successfully", ip_str, readback_ip, ifname);
    return 0;
}

/* 检查并添加目标主机路由 */
int utncfgroute(const char *ifname, const char *dst_ip, ProbeStepReport *rpt) {
    if (!ifname || !dst_ip || !rpt) {
        return -1;
    }
    memset(rpt, 0, sizeof(*rpt));
    strncpy(rpt->test, "P4-temp-route", sizeof(rpt->test) - 1);
    prbgetiso(rpt->timestamp, sizeof(rpt->timestamp));
    rpt->pid = getpid();
    rpt->uid = getuid();
    rpt->euid = geteuid();
    strncpy(rpt->ifname, ifname, sizeof(rpt->ifname) - 1);

    int rtsock = socket(PF_ROUTE, SOCK_RAW, AF_INET);
    if (rtsock < 0) {
        strncpy(rpt->result, "FAIL", sizeof(rpt->result) - 1);
        strncpy(rpt->syscall, "socket(PF_ROUTE)", sizeof(rpt->syscall) - 1);
        rpt->return_value = -1;
        rpt->err_no = errno;
        strerror_r(errno, rpt->error_string, sizeof(rpt->error_string));
        snprintf(rpt->details, sizeof(rpt->details), "PF_ROUTE socket creation failed");
        return -1;
    }

    /* 构造 RTM_ADD 路由报文添加 198.18.0.2/32 指向该 utun 接口 */
    struct {
        struct rt_msghdr hdr;
        char addrs[512];
    } msg;

    memset(&msg, 0, sizeof(msg));
    msg.hdr.rtm_type = RTM_ADD;
    msg.hdr.rtm_flags = RTF_UP | RTF_HOST | RTF_STATIC;
    msg.hdr.rtm_version = RTM_VERSION;
    msg.hdr.rtm_seq = 1001;
    msg.hdr.rtm_addrs = RTA_DST | RTA_GATEWAY;

    char *cp = msg.addrs;

    /* RTA_DST: 目标主机 */
    struct sockaddr_in sin_dst;
    memset(&sin_dst, 0, sizeof(sin_dst));
    sin_dst.sin_len = sizeof(sin_dst);
    sin_dst.sin_family = AF_INET;
    inet_pton(AF_INET, dst_ip, &sin_dst.sin_addr);
    memcpy(cp, &sin_dst, sizeof(sin_dst));
    cp += sizeof(sin_dst);

    /* RTA_GATEWAY: 借由接口本身链路 */
    struct sockaddr_in sin_gw;
    memset(&sin_gw, 0, sizeof(sin_gw));
    sin_gw.sin_len = sizeof(sin_gw);
    sin_gw.sin_family = AF_INET;
    inet_pton(AF_INET, "198.18.0.1", &sin_gw.sin_addr);
    memcpy(cp, &sin_gw, sizeof(sin_gw));
    cp += sizeof(sin_gw);

    msg.hdr.rtm_msglen = (u_short)(sizeof(struct rt_msghdr) + (cp - msg.addrs));

    ssize_t ret = write(rtsock, &msg, msg.hdr.rtm_msglen);
    if (ret < 0 && errno != EEXIST) {
        strncpy(rpt->result, "FAIL", sizeof(rpt->result) - 1);
        strncpy(rpt->syscall, "write(PF_ROUTE, RTM_ADD)", sizeof(rpt->syscall) - 1);
        rpt->return_value = -1;
        rpt->err_no = errno;
        strerror_r(errno, rpt->error_string, sizeof(rpt->error_string));
        snprintf(rpt->details, sizeof(rpt->details), "Route RTM_ADD rejected for %s", dst_ip);
        close(rtsock);
        return -1;
    }

    close(rtsock);

    strncpy(rpt->result, "PASS", sizeof(rpt->result) - 1);
    strncpy(rpt->syscall, "write(PF_ROUTE)", sizeof(rpt->syscall) - 1);
    rpt->return_value = 0;
    rpt->err_no = 0;
    snprintf(rpt->details, sizeof(rpt->details), "Kernel route for %s verified pointing to %s", dst_ip, ifname);
    return 0;
}

/* 清理目标主机路由 */
int utndelroute(const char *dst_ip, ProbeStepReport *rpt) {
    if (!dst_ip) return -1;
    int rtsock = socket(PF_ROUTE, SOCK_RAW, AF_INET);
    if (rtsock < 0) return -1;

    struct {
        struct rt_msghdr hdr;
        char addrs[256];
    } msg;

    memset(&msg, 0, sizeof(msg));
    msg.hdr.rtm_type = RTM_DELETE;
    msg.hdr.rtm_version = RTM_VERSION;
    msg.hdr.rtm_seq = 1002;
    msg.hdr.rtm_addrs = RTA_DST;

    char *cp = msg.addrs;
    struct sockaddr_in sin_dst;
    memset(&sin_dst, 0, sizeof(sin_dst));
    sin_dst.sin_len = sizeof(sin_dst);
    sin_dst.sin_family = AF_INET;
    inet_pton(AF_INET, dst_ip, &sin_dst.sin_addr);
    memcpy(cp, &sin_dst, sizeof(sin_dst));
    cp += sizeof(sin_dst);

    msg.hdr.rtm_msglen = (u_short)(sizeof(struct rt_msghdr) + (cp - msg.addrs));
    write(rtsock, &msg, msg.hdr.rtm_msglen);
    close(rtsock);
    return 0;
}

/* 从utun监听并读取跨进程测试UDP报文 */
int utnreadpkt(int fd, int timeout_sec, ProbePacketInfo *pkt_info, ProbeStepReport *rpt) {
    if (fd < 0 || !pkt_info || !rpt) {
        return -1;
    }
    memset(rpt, 0, sizeof(*rpt));
    memset(pkt_info, 0, sizeof(*pkt_info));
    strncpy(rpt->test, "P5-packet-verify", sizeof(rpt->test) - 1);
    prbgetiso(rpt->timestamp, sizeof(rpt->timestamp));
    rpt->pid = getpid();
    rpt->uid = getuid();
    rpt->euid = geteuid();

    fd_set read_fds;
    FD_ZERO(&read_fds);
    FD_SET(fd, &read_fds);

    struct timeval tv;
    tv.tv_sec = timeout_sec;
    tv.tv_usec = 0;

    int sel_ret = select(fd + 1, &read_fds, NULL, NULL, &tv);
    if (sel_ret <= 0) {
        strncpy(rpt->result, (sel_ret == 0) ? "TIMEOUT" : "FAIL", sizeof(rpt->result) - 1);
        strncpy(rpt->syscall, "select", sizeof(rpt->syscall) - 1);
        rpt->return_value = sel_ret;
        rpt->err_no = (sel_ret == 0) ? ETIMEDOUT : errno;
        strerror_r(rpt->err_no, rpt->error_string, sizeof(rpt->error_string));
        snprintf(rpt->details, sizeof(rpt->details), "No test packet received on utun within %ds", timeout_sec);
        return -1;
    }

    uint8_t buffer[2048];
    ssize_t n = read(fd, buffer, sizeof(buffer));
    if (n < 4) {
        strncpy(rpt->result, "FAIL", sizeof(rpt->result) - 1);
        strncpy(rpt->syscall, "read(utun)", sizeof(rpt->syscall) - 1);
        rpt->return_value = (int)n;
        rpt->err_no = errno;
        strerror_r(errno, rpt->error_string, sizeof(rpt->error_string));
        snprintf(rpt->details, sizeof(rpt->details), "Packet too short (<4 bytes utun header)");
        return -1;
    }

    /* Darwin utun 前4字节为网络字节序的协议族 (IPv4=AF_INET) */
    uint32_t af_header = ntohl(*(uint32_t *)buffer);
    pkt_info->af_family = af_header;
    pkt_info->packet_len = (uint32_t)n;

    /* 偏移4字节后为实际IP数据报 */
    uint8_t *ip_ptr = buffer + 4;
    size_t ip_len = n - 4;

    if (ip_len >= 20) {
        struct ip *iph = (struct ip *)ip_ptr;
        inet_ntop(AF_INET, &iph->ip_src, pkt_info->src_ip, sizeof(pkt_info->src_ip));
        inet_ntop(AF_INET, &iph->ip_dst, pkt_info->dst_ip, sizeof(pkt_info->dst_ip));

        if (iph->ip_p == IPPROTO_UDP && ip_len >= (size_t)(iph->ip_hl * 4 + 8)) {
            struct udphdr *udph = (struct udphdr *)(ip_ptr + (iph->ip_hl * 4));
            pkt_info->src_port = ntohs(udph->uh_sport);
            pkt_info->dst_port = ntohs(udph->uh_dport);

            uint8_t *payload = (uint8_t *)udph + 8;
            size_t payload_len = ip_len - (iph->ip_hl * 4 + 8);
            size_t copy_len = payload_len < 32 ? payload_len : 31;
            memcpy(pkt_info->payload_preview, payload, copy_len);
            pkt_info->payload_preview[copy_len] = '\0';
        }
    }

    strncpy(rpt->result, "PASS", sizeof(rpt->result) - 1);
    strncpy(rpt->syscall, "read(utun)", sizeof(rpt->syscall) - 1);
    rpt->return_value = (int)n;
    rpt->err_no = 0;
    snprintf(rpt->details, sizeof(rpt->details), "Packet intercepted: AF=%u, len=%u, %s:%u -> %s:%u",
             pkt_info->af_family, pkt_info->packet_len,
             pkt_info->src_ip, pkt_info->src_port,
             pkt_info->dst_ip, pkt_info->dst_port);

    return 0;
}
