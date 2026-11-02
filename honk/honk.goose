// Honk: typed, self-documenting web servers in Goose.
//
// An app is one function that declares routes. Each route names the model
// it answers with and, optionally, a params struct whose fields Honk fills
// from the path, the query string and the JSON body, validated, before the
// handler block runs. The block's value is the response, serialized to JSON
// by reflection. The same declarations, read once at startup, become the
// OpenAPI schema served at /openapi.json, with Swagger UI at /docs.
//
//     struct Item { name: u8[..32], price: f64 }
//     struct ReadItem { item_id: i64, q: const u8[:] = "" }
//
//     fn app(c: honk::Ctx&) {
//         honk::get<Item, ReadItem>(c, "/items/{item_id}") { p =>
//             Item { name: "goose", price: p.item_id * 1.5 }
//         };
//     }
//
//     fn main() { honk::serve(honk::Config { port: 8000, .. }, app); }
//
// The modules: net (sockets and mailboxes, the only C), http (requests and
// responses), model (JSON out, validation in, schemas), routing (route
// declarations), openapi (the schema and the docs pages) and workers
// (threads, shared state and background jobs).
namespace honk;

import std;
import exception;
import os;
import .net;
import .http;
import .model;
import .routing;
import .openapi;
import .workers;

let VERSION = "0.1.0";

// How serve() runs, and what /openapi.json says about the app.
struct Config {
    host: const u8[:] = "127.0.0.1",
    port: i64 = 8000,
    title: const u8[:] = "Honk API",
    version: const u8[:] = "0.1.0",
    description: const u8[:] = "",
    docs: bool = true,              // serve /docs, /redoc and /openapi.json
    log: bool = true,               // one line per request on stdout
    timeout_ms: i64 = 10000,        // how long a client may take to send its request
    keep_alive: bool = true,        // serve several requests per connection
    keep_alive_ms: i64 = 5000,      // how long an idle connection is kept
    keep_alive_max: i64 = 100,      // requests per connection before it is closed
    max_body: i64 = 1048576,        // larger requests get 413
    tls_cert: const u8[:] = "",     // a PEM certificate chain: serve HTTPS instead of HTTP
    tls_key: const u8[:] = "",      // its PEM private key
    tls_lib: const u8[:] = "",      // libssl to load, if not found where OpenSSL 3 usually is
}

// A path parameter captured by the matched route.
struct Param { name: u8[..32], value: const u8[:] }

// One declared route, recorded while the app is described for OpenAPI. The
// path and the operation's JSON are ranges of Api.text.
struct RouteInfo { method: const u8[:], path_at: i64, path_end: i64, op_at: i64, op_end: i64 }

// What describing the app collects.
struct Api { text: u8[>..]&, routes: RouteInfo[>..]& }

// Everything a handler can see and change about the request in flight.
// Routes, dependencies and helpers all take it as `c: honk::Ctx&`.
struct Ctx {
    method: const u8[:],
    path: const u8[:],              // percent-decoded
    query: const u8[:],             // raw, without the '?'
    headers: const u8[:],           // the raw header lines
    body: const u8[:],
    params: Param[..8],             // path parameters of the matched route
    status: i64 = 200,
    content_type: const u8[:] = "application/json",
    out: u8[>..]&,                  // the response body, from out[out_at]
    out_at: i64 = 0,                // what an error throws away stays below this
    resp_headers: u8[>..]&,         // extra response header lines, "Name: value\r\n" each
    scratch: u8[>..]&,              // decoded text that lives as long as the request
    handled: bool = false,          // a route has answered
    path_seen: bool = false,        // a route matched the path but not the method
    describing: bool = false,       // routes record themselves instead of matching
    keep_alive: bool = false,       // the connection stays open after this response
    prefix: u8[..128] = [],         // from honk::include
    tag: const u8[:] = "",          // from honk::include
    api: Api&,
}

// An HTTP error: thrown by honk::raise, answered as {"detail": ...}.
struct HTTPError { status: i64, detail: u8[], is_json: bool = false }

// Response types other than JSON models. A route answers with one of these
// by naming it as its response type: honk::get<honk::Html>(c, "/") { ... }.
struct Html { body: u8[] }
struct Text { body: u8[] }
struct Redirect { location: u8[], status: i64 = 307 }
struct NoContent { }

// The params type of a route that takes none, for the two-type forms.
struct NoParams { }

// Stops the handler and answers `status` with {"detail": detail}. Call it
// from a route block or from any function a route block calls.
fn raise<T>(status: i64, detail: T[:]) {
    exception::throw(HTTPError { status: status, detail: detail });
}

// The value of a request header, matched without regard to case, and
// whether it was there.
fn header(c: Ctx&, name: const u8[:]) -> const u8[:], bool {
    var found = false;
    var value = c.headers[0..0];
    each_split(c.headers, '\n') { line =>
        let colon = find(line, ":");
        if !found && colon > 0 && same_text_nocase(trim(line[..colon]), name) {
            value = trim(line[colon + 1..]);
            found = true;
        }
    };
    return value, found;
}

// Adds a header to the response.
fn set_header(c: Ctx&, name: const u8[:], value: const u8[:]) {
    c.resp_headers.append(name);
    c.resp_headers.append(": ");
    c.resp_headers.append(value);
    c.resp_headers.append("\r\n");
}

// The value of a path parameter the matched route captured, as written.
fn path_param(c: Ctx&, name: const u8[:]) -> const u8[:], bool {
    for p in c.params { if p.name == name { return p.value, true; } }
    return c.path[0..0], false;
}

// A query string parameter, percent-decoded, and whether it was there.
fn query_param(c: Ctx&, name: const u8[:]) -> const u8[:], bool {
    return query_lookup(c, name);
}

// Runs a group of routes under a path prefix, with a tag for the docs:
//
//     fn users(c: honk::Ctx&) { honk::get<User>(c, "/me") { ... }; }
//     honk::include(c, "/users", "users", users);
fn include<F>(c: Ctx&, prefix: const u8[:], tag: const u8[:] = "") {
    if c.handled { return; }
    let mark = c.prefix.len;
    let saved_tag = c.tag;
    c.prefix.append(prefix);
    if tag.len > 0 { c.tag = tag; }
    F(c);
    c.prefix.resize(mark);
    c.tag = saved_tag;
}

// Listens on cfg.host:cfg.port and answers requests with App until the
// process ends. App is `fn app(c: honk::Ctx&)`, declaring the routes.
fn serve<App>(cfg: Config) {
    let fd = listen_or_abort(cfg);
    print("INFO:     Honk ", VERSION, " running on ", scheme(cfg), "://", cfg.host, ":", cfg.port,
          if cfg.docs { " (docs at /docs)" } else { "" });
    accept_loop(cfg, fd, true, App);
}

// Opens the listening socket, and loads the certificate when cfg asks for
// TLS, so that every connection accepted after this speaks HTTPS.
fn listen_or_abort(cfg: Config&) -> i64 {
    if cfg.tls_cert.len > 0 || cfg.tls_key.len > 0 {
        if cfg.tls_cert.len == 0 || cfg.tls_key.len == 0 {
            abort("honk: TLS needs both Config.tls_cert and Config.tls_key");
        }
        var why: u8[>..] = [];
        if !tls_setup(cfg.tls_cert, cfg.tls_key, cfg.tls_lib, why) { abort(str("honk: ", why)); }
    }
    let fd = net_listen(cfg.host, cfg.port, 128);
    if fd < 0 { abort(str("honk: cannot listen on ", cfg.host, ":", cfg.port)); }
    return fd;
}

fn scheme(cfg: Config&) -> const u8[:] { if cfg.tls_cert.len > 0 { "https" } else { "http" } }

// Accepts connections on the listening socket fd and answers their requests
// with App, forever. give_way closes an idle keep-alive connection as soon
// as another client connects, for a server that answers one at a time.
fn accept_loop<App>(cfg: Config&, fd: i64, give_way: bool) {
    var spec: u8[>..] = [];
    if cfg.docs { build_openapi(cfg, spec, App); }
    loop {
        let conn = net_accept(fd, cfg.timeout_ms);
        if conn < 0 { continue; }
        var served = 0;
        loop {
            var keep = false;
            {
                var raw: u8[>..] = [];
                var resp: u8[>..] = [];
                let got = read_request(conn, raw, cfg.max_body);
                if got == READ_OK {
                    let status, again = process(cfg, raw, spec, resp, served + 1 < cfg.keep_alive_max, App);
                    keep = again;
                } else if got == READ_TOO_LARGE {
                    plain_response(resp, 413, "{\"detail\":\"Request Entity Too Large\"}");
                } else if got == READ_BAD {
                    plain_response(resp, 400, "{\"detail\":\"Bad Request\"}");
                }
                if resp.len > 0 && !net_send(conn, resp) { keep = false; }
            }
            served++;
            if !keep || served >= cfg.keep_alive_max { break; }
            if net_wait(conn, if give_way { fd } else { -1 }, cfg.keep_alive_ms) != 1 { break; }
        }
        net_close(conn);
    }
}

// Answers one raw HTTP request with App, without a network: Honk's
// test client. Returns the status and the response body.
//
//     let status, body = honk::request("GET", "/items/1", app);
//     let status, body = honk::request("POST", "/items", "{\"name\":\"x\"}", app);
fn request<App>(method: const u8[:], target: const u8[:], body: const u8[:] = "",
                headers: const u8[:] = "") -> i64, u8[>..] {
    let cfg = Config { log: false, .. };
    var spec: u8[>..] = [];
    build_openapi(cfg, spec, App);
    var raw: u8[>..] = [];
    format(raw, method, " ", target, " HTTP/1.1\r\nhost: test\r\n", headers);
    if body.len > 0 { format(raw, "content-type: application/json\r\ncontent-length: ", body.len, "\r\n"); }
    raw.append("\r\n");
    raw.append(body);
    var resp: u8[>..] = [];
    let status, keep = process(cfg, raw, spec, resp, false, App);
    let at = find(resp, "\r\n\r\n");
    var body: u8[>..] = [];
    body.append(resp[at + 4..]);
    return status, body;
}

// Answers the request in raw with App: parses it, runs the routes and
// writes the whole HTTP response into resp. Returns the status, and whether
// the connection stays open for another request, which may_keep allows.
fn process<App>(cfg: Config&, raw: const u8[:], spec: const u8[:], resp: u8[>..]&, may_keep: bool) -> i64, bool {
    var out: u8[>..] = [];
    var extra: u8[>..] = [];
    var scratch: u8[>..] = [];
    var api_text: u8[>..] = [];
    var api_routes: RouteInfo[>..] = [];
    var api = Api { text: api_text, routes: api_routes };
    var c = Ctx { method: "", path: "", query: "", headers: "", body: "", params: [],
                  out: out, resp_headers: extra, scratch: scratch, api: api };
    let started = clock();
    let parsed, target = parse_request(c, raw);
    c.keep_alive = parsed && may_keep && cfg.keep_alive && wants_keep_alive(c, raw);
    if !parsed {
        c.status = 400;
        c.out.append("{\"detail\":\"Bad Request\"}");
    } else if cfg.docs && c.method == "GET" && c.path == "/openapi.json" {
        c.out.append(spec);
    } else if cfg.docs && c.method == "GET" && c.path == "/docs" {
        c.content_type = "text/html; charset=utf-8";
        swagger_page(c.out, cfg);
    } else if cfg.docs && c.method == "GET" && c.path == "/redoc" {
        c.content_type = "text/html; charset=utf-8";
        redoc_page(c.out, cfg);
    } else {
        fn run() { App(c); }
        exception::try<HTTPError>(run) { e =>
            c.out_at = c.out.len;           // drop what the handler wrote
            c.handled = true;
            c.status = e.status;
            c.content_type = "application/json";
            c.out.append("{\"detail\":");
            if e.is_json { c.out.append(e.detail); } else { json::format_string(c.out, e.detail); }
            c.out.push('}');
        };
        if !c.handled {
            if c.path_seen {
                c.status = 405;
                c.out.append("{\"detail\":\"Method Not Allowed\"}");
            } else {
                c.status = 404;
                c.out.append("{\"detail\":\"Not Found\"}");
            }
        }
    }
    write_response(resp, c);
    if cfg.log {
        var line: u8[>..] = [];
        format(line, "INFO:     \"", c.method, " ", target, " HTTP/1.1\" ", c.status, " ",
               reason(c.status), " (");
        format_flt(line, (clock() - started) * 1000.0, 2);
        line.append(" ms)");
        print(line);
    }
    return c.status, c.keep_alive;
}
