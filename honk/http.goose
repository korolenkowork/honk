// HTTP/1.1 on the wire: reading a request off a connection, splitting it
// into the slices a Ctx holds, and writing the response back.
namespace honk;

import std;

let READ_OK = 0;
let READ_CLOSED = 1;
let READ_BAD = 2;
let READ_TOO_LARGE = 3;

// Reads one request into raw: the head up to the blank line, then as many
// body bytes as Content-Length says.
fn read_request(conn: i64, raw: u8[>..]&, max_body: i64) -> i64 {
    var head_end = -1;
    while head_end < 0 {
        let n = net_recv(conn, raw, 16384);
        if n <= 0 { return if raw.len == 0 { READ_CLOSED } else { READ_BAD }; }
        head_end = find(raw, "\r\n\r\n");
        if head_end < 0 && raw.len > 65536 { return READ_BAD; }
    }
    let want = content_length(raw[..head_end]);
    if want < 0 { return READ_BAD; }
    if want > max_body { return READ_TOO_LARGE; }
    let total = head_end + 4 + want;
    while raw.len < total {
        let n = net_recv(conn, raw, total - raw.len);
        if n <= 0 { return READ_BAD; }
    }
    return READ_OK;
}

// The Content-Length of a request head, 0 if it has none, -1 if malformed.
fn content_length(head: u8[:]) -> i64 {
    var len = 0;
    each_split(head, '\n') { line =>
        let colon = find(line, ":");
        if colon > 0 && same_text_nocase(trim(line[..colon]), "content-length") {
            let n, ok = parse_int(trim(line[colon + 1..]));
            len = if ok && n >= 0 { n } else { -1 };
        }
    };
    return len;
}

// Splits raw into c's method, path, query, headers and body. Also returns
// the request target as sent, for the log.
fn parse_request(c: Ctx&, raw: const u8[:]) -> bool, const u8[:] {
    let head_end = find(raw, "\r\n\r\n");
    if head_end < 0 { return false, raw[0..0]; }
    let line_end = find(raw, "\r\n");
    let line = raw[..line_end];
    let sp1 = find(line, " ");
    if sp1 <= 0 { return false, raw[0..0]; }
    let rest = line[sp1 + 1..];
    let sp2 = find(rest, " ");
    if sp2 <= 0 { return false, raw[0..0]; }
    c.method = line[..sp1];
    let target = rest[..sp2];
    let qmark = find(target, "?");
    let raw_path = if qmark >= 0 { target[..qmark] } else { target };
    c.query = if qmark >= 0 { target[qmark + 1..] } else { target[0..0] };
    if raw_path.len == 0 || raw_path[0] != '/' { return false, target; }
    let at = c.scratch.len;
    percent_decode(c.scratch, raw_path, false);
    c.path = c.scratch[at..];
    // "/items/" and "/items" are the same route.
    if c.path.len > 1 && c.path[c.path.len - 1] == '/' { c.path = c.path[..c.path.len - 1]; }
    c.headers = if line_end + 2 < head_end { raw[line_end + 2..head_end] } else { raw[0..0] };
    c.body = raw[head_end + 4..];
    return true, target;
}

// Appends s with %XX escapes decoded (and '+' as a space, in a query).
fn percent_decode(out: u8[>..]&, s: u8[:], plus_is_space: bool) {
    var i = 0;
    while i < s.len {
        let ch = s[i];
        if ch == '%' && i + 2 < s.len {
            let hi = hex_value(s[i + 1]);
            let lo = hex_value(s[i + 2]);
            if hi >= 0 && lo >= 0 {
                out.push((hi * 16 + lo) as! u8);
                i += 3;
                continue;
            }
        }
        out.push(if plus_is_space && ch == '+' { ' ' } else { ch });
        i++;
    }
}

fn hex_value(ch: u8) -> i64 {
    if ch >= '0' && ch <= '9' { return ch - '0'; }
    if ch >= 'a' && ch <= 'f' { return (ch - 'a') as i64 + 10; }
    if ch >= 'A' && ch <= 'F' { return (ch - 'A') as i64 + 10; }
    return -1;
}

// The decoded value of the first query parameter named name.
fn query_lookup(c: Ctx&, name: const u8[:]) -> const u8[:], bool {
    var found = false;
    var value = c.query[0..0];
    each_split(c.query, '&') { pair =>
        if !found && pair.len > 0 {
            let eq = find(pair, "=");
            let key = if eq >= 0 { pair[..eq] } else { pair };
            if key == name {
                let at = c.scratch.len;
                if eq >= 0 { percent_decode(c.scratch, pair[eq + 1..], true); }
                value = c.scratch[at..];
                found = true;
            }
        }
    };
    return value, found;
}

fn same_text_nocase(a: u8[:], b: u8[:]) -> bool {
    if a.len != b.len { return false; }
    for i in a.len { if lower(a[i]) != lower(b[i]) { return false; } }
    return true;
}

fn lower(ch: u8) -> u8 { if ch >= 'A' && ch <= 'Z' { ch + 32 } else { ch } }

// The reason phrase for a status code.
fn reason(status: i64) -> const u8[:] {
    match status {
        200 => "OK", 201 => "Created", 202 => "Accepted", 204 => "No Content",
        301 => "Moved Permanently", 302 => "Found", 303 => "See Other",
        304 => "Not Modified", 307 => "Temporary Redirect", 308 => "Permanent Redirect",
        400 => "Bad Request", 401 => "Unauthorized", 403 => "Forbidden", 404 => "Not Found",
        405 => "Method Not Allowed", 409 => "Conflict", 410 => "Gone",
        413 => "Content Too Large", 415 => "Unsupported Media Type",
        422 => "Unprocessable Content", 429 => "Too Many Requests",
        500 => "Internal Server Error", 501 => "Not Implemented", 503 => "Service Unavailable",
        _ => "Unknown",
    }
}

// The status line, the headers and the body of c's response.
fn write_response(resp: u8[>..]&, c: Ctx&) {
    let empty = c.status == 204 || c.status == 304;
    format(resp, "HTTP/1.1 ", c.status, " ", reason(c.status), "\r\n");
    if !empty { format(resp, "content-type: ", c.content_type, "\r\n"); }
    let body = c.out[c.out_at..];
    format(resp, "content-length: ", if empty { 0 } else { body.len }, "\r\n");
    resp.append("server: honk\r\nconnection: close\r\n");
    resp.append(c.resp_headers);
    resp.append("\r\n");
    if !empty { resp.append(body); }
}

// A whole response with a JSON body, for answers given before a Ctx exists.
fn plain_response(resp: u8[>..]&, status: i64, body: const u8[:]) {
    format(resp, "HTTP/1.1 ", status, " ", reason(status), "\r\ncontent-type: application/json\r\n",
           "content-length: ", body.len, "\r\nserver: honk\r\nconnection: close\r\n\r\n", body);
}
