/* TLS for Honk, on OpenSSL 3 loaded at run time.
   Honk does not link OpenSSL: an app that serves plain HTTP builds and runs
   with no TLS library at all. When Config names a certificate, honk_tls_setup
   loads libssl with dlopen (LoadLibrary on Windows), takes the dozen
   functions below from it, and builds one server context that every worker
   shares. Each connection's session is kept in a table indexed by its
   socket, which only the worker serving that socket touches. */
#include "goose.h"
#include "honk_tls.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
#define honk_dlopen(name) ((void *)LoadLibraryA(name))
#define honk_dlsym(lib, name) ((void *)GetProcAddress((HMODULE)(lib), name))
#else
#include <dlfcn.h>
#define honk_dlopen(name) dlopen(name, RTLD_NOW | RTLD_GLOBAL)
#define honk_dlsym(lib, name) dlsym(lib, name)
#endif

typedef struct { const uint8_t *data; int64_t len; } honk_tls_bytes;   /* const u8[:] */

/* OpenSSL's types are opaque here; these are the ABI-stable entry points
   of libssl 3 (and libcrypto's error queue, reached through libssl). */
typedef void SSL_CTX;
typedef void SSL;
typedef void SSL_METHOD;
static const SSL_METHOD *(*p_TLS_server_method)(void);
static SSL_CTX *(*p_SSL_CTX_new)(const SSL_METHOD *);
static long (*p_SSL_CTX_ctrl)(SSL_CTX *, int, long, void *);
static int (*p_SSL_CTX_use_certificate_chain_file)(SSL_CTX *, const char *);
static int (*p_SSL_CTX_use_PrivateKey_file)(SSL_CTX *, const char *, int);
static int (*p_SSL_CTX_check_private_key)(const SSL_CTX *);
static SSL *(*p_SSL_new)(SSL_CTX *);
static int (*p_SSL_set_fd)(SSL *, int);
static int (*p_SSL_accept)(SSL *);
static int (*p_SSL_read)(SSL *, void *, int);
static int (*p_SSL_write)(SSL *, const void *, int);
static int (*p_SSL_pending)(const SSL *);
static int (*p_SSL_get_error)(const SSL *, int);
static int (*p_SSL_shutdown)(SSL *);
static void (*p_SSL_free)(SSL *);
static unsigned long (*p_ERR_get_error)(void);
static void (*p_ERR_error_string_n)(unsigned long, char *, size_t);

#define HONK_SSL_FILETYPE_PEM 1
#define HONK_SSL_CTRL_SET_MIN_PROTO_VERSION 123
#define HONK_TLS1_2_VERSION 0x0303
#define HONK_SSL_ERROR_ZERO_RETURN 6

#define HONK_TLS_MAX_FD 65536

static SSL_CTX *honk_ctx;
static SSL *honk_sessions[HONK_TLS_MAX_FD];

static void honk_tls_fail(gs_rref err, const char *what) {
    gs_bld_append(err, what, (int64_t)strlen(what));
    if (p_ERR_get_error) {
        unsigned long code = p_ERR_get_error();
        if (code) {
            char text[256];
            p_ERR_error_string_n(code, text, sizeof text);
            gs_bld_append(err, ": ", 2);
            gs_bld_append(err, text, (int64_t)strlen(text));
        }
    }
}

static void *honk_tls_load(const char *wanted) {
    if (wanted[0]) return honk_dlopen(wanted);
    static const char *names[] = {
#if defined(_WIN32)
        "libssl-3-x64.dll", "libssl-3-arm64.dll", "libssl-3.dll",
#elif defined(__APPLE__)
        /* never the unversioned /usr/lib/libssl.dylib, which macOS refuses */
        "libssl.3.dylib", "/opt/homebrew/opt/openssl@3/lib/libssl.3.dylib",
        "/usr/local/opt/openssl@3/lib/libssl.3.dylib", "/opt/local/lib/libssl.3.dylib",
#else
        "libssl.so.3",
#endif
    };
    for (size_t i = 0; i < sizeof names / sizeof names[0]; i++) {
        void *lib = honk_dlopen(names[i]);
        if (lib) return lib;
    }
    return NULL;
}

static void honk_cstr(char *out, size_t cap, honk_tls_bytes s) {
    size_t n = (size_t)s.len < cap - 1 ? (size_t)s.len : cap - 1;
    memcpy(out, s.data, n);
    out[n] = 0;
}

/* Loads OpenSSL (from lib, if not empty) and the PEM certificate chain and
   private key, for every connection accepted from now on. On failure,
   appends why to err. */
bool honk_tls_setup(honk_tls_bytes cert, honk_tls_bytes key, honk_tls_bytes lib, gs_rref err) {
    char cert_path[4096], key_path[4096], lib_path[4096];
    honk_cstr(cert_path, sizeof cert_path, cert);
    honk_cstr(key_path, sizeof key_path, key);
    honk_cstr(lib_path, sizeof lib_path, lib);
    void *ssl = honk_tls_load(lib_path);
    if (!ssl) {
        honk_tls_fail(err, "cannot load OpenSSL 3 (libssl); install it or set Config.tls_lib");
        return false;
    }
#define HONK_SYM(name) \
    if (!(*(void **)&p_##name = honk_dlsym(ssl, #name))) { \
        honk_tls_fail(err, "libssl has no " #name "; Honk needs OpenSSL 3"); return false; }
    HONK_SYM(TLS_server_method) HONK_SYM(SSL_CTX_new) HONK_SYM(SSL_CTX_ctrl)
    HONK_SYM(SSL_CTX_use_certificate_chain_file) HONK_SYM(SSL_CTX_use_PrivateKey_file)
    HONK_SYM(SSL_CTX_check_private_key) HONK_SYM(SSL_new) HONK_SYM(SSL_set_fd)
    HONK_SYM(SSL_accept) HONK_SYM(SSL_read) HONK_SYM(SSL_write) HONK_SYM(SSL_pending)
    HONK_SYM(SSL_get_error) HONK_SYM(SSL_shutdown) HONK_SYM(SSL_free)
    HONK_SYM(ERR_get_error) HONK_SYM(ERR_error_string_n)
#undef HONK_SYM
    SSL_CTX *ctx = p_SSL_CTX_new(p_TLS_server_method());
    if (!ctx) { honk_tls_fail(err, "cannot create a TLS context"); return false; }
    p_SSL_CTX_ctrl(ctx, HONK_SSL_CTRL_SET_MIN_PROTO_VERSION, HONK_TLS1_2_VERSION, NULL);
    if (p_SSL_CTX_use_certificate_chain_file(ctx, cert_path) != 1) {
        honk_tls_fail(err, "cannot read the certificate"); return false;
    }
    if (p_SSL_CTX_use_PrivateKey_file(ctx, key_path, HONK_SSL_FILETYPE_PEM) != 1) {
        honk_tls_fail(err, "cannot read the private key"); return false;
    }
    if (p_SSL_CTX_check_private_key(ctx) != 1) {
        honk_tls_fail(err, "the private key does not match the certificate"); return false;
    }
    honk_ctx = ctx;
    return true;
}

bool honk_tls_on(void) { return honk_ctx != NULL; }

bool honk_tls_accept(int fd) {
    if (fd < 0 || fd >= HONK_TLS_MAX_FD) return false;
    SSL *s = p_SSL_new(honk_ctx);
    if (!s) return false;
    p_SSL_set_fd(s, fd);
    if (p_SSL_accept(s) != 1) {             /* a plain-HTTP client, a bad hello, a timeout */
        p_SSL_free(s);
        while (p_ERR_get_error()) {}
        return false;
    }
    honk_sessions[fd] = s;
    return true;
}

long honk_tls_recv(int fd, char *buf, long max) {
    SSL *s = honk_sessions[fd];
    int n = p_SSL_read(s, buf, (int)max);
    if (n > 0) return n;
    int e = p_SSL_get_error(s, n);
    while (p_ERR_get_error()) {}
    return e == HONK_SSL_ERROR_ZERO_RETURN ? 0 : -1;
}

long honk_tls_send(int fd, const char *buf, long n) {
    int w = p_SSL_write(honk_sessions[fd], buf, (int)n);
    if (w <= 0) { while (p_ERR_get_error()) {} return -1; }
    return w;
}

bool honk_tls_pending(int fd) {
    return fd >= 0 && fd < HONK_TLS_MAX_FD && honk_sessions[fd] && p_SSL_pending(honk_sessions[fd]) > 0;
}

void honk_tls_close(int fd) {
    if (fd < 0 || fd >= HONK_TLS_MAX_FD || !honk_sessions[fd]) return;
    p_SSL_shutdown(honk_sessions[fd]);
    p_SSL_free(honk_sessions[fd]);
    honk_sessions[fd] = NULL;
    while (p_ERR_get_error()) {}
}
