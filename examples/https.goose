// HTTPS: the hello app behind TLS. Honk loads OpenSSL 3 at run time, only
// when a certificate is configured. Make a self-signed certificate for
// localhost, then run:
//
//     openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj /CN=localhost \
//         -addext subjectAltName=DNS:localhost,IP:127.0.0.1 \
//         -keyout key.pem -out cert.pem
//     goose examples/https.goose -- cert.pem key.pem
//     curl --cacert cert.pem https://localhost:8443/
import honk from "../honk";
import os;

struct Message { message: const u8[:], secure: bool }

fn app(c: honk::Ctx&) {
    honk::get<Message>(c, "/") { Message { message: "Honk!", secure: true } };
}

fn main() {
    let a = args();
    if a.len < 3 {
        print("usage: https cert.pem key.pem");
        exit(2);
    }
    honk::serve(honk::Config { port: 8443, tls_cert: a[1], tls_key: a[2], .. }, app);
}
