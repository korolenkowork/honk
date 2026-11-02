// Sockets: the only part of Honk that is not Goose (src/honk_net.c).
namespace honk;

extern "honk_net_listen" fn net_listen(host: const u8[:], port: i64, backlog: i64) -> i64;
extern "honk_net_accept" fn net_accept(fd: i64, timeout_ms: i64) -> i64;
extern "honk_net_recv" fn net_recv(fd: i64, out: u8[>..]&, max: i64) -> i64;
extern "honk_net_send" fn net_send(fd: i64, data: const u8[:]) -> bool;
extern "honk_net_close" fn net_close(fd: i64);
