/* Exercise the iOS cgo preamble against Apple's native Darwin ioctl ABI. */
#include <assert.h>
#include <stddef.h>
#include <stdarg.h>
#include <stdio.h>
#include <netinet6/in6_var.h>

_Static_assert(sizeof(struct ts_in6_aliasreq) == sizeof(struct in6_aliasreq), "IPv6 add ABI mismatch");
_Static_assert(sizeof(struct ts_in6_ifreq) == sizeof(struct in6_ifreq), "IPv6 delete ABI mismatch");
_Static_assert(offsetof(struct ts_in6_aliasreq, lifetime) == offsetof(struct in6_aliasreq, ifra_lifetime), "IPv6 lifetime offset mismatch");
_Static_assert(TS_SIOCAIFADDR_IN6 == SIOCAIFADDR_IN6, "IPv6 add ioctl mismatch");
_Static_assert(TS_SIOCDIFADDR_IN6 == SIOCDIFADDR_IN6, "IPv6 delete ioctl mismatch");

static unsigned long expected_op;
static unsigned long failed_op;
static int mock_error;
static int calls;
static int mask_bits;

/* Check individual mask bits, including partial bytes and empty masks. */
static void check_mask(const unsigned char *mask, int bits) {
    for (int i = 0; i < bits; i++) {
        assert(!!(mask[i / 8] & (0x80 >> (i % 8))) == (i < mask_bits));
    }
}

/* Capture ioctl requests without changing any host interfaces. */
int ts_ioctl(int fd, unsigned long op, ...) {
    (void)fd;
    va_list args;
    va_start(args, op);
    void *data = va_arg(args, void *);
    va_end(args);
    calls++;
    assert(strcmp((const char *)data, "utun99") == 0);
    if (op == SIOCGIFFLAGS) {
        ((struct ifreq *)data)->ifr_flags = IFF_POINTOPOINT;
    } else if (op == SIOCSIFFLAGS) {
        assert(((struct ifreq *)data)->ifr_flags == (IFF_UP | IFF_POINTOPOINT));
    } else {
        assert(op == expected_op);
        if (op == SIOCAIFADDR || op == SIOCDIFADDR) {
            struct ifaliasreq *req = data;
            struct sockaddr_in *addr = (struct sockaddr_in *)&req->ifra_addr;
            struct in_addr expected;
            assert(inet_pton(AF_INET, "100.64.0.1", &expected) == 1);
            assert(addr->sin_len == sizeof(*addr) && addr->sin_family == AF_INET);
            assert(memcmp(&addr->sin_addr, &expected, sizeof(expected)) == 0);
            if (op == SIOCAIFADDR) {
                assert(memcmp(&req->ifra_addr, &req->ifra_broadaddr, sizeof(*addr)) == 0);
                check_mask((unsigned char *)&((struct sockaddr_in *)&req->ifra_mask)->sin_addr, 32);
            }
        } else {
            struct in6_aliasreq *req = data;
            struct in6_addr expected;
            assert(inet_pton(AF_INET6, "fd7a:115c:a1e0::1", &expected) == 1);
            assert(req->ifra_addr.sin6_len == sizeof(req->ifra_addr));
            assert(req->ifra_addr.sin6_family == AF_INET6);
            assert(memcmp(&req->ifra_addr.sin6_addr, &expected, sizeof(expected)) == 0);
            if (op == SIOCAIFADDR_IN6) {
                assert(memcmp(&req->ifra_addr, &req->ifra_dstaddr, sizeof(req->ifra_addr)) == 0);
                check_mask(req->ifra_prefixmask.sin6_addr.s6_addr, 128);
                assert(req->ifra_lifetime.ia6t_vltime == UINT32_MAX);
                assert(req->ifra_lifetime.ia6t_pltime == UINT32_MAX);
            }
        }
    }
    if (mock_error && (!failed_op || failed_op == op)) {
        errno = mock_error;
        return -1;
    }
    return 0;
}

/* Verify both address families, idempotence, validation, and error propagation. */
int main(void) {
    assert(ts_if_up("utun99") == 0 && calls == 2);
    mock_error = EPERM;
    failed_op = SIOCSIFFLAGS;
    assert(ts_if_up("utun99") == EPERM);
    failed_op = SIOCGIFFLAGS;
    assert(ts_if_up("utun99") == EPERM);
    mock_error = 0;
    failed_op = 0;

    const int prefixes[] = {0, 1, 7, 8, 31, 32, 63, 64, 127, 128};
    for (int ipv6 = 0; ipv6 <= 1; ipv6++) {
        const char *address = ipv6 ? "fd7a:115c:a1e0::1" : "100.64.0.1";
        for (unsigned int i = 0; i < sizeof(prefixes) / sizeof(prefixes[0]); i++) {
            mask_bits = prefixes[i];
            if (!ipv6 && mask_bits > 32) continue;
            expected_op = ipv6 ? SIOCAIFADDR_IN6 : SIOCAIFADDR;
            assert(ts_addr("utun99", address, mask_bits, ipv6, 0) == 0);
        }
        mask_bits = ipv6 ? 128 : 32;
        mock_error = EEXIST;
        assert(ts_addr("utun99", address, mask_bits, ipv6, 0) == 0);
        mock_error = EPERM;
        assert(ts_addr("utun99", address, mask_bits, ipv6, 0) == EPERM);
        expected_op = ipv6 ? SIOCDIFADDR_IN6 : SIOCDIFADDR;
        mock_error = EADDRNOTAVAIL;
        assert(ts_addr("utun99", address, mask_bits, ipv6, 1) == 0);
        mock_error = EPERM;
        assert(ts_addr("utun99", address, mask_bits, ipv6, 1) == EPERM);
        mock_error = 0;
        assert(ts_addr("utun99", address, mask_bits, ipv6, 1) == 0);
    }

    int before = calls;
    assert(ts_if_up("interface-name-too-long") == ENAMETOOLONG);
    assert(ts_addr("utun99", "invalid", 32, 0, 0) == EINVAL);
    assert(ts_addr("utun99", "invalid", 128, 1, 0) == EINVAL);
    assert(ts_addr("utun99", "100.64.0.1", -1, 0, 0) == EINVAL);
    assert(ts_addr("utun99", "100.64.0.1", 33, 0, 0) == EINVAL);
    assert(ts_addr("utun99", "fd7a:115c:a1e0::1", 129, 1, 0) == EINVAL);
    assert(calls == before);
    puts("PASS: native iOS router ABI, flags, IPv4/IPv6 add/delete, masks, validation, and ioctl errors");
    return 0;
}
