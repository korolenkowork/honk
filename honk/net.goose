// Sockets, TLS and reply mailboxes: the only parts of Honk that are not
// Goose (src/honk_net.c, src/honk_tls.c, src/honk_mail.c).
namespace honk;

extern "honk_net_listen" fn net_listen(host: const u8[:], port: i64, backlog: i64) -> i64;
extern "honk_net_accept" fn net_accept(fd: i64, timeout_ms: i64) -> i64;
extern "honk_net_recv" fn net_recv(fd: i64, out: u8[>..]&, max: i64) -> i64;
extern "honk_net_send" fn net_send(fd: i64, data: const u8[:]) -> bool;
extern "honk_net_close" fn net_close(fd: i64);
extern "honk_net_wait" fn net_wait(conn: i64, listener: i64, timeout_ms: i64) -> i64;

extern "honk_mail_slots" fn mail_slots() -> i64;
extern "honk_mail_put" fn mail_put(slot: i64, seq: i64, reply: const u8[:]) -> bool;
extern "honk_mail_take" fn mail_take(slot: i64, seq: i64, out: u8[>..]&, timeout_ms: i64) -> bool;
extern "honk_tls_setup" fn tls_setup(cert: const u8[:], key: const u8[:], lib: const u8[:], err: u8[>..]&) -> bool;
