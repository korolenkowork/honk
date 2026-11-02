// Routes. Each method has two forms:
//
//     honk::get<R>(c, "/path") { ... R value ... };
//     honk::get<R, P>(c, "/items/{item_id}") { p => ... R value ... };
//
// R is the response: a model (sent as JSON), honk::Html, honk::Text,
// honk::Redirect or honk::NoContent. P is the params struct: each field is
// filled, in this order of preference, from the path parameter of its name,
// from the body when the field is itself a model, or from the query
// parameter of its name. A path or body field that fails validation, or a
// query field that does not parse, answers 422 with a list of errors
// and the block does not run.
//
// Options for every route: `summary` for the docs, and `status` for the
// success status code.
namespace honk;

import std;
import exception;

fn get<R, F>(c: Ctx&, path: const u8[:], summary: const u8[:] = "", status: i64 = 200) {
    route<R, NoParams>(c, "GET", path, summary, status) { p => F() };
}
fn get<R, P, F>(c: Ctx&, path: const u8[:], summary: const u8[:] = "", status: i64 = 200) {
    route<R, P>(c, "GET", path, summary, status, F);
}
fn post<R, F>(c: Ctx&, path: const u8[:], summary: const u8[:] = "", status: i64 = 200) {
    route<R, NoParams>(c, "POST", path, summary, status) { p => F() };
}
fn post<R, P, F>(c: Ctx&, path: const u8[:], summary: const u8[:] = "", status: i64 = 200) {
    route<R, P>(c, "POST", path, summary, status, F);
}
fn put<R, F>(c: Ctx&, path: const u8[:], summary: const u8[:] = "", status: i64 = 200) {
    route<R, NoParams>(c, "PUT", path, summary, status) { p => F() };
}
fn put<R, P, F>(c: Ctx&, path: const u8[:], summary: const u8[:] = "", status: i64 = 200) {
    route<R, P>(c, "PUT", path, summary, status, F);
}
fn patch<R, F>(c: Ctx&, path: const u8[:], summary: const u8[:] = "", status: i64 = 200) {
    route<R, NoParams>(c, "PATCH", path, summary, status) { p => F() };
}
fn patch<R, P, F>(c: Ctx&, path: const u8[:], summary: const u8[:] = "", status: i64 = 200) {
    route<R, P>(c, "PATCH", path, summary, status, F);
}
fn delete<R, F>(c: Ctx&, path: const u8[:], summary: const u8[:] = "", status: i64 = 200) {
    route<R, NoParams>(c, "DELETE", path, summary, status) { p => F() };
}
fn delete<R, P, F>(c: Ctx&, path: const u8[:], summary: const u8[:] = "", status: i64 = 200) {
    route<R, P>(c, "DELETE", path, summary, status, F);
}

// A route of any method: matches, binds P, runs the handler and writes its
// result, or, while the app is being described, records itself.
fn route<R, P, F>(c: Ctx&, method: const u8[:], path: const u8[:], summary: const u8[:], status: i64) {
    if c.handled { return; }
    var full: u8[..256] = [];
    full.append(c.prefix);
    full.append(path);
    if c.describing {
        describe_route<R, P>(c, method, full, summary, status);
        return;
    }
    if !match_path(c, full) { return; }
    if c.method != method && !(method == "GET" && c.method == "HEAD") {
        c.path_seen = true;
        return;
    }
    c.handled = true;
    c.status = status;
    // e before p: strings read from the body are views that p keeps, and
    // they are rooted at e.
    var errors: u8[>..] = [];
    var e = Errors { list: errors, scratch: c.scratch };
    var p = P { .. };
    bind_params(c, p, e);
    if e.count > 0 {
        exception::throw(HTTPError { status: 422, detail: str("[", errors, "]"), is_json: true });
    }
    let r: R = F(&p);              // by reference: P may hold a list
    respond(c, r);
}

// Matches c.path against a template, capturing its {name} segments into
// c.params. A {name:path} segment takes the rest of the path.
fn match_path(c: Ctx&, tmpl: u8[:]) -> bool {
    c.params.clear();
    var i = 0;
    var j = 0;
    let path = c.path;
    loop {
        if i >= tmpl.len { return j >= path.len; }
        if j >= path.len { return false; }
        if tmpl[i] != '/' || path[j] != '/' { return false; }
        i++;
        j++;
        let ie = segment_end(tmpl, i);
        let je = segment_end(path, j);
        let t = tmpl[i..ie];
        let s = path[j..je];
        if t.len > 2 && t[0] == '{' && t[t.len - 1] == '}' {
            let name = t[1..t.len - 1];
            if ends_with(name, ":path") {
                add_param(c, name[..name.len - 5], path[j..]);
                return true;
            }
            if s.len == 0 || c.params.len == 8 { return false; }
            add_param(c, name, s);
        } else if t != s {
            return false;
        }
        i = ie;
        j = je;
    }
}

fn segment_end(s: u8[:], from: i64) -> i64 {
    var k = from;
    while k < s.len && s[k] != '/' { k++; }
    return k;
}

fn add_param(c: Ctx&, name: u8[:], value: const u8[:]) {
    var p = Param { name: [], value: value };
    p.name.append(name[..min(name.len, 32)]);
    c.params.push(p);
}

// ------------------------------------------------------------ binding P

fn bind_params<P>(c: Ctx&, p: P&, e: Errors&) {
    const for <N, A> in fields<P> { bind_field(c, N, p.A, e, BY_TYPE); }
}

// The text a scalar field is parsed from: its path parameter, else its
// query parameter. loc is where it came from, for errors.
fn param_text(c: Ctx&, name: const u8[:]) -> const u8[:], bool, const u8[:] {
    let pv, in_path = path_param(c, name);
    if in_path { return pv, true, "path"; }
    let qv, in_query = query_lookup(c, name);
    return qv, in_query, "query";
}

fn param_error(e: Errors&, kind: const u8[:], from: const u8[:], name: const u8[:], msg: const u8[:],
               text: const u8[:]) {
    var loc: u8[>..] = [];
    format(loc, "\"", from, "\",\"", name, "\"");
    var input: u8[>..] = [];
    json::format_string(input, text);
    add_error(e, kind, loc, msg, input);
}

// A scalar, string or enum field: its path or query parameter, parsed by
// type.
fn bind_field(c: Ctx&, name: const u8[:], dst: i64&, e: Errors&, k: i64) { bind_text(c, name, dst, e); }
fn bind_field(c: Ctx&, name: const u8[:], dst: i32&, e: Errors&, k: i64) { bind_text(c, name, dst, e); }
fn bind_field(c: Ctx&, name: const u8[:], dst: f64&, e: Errors&, k: i64) { bind_text(c, name, dst, e); }
fn bind_field(c: Ctx&, name: const u8[:], dst: bool&, e: Errors&, k: i64) { bind_text(c, name, dst, e); }
fn bind_field(c: Ctx&, name: const u8[:], dst: const u8[:]&, e: Errors&, k: i64) { bind_text(c, name, dst, e); }
fn bind_field(c: Ctx&, name: const u8[:], dst: u8[>..]&, e: Errors&, k: i64) { bind_text(c, name, dst, e); }
fn bind_field<E>(c: Ctx&, name: const u8[:], dst: Enum<E>&, e: Errors&, k: i64) { bind_text(c, name, dst, e); }
fn bind_field(c: Ctx&, name: const u8[:], dst: u8[..8]&, e: Errors&, k: i64)    { bind_text(c, name, dst, e); }
fn bind_field(c: Ctx&, name: const u8[:], dst: u8[..16]&, e: Errors&, k: i64)   { bind_text(c, name, dst, e); }
fn bind_field(c: Ctx&, name: const u8[:], dst: u8[..32]&, e: Errors&, k: i64)   { bind_text(c, name, dst, e); }
fn bind_field(c: Ctx&, name: const u8[:], dst: u8[..64]&, e: Errors&, k: i64)   { bind_text(c, name, dst, e); }
fn bind_field(c: Ctx&, name: const u8[:], dst: u8[..128]&, e: Errors&, k: i64)  { bind_text(c, name, dst, e); }
fn bind_field(c: Ctx&, name: const u8[:], dst: u8[..256]&, e: Errors&, k: i64)  { bind_text(c, name, dst, e); }
fn bind_field(c: Ctx&, name: const u8[:], dst: u8[..512]&, e: Errors&, k: i64)  { bind_text(c, name, dst, e); }
fn bind_field(c: Ctx&, name: const u8[:], dst: u8[..1024]&, e: Errors&, k: i64) { bind_text(c, name, dst, e); }
fn bind_field(c: Ctx&, name: const u8[:], dst: u8[..2048]&, e: Errors&, k: i64) { bind_text(c, name, dst, e); }
fn bind_field(c: Ctx&, name: const u8[:], dst: u8[..4096]&, e: Errors&, k: i64) { bind_text(c, name, dst, e); }

fn bind_text(c: Ctx&, name: const u8[:], dst, e: Errors&) {
    let s, found, from = param_text(c, name);
    if found { parse_text(dst, s, e, from, name, BY_TYPE); }
}

// A list field: every query parameter of its name, as in ?tag=a&tag=b.
fn bind_field<T>(c: Ctx&, name: const u8[:], dst: T[>..]&, e: Errors&, k: i64) {
    each_query_value(c, name) { s =>
        let el .= dst.push(default<T>());
        parse_text(el, s, e, "query", name, BY_TYPE);
    };
}

// An Opt field: filled, and set, only when its parameter or body was sent.
fn bind_field<T>(c: Ctx&, name: const u8[:], dst: Opt<T>&, e: Errors&, k: i64) {
    let sent = if is_model(dst.value, BY_TYPE) { trim(c.body).len > 0 && trim(c.body) != "null" }
               else { has_param(c, name) };
    if sent {
        bind_field(c, name, dst.value, e, BY_TYPE);
        dst.set = true;
    }
}

// A model field is the request body.
fn bind_field<T>(c: Ctx&, name: const u8[:], dst: T&, e: Errors&, k: f64) { read_body(c, dst, e); }

fn has_param(c: Ctx&, name: const u8[:]) -> bool {
    let s, found, from = param_text(c, name);
    return found;
}

// Parses parameter text s into dst, by dst's type, or records why not.
fn parse_text(dst: i64&, s: const u8[:], e: Errors&, from: const u8[:], name: const u8[:], k: i64) {
    let v, ok = parse_int(s);
    if ok { dst = v; }
    else { param_error(e, "int_parsing", from, name, "Input should be a valid integer, unable to parse string as an integer", s); }
}

fn parse_text(dst: i32&, s: const u8[:], e: Errors&, from: const u8[:], name: const u8[:], k: i64) {
    let v, ok = parse_int(s);
    if !ok { param_error(e, "int_parsing", from, name, "Input should be a valid integer, unable to parse string as an integer", s); }
    else if v < -2147483648 || v > 2147483647 { param_error(e, "int_too_big", from, name, "Input should fit a 32-bit integer", s); }
    else { dst = v as i32; }
}

fn parse_text(dst: f64&, s: const u8[:], e: Errors&, from: const u8[:], name: const u8[:], k: i64) {
    let v, ok = parse_flt(s);
    if ok { dst = v; }
    else { param_error(e, "float_parsing", from, name, "Input should be a valid number, unable to parse string as a number", s); }
}

fn parse_text(dst: bool&, s: const u8[:], e: Errors&, from: const u8[:], name: const u8[:], k: i64) {
    if s == "true" || s == "1" || s == "yes" || s == "on" || s.len == 0 { dst = true; }
    else if s == "false" || s == "0" || s == "no" || s == "off" { dst = false; }
    else { param_error(e, "bool_parsing", from, name, "Input should be a valid boolean, unable to interpret input", s); }
}

fn parse_text(dst: const u8[:]&, s: const u8[:], e: Errors&, from: const u8[:], name: const u8[:], k: i64) { dst = s; }

fn parse_text(dst: u8[>..]&, s: const u8[:], e: Errors&, from: const u8[:], name: const u8[:], k: i64) { dst.append(s); }

fn parse_text<E>(dst: Enum<E>&, s: const u8[:], e: Errors&, from: const u8[:], name: const u8[:], k: i64) {
    if !enum_parse(s, dst.value) { param_error(e, "enum", from, name, enum_message(dst.value), s); }
}

fn parse_text(dst: u8[..8]&, s: const u8[:], e: Errors&, from: const u8[:], name: const u8[:], k: i64)    { parse_limited(dst, 8, s, e, from, name); }
fn parse_text(dst: u8[..16]&, s: const u8[:], e: Errors&, from: const u8[:], name: const u8[:], k: i64)   { parse_limited(dst, 16, s, e, from, name); }
fn parse_text(dst: u8[..32]&, s: const u8[:], e: Errors&, from: const u8[:], name: const u8[:], k: i64)   { parse_limited(dst, 32, s, e, from, name); }
fn parse_text(dst: u8[..64]&, s: const u8[:], e: Errors&, from: const u8[:], name: const u8[:], k: i64)   { parse_limited(dst, 64, s, e, from, name); }
fn parse_text(dst: u8[..128]&, s: const u8[:], e: Errors&, from: const u8[:], name: const u8[:], k: i64)  { parse_limited(dst, 128, s, e, from, name); }
fn parse_text(dst: u8[..256]&, s: const u8[:], e: Errors&, from: const u8[:], name: const u8[:], k: i64)  { parse_limited(dst, 256, s, e, from, name); }
fn parse_text(dst: u8[..512]&, s: const u8[:], e: Errors&, from: const u8[:], name: const u8[:], k: i64)  { parse_limited(dst, 512, s, e, from, name); }
fn parse_text(dst: u8[..1024]&, s: const u8[:], e: Errors&, from: const u8[:], name: const u8[:], k: i64) { parse_limited(dst, 1024, s, e, from, name); }
fn parse_text(dst: u8[..2048]&, s: const u8[:], e: Errors&, from: const u8[:], name: const u8[:], k: i64) { parse_limited(dst, 2048, s, e, from, name); }
fn parse_text(dst: u8[..4096]&, s: const u8[:], e: Errors&, from: const u8[:], name: const u8[:], k: i64) { parse_limited(dst, 4096, s, e, from, name); }

fn parse_limited<S>(dst: S&, max: i64, s: const u8[:], e: Errors&, from: const u8[:], name: const u8[:]) {
    if s.len > max {
        param_error(e, "string_too_long", from, name, str("String should have at most ", max, " characters"), s);
        return;
    }
    dst.clear();
    dst.append(s);
}

// ------------------------------------------------------------ responses

fn respond(c: Ctx&, r: Html&) {
    c.content_type = "text/html; charset=utf-8";
    c.out.append(r.body);
}
fn respond(c: Ctx&, r: Text&) {
    c.content_type = "text/plain; charset=utf-8";
    c.out.append(r.body);
}
fn respond(c: Ctx&, r: Redirect&) {
    c.status = r.status;
    set_header(c, "location", r.location);
}
fn respond(c: Ctx&, r: NoContent&) { c.status = 204; }
fn respond<T>(c: Ctx&, r: T&) { to_json(c.out, r); }
