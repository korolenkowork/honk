/* The native part of Honk: a thin layer over BSD sockets.
   Goose has no networking in its standard library, so Honk brings these
   few functions in through `extern fn` (see net.goose). Everything else,
   HTTP included, is Goose. */
#include "goose.h"

#include <errno.h>
#include <stdbool.h>
#include <signal.h>
#include <stdint.h>
#include <string.h>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
typedef SOCKET honk_sock;
#define honk_closesock closesocket
#pragma comment(lib, "ws2_32.lib")
#else
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>
#define honk_closesock close
#endif

typedef struct { const uint8_t *data; int64_t len; } honk_bytes;   /* const u8[:] */

static int honk_started = 0;

static void honk_startup(void) {
    if (honk_started) return;
    honk_started = 1;
#ifdef _WIN32
    WSADATA wsa;
    WSAStartup(MAKEWORD(2, 2), &wsa);
#else
    signal(SIGPIPE, SIG_IGN);   /* a client that hangs up must not kill the server */
#endif
}

/* Opens a listening TCP socket on host:port. Returns the socket, or -1. */
int64_t honk_net_listen(honk_bytes host, int64_t port, int64_t backlog) {
    honk_startup();
    char h[256];
    int64_t n = host.len < 255 ? host.len : 255;
    memcpy(h, host.data, (size_t)n);
    h[n] = 0;
    int fd = (int)socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, (const char *)&one, sizeof one);
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    if (n == 0 || strcmp(h, "0.0.0.0") == 0) addr.sin_addr.s_addr = htonl(INADDR_ANY);
    else if (strcmp(h, "localhost") == 0) addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    else if (inet_pton(AF_INET, h, &addr.sin_addr) != 1) { honk_closesock(fd); return -1; }
    if (bind(fd, (struct sockaddr *)&addr, sizeof addr) < 0) { honk_closesock(fd); return -1; }
    if (listen(fd, (int)backlog) < 0) { honk_closesock(fd); return -1; }
    return fd;
}

/* Waits for a connection. Reads on it time out after timeout_ms. */
int64_t honk_net_accept(int64_t fd, int64_t timeout_ms) {
    for (;;) {
        int c = (int)accept((int)fd, NULL, NULL);
        if (c < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
#ifdef _WIN32
        DWORD tv = (DWORD)timeout_ms;
#else
        struct timeval tv;
        tv.tv_sec = (time_t)(timeout_ms / 1000);
        tv.tv_usec = (suseconds_t)((timeout_ms % 1000) * 1000);
#endif
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, (const char *)&tv, sizeof tv);
        int one = 1;
        setsockopt(c, IPPROTO_TCP, TCP_NODELAY, (const char *)&one, sizeof one);
        return c;
    }
}

/* Appends up to max bytes read from the connection to out. Returns the
   number read: 0 when the peer closed, -1 on an error or a timeout. */
int64_t honk_net_recv(int64_t fd, gs_rref out, int64_t max) {
    char buf[16384];
    if (max > (int64_t)sizeof buf) max = (int64_t)sizeof buf;
    for (;;) {
        long n = (long)recv((int)fd, buf, (size_t)max, 0);
        if (n < 0 && errno == EINTR) continue;
        if (n > 0) gs_bld_append(out, buf, (int64_t)n);
        return n < 0 ? -1 : (int64_t)n;
    }
}

/* Sends all of data. Returns false if the connection failed first. */
bool honk_net_send(int64_t fd, honk_bytes data) {
    int64_t done = 0;
    while (done < data.len) {
        long n = (long)send((int)fd, (const char *)data.data + done, (size_t)(data.len - done), 0);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return false;
        done += n;
    }
    return true;
}

void honk_net_close(int64_t fd) { honk_closesock((int)fd); }

/* Waits up to timeout_ms for the next request on an idle keep-alive
   connection, watching the listening socket too. Returns 1 when the
   connection has data (or was closed), 2 when a new client is waiting on
   the listener first, and 0 on a timeout. */
int64_t honk_net_wait(int64_t conn, int64_t listener, int64_t timeout_ms) {
#ifdef _WIN32
    WSAPOLLFD p[2];
    p[0].fd = (SOCKET)conn; p[0].events = POLLRDNORM; p[0].revents = 0;
    p[1].fd = (SOCKET)listener; p[1].events = POLLRDNORM; p[1].revents = 0;
    int n = WSAPoll(p, 2, (INT)timeout_ms);
#else
    struct pollfd p[2];
    p[0].fd = (int)conn; p[0].events = POLLIN; p[0].revents = 0;
    p[1].fd = (int)listener; p[1].events = POLLIN; p[1].revents = 0;
    int n;
    do { n = poll(p, 2, (int)timeout_ms); } while (n < 0 && errno == EINTR);
#endif
    if (n <= 0) return 0;
    if (p[0].revents) return 1;
    return 2;
}
