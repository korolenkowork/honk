/* TLS for Honk's sockets (honk_tls.c), used by honk_net.c. */
#ifndef HONK_TLS_H
#define HONK_TLS_H

#include <stdbool.h>
#include <stdint.h>

bool honk_tls_on(void);                        /* a certificate is loaded */
bool honk_tls_accept(int fd);                  /* runs the handshake on a new connection */
long honk_tls_recv(int fd, char *buf, long max); /* as recv: >0, 0 closed, -1 error */
long honk_tls_send(int fd, const char *buf, long n);
bool honk_tls_pending(int fd);                 /* decrypted bytes are already waiting */
void honk_tls_close(int fd);                   /* sends close_notify and frees the session */

#endif
