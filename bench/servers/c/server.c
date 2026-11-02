/* The benchmark API in C (bench/README.md has the spec). C has no HTTP or
   JSON library, so this is a minimal hand-written server: a thread per
   connection, HTTP/1.1 keep-alive, and just enough JSON to read
   {"name": "...", "price": ...}.

       cc -O2 -pthread bench/servers/c/server.c -o bench/servers/c/server */
#include <arpa/inet.h>
#include <ctype.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <unistd.h>

static int listener;

static int send_all(int fd, const char *p, size_t n) {
    while (n > 0) {
        ssize_t w = send(fd, p, n, 0);
        if (w <= 0) return 0;
        p += w;
        n -= (size_t)w;
    }
    return 1;
}

static int respond(int fd, int status, const char *reason, const char *body, size_t len) {
    char head[256];
    int h = snprintf(head, sizeof head,
                     "HTTP/1.1 %d %s\r\ncontent-type: application/json\r\ncontent-length: %zu\r\n\r\n",
                     status, reason, len);
    return send_all(fd, head, (size_t)h) && send_all(fd, body, len);
}

/* Finds "key": in a flat JSON object and returns a pointer to its value. */
static const char *json_value(const char *body, const char *key) {
    char pat[64];
    snprintf(pat, sizeof pat, "\"%s\"", key);
    const char *p = strstr(body, pat);
    if (!p) return NULL;
    p += strlen(pat);
    while (isspace((unsigned char)*p)) p++;
    if (*p != ':') return NULL;
    p++;
    while (isspace((unsigned char)*p)) p++;
    return p;
}

static int create_item(int fd, const char *body) {
    const char *name = json_value(body, "name");
    const char *price = json_value(body, "price");
    char *end = NULL;
    double v = price ? strtod(price, &end) : 0;
    if (!name || *name != '"' || !price || end == price) {
        static const char err[] = "{\"detail\":[{\"type\":\"invalid\",\"msg\":\"name and price are required\"}]}";
        return respond(fd, 422, "Unprocessable Content", err, sizeof err - 1);
    }
    const char *name_end = strchr(name + 1, '"');
    if (!name_end) return respond(fd, 422, "Unprocessable Content", "{}", 2);
    char out[512];
    int n = snprintf(out, sizeof out, "{\"name\":\"%.*s\",\"price\":%.17g,\"price_with_tax\":%.17g}",
                     (int)(name_end - name - 1), name + 1, v, v * 1.2);
    return respond(fd, 201, "Created", out, (size_t)n);
}

static int route(int fd, const char *method, char *target, const char *body) {
    char *query = strchr(target, '?');
    if (query) *query++ = 0;
    if (!strcmp(method, "GET") && !strcmp(target, "/hello")) {
        static const char hello[] = "{\"message\":\"Honk!\"}";
        return respond(fd, 200, "OK", hello, sizeof hello - 1);
    }
    if (!strncmp(target, "/items/", 7) && !strcmp(method, "GET")) {
        char *end;
        long long id = strtoll(target + 7, &end, 10);
        if (end == target + 7 || *end) {
            static const char err[] = "{\"detail\":[{\"type\":\"int_parsing\",\"loc\":[\"path\",\"item_id\"]}]}";
            return respond(fd, 422, "Unprocessable Content", err, sizeof err - 1);
        }
        const char *q = "";
        size_t qlen = 0;
        for (char *p = query; p && *p;) {
            char *amp = strchr(p, '&');
            size_t len = amp ? (size_t)(amp - p) : strlen(p);
            if (len >= 2 && !strncmp(p, "q=", 2)) { q = p + 2; qlen = len - 2; }
            p = amp ? amp + 1 : NULL;
        }
        char out[512];
        int n = snprintf(out, sizeof out, "{\"item_id\":%lld,\"q\":\"%.*s\"}", id, (int)qlen, q);
        return respond(fd, 200, "OK", out, (size_t)n);
    }
    if (!strcmp(target, "/items") && !strcmp(method, "POST")) return create_item(fd, body);
    static const char nf[] = "{\"detail\":\"Not Found\"}";
    return respond(fd, 404, "Not Found", nf, sizeof nf - 1);
}

static void serve(int fd) {
    char buf[65536];
    size_t have = 0;
    for (;;) {
        char *head_end;
        buf[have] = 0;
        while (!(head_end = strstr(buf, "\r\n\r\n"))) {
            if (have >= sizeof buf - 1) return;
            ssize_t n = recv(fd, buf + have, sizeof buf - 1 - have, 0);
            if (n <= 0) return;
            have += (size_t)n;
            buf[have] = 0;
        }
        size_t head_len = (size_t)(head_end - buf) + 4;
        size_t body_len = 0;
        for (char *line = strstr(buf, "\r\n"); line && line < head_end; line = strstr(line + 2, "\r\n")) {
            if (!strncasecmp(line + 2, "content-length:", 15)) body_len = strtoul(line + 17, NULL, 10);
        }
        if (head_len + body_len >= sizeof buf) return;
        while (have < head_len + body_len) {
            ssize_t n = recv(fd, buf + have, sizeof buf - 1 - have, 0);
            if (n <= 0) return;
            have += (size_t)n;
        }
        char saved = buf[head_len + body_len];
        buf[head_len + body_len] = 0;
        char method[8] = {0}, target[2048] = {0};
        if (sscanf(buf, "%7s %2047s", method, target) != 2) return;
        if (!route(fd, method, target, buf + head_len)) return;
        buf[head_len + body_len] = saved;
        size_t used = head_len + body_len;
        memmove(buf, buf + used, have - used);
        have -= used;
    }
}

static void *connection(void *arg) {
    int fd = (int)(intptr_t)arg;
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    serve(fd);
    close(fd);
    return NULL;
}

int main(void) {
    signal(SIGPIPE, SIG_IGN);
    listener = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(8000);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(listener, (struct sockaddr *)&addr, sizeof addr) || listen(listener, 1024)) {
        perror("listen");
        return 1;
    }
    for (;;) {
        int fd = accept(listener, NULL, NULL);
        if (fd < 0) continue;
        pthread_t t;
        if (pthread_create(&t, NULL, connection, (void *)(intptr_t)fd) == 0) pthread_detach(t);
        else close(fd);
    }
}
