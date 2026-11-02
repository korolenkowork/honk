// Models: plain Goose structs that describe requests and responses. A model
// is written out as JSON, read back from a request body with validation,
// and described as a JSON Schema, all by reflection over its fields
// (`const for ... in fields<T>`), so no model needs code of its own.
//
// What a field may be:
//   i8..i64, u8..u32     JSON integer
//   f32, f64             JSON number
//   bool                 JSON boolean
//   const u8[:]          JSON string; a view into the request, no copy
//   u8[..N]              JSON string of at most N bytes (N in CAPS, for reading)
//   u8[], u8[>..]        JSON string (written only)
//   T[k], T[>..], T[:]   JSON array of T (written only)
//   another model        JSON object
//
// A body field is required unless it declares a default that is not its
// type's zero: `price: f64` and `price: f64 = 0.0` are required,
// `price: f64 = 9.99` is not. Goose cannot tell `= 0` from no default, so a
// zero default reads as none. bool fields are never required.
//
// Overload resolution picks the writer for each field type. A model is any
// type the scalar and array overloads do not take, which the trailing
// `k: f64` parameter arranges: the dispatch token BY_TYPE is an i64, and a
// candidate that needs an integer turned into a float is the last one the
// compiler tries (spec 7.1).
namespace honk;

import std;
import math;
import json;

let BY_TYPE: i64 = 0;

// ---------------------------------------------------------------- writing

// Appends v as JSON.
fn to_json(out: u8[>..]&, v) { json_value(out, v, BY_TYPE); }

fn json_value(out: u8[>..]&, v: i64, k: i64) { json::format_int(out, v); }
fn json_value(out: u8[>..]&, v: f64, k: i64) { json::format_number(out, v); }
fn json_value(out: u8[>..]&, v: bool, k: i64) { json::format_bool(out, v); }
fn json_value<T>(out: u8[>..]&, v: T[:], k: i64) { json_seq(out, v); }
fn json_value<T>(out: u8[>..]&, v: T&, k: f64) {
    out.push('{');
    var first = true;
    const for <N, A> in fields<T> {
        if !first { out.push(','); }
        first = false;
        json::format_key(out, N);
        json_value(out, v.A, BY_TYPE);
    }
    out.push('}');
}

fn json_seq(out: u8[>..]&, s: u8[:]) { json::format_string(out, s); }
fn json_seq<T>(out: u8[>..]&, xs: T[:]) {
    out.push('[');
    for &x, i in xs {
        if i > 0 { out.push(','); }
        json_value(out, x, BY_TYPE);
    }
    out.push(']');
}

// ---------------------------------------------------------------- schemas

// Appends the JSON Schema of v's type.
fn schema_of(out: u8[>..]&, v) {
    out.push('{');
    schema_body(out, v, BY_TYPE);
    out.push('}');
}

// The members of a schema, without its braces, so that callers can add
// "default" and "title" before they close it.
fn schema_body(out: u8[>..]&, v: i64, k: i64) { out.append("\"type\":\"integer\""); }
fn schema_body(out: u8[>..]&, v: f64, k: i64) { out.append("\"type\":\"number\""); }
fn schema_body(out: u8[>..]&, v: bool, k: i64) { out.append("\"type\":\"boolean\""); }
fn schema_body(out: u8[>..]&, v: u8[..8], k: i64)   { schema_str(out, 8); }
fn schema_body(out: u8[>..]&, v: u8[..16], k: i64)  { schema_str(out, 16); }
fn schema_body(out: u8[>..]&, v: u8[..32], k: i64)  { schema_str(out, 32); }
fn schema_body(out: u8[>..]&, v: u8[..64], k: i64)  { schema_str(out, 64); }
fn schema_body(out: u8[>..]&, v: u8[..128], k: i64) { schema_str(out, 128); }
fn schema_body(out: u8[>..]&, v: u8[..256], k: i64) { schema_str(out, 256); }
fn schema_body<T>(out: u8[>..]&, v: T[:], k: i64) { schema_seq(out, v); }
fn schema_body<T>(out: u8[>..]&, v: T&, k: f64) {
    var d = T { .. };
    out.append("\"type\":\"object\",\"properties\":{");
    var first = true;
    const for <N, A> in fields<T> {
        if !first { out.push(','); }
        first = false;
        json::format_key(out, N);
        field_schema(out, N, d.A, !required_field(d.A, BY_TYPE));
    }
    out.append("},\"required\":[");
    first = true;
    const for <N, A> in fields<T> {
        if required_field(d.A, BY_TYPE) {
            if !first { out.push(','); }
            first = false;
            json::format_string(out, N);
        }
    }
    out.push(']');
}

// The schema of one field or parameter, titled from its name
// ("unit_price" is "Unit Price"), with its default when it has one.
fn field_schema(out: u8[>..]&, name: const u8[:], v, with_default: bool) {
    out.push('{');
    schema_body(out, v, BY_TYPE);
    if with_default {
        out.append(",\"default\":");
        json_value(out, v, BY_TYPE);
    }
    out.append(",\"title\":\"");
    var up = true;
    for ch in name {
        if ch == '_' { out.push(' '); up = true; continue; }
        out.push(if up && ch >= 'a' && ch <= 'z' { ch - 32 } else { ch });
        up = false;
    }
    out.append("\"}");
}

fn schema_str(out: u8[>..]&, max: i64) { format(out, "\"type\":\"string\",\"maxLength\":", max); }

fn schema_seq(out: u8[>..]&, s: u8[:]) { out.append("\"type\":\"string\""); }
fn schema_seq<T>(out: u8[>..]&, xs: T[:]) {
    let d = default<T>();
    out.append("\"type\":\"array\",\"items\":");
    schema_of(out, d);
}

// Whether a field whose value in `T { .. }` is v must be sent.
fn required_field(v: i64, k: i64) -> bool { v == 0 }
fn required_field(v: f64, k: i64) -> bool { v == 0.0 }
fn required_field(v: bool, k: i64) -> bool { false }
fn required_field<T>(v: T[:], k: i64) -> bool { v.len == 0 }
fn required_field<T>(v: T&, k: f64) -> bool { true }

// ---------------------------------------------------------------- reading

// Where validation errors go while a request is read. The errors are the
// items of the 422 "detail" array, without the brackets.
struct Errors { list: u8[>..]&, count: i64 = 0, scratch: u8[>..]& }

// Records a validation error. loc is the JSON of the location's parts,
// `"body","price"`; input is the offending value's JSON text.
fn add_error(e: Errors&, kind: const u8[:], loc: u8[:], msg: u8[:], input: u8[:]) {
    if e.count > 0 { e.list.push(','); }
    e.count++;
    e.list.append("{\"type\":");
    json::format_string(e.list, kind);
    format(e.list, ",\"loc\":[", loc, "],\"msg\":");
    json::format_string(e.list, msg);
    e.list.append(",\"input\":");
    e.list.append(if input.len > 0 { input } else { "null" });
    e.list.push('}');
}

// Reads the JSON request body into dst, a model, recording what is wrong
// with it in e.
fn read_body<T>(c: Ctx&, dst: T&, e: Errors&) {
    if trim(c.body).len == 0 {
        add_error(e, "missing", "\"body\"", "Field required", "");
        return;
    }
    var check = json::reader(c.body);
    json::skip(check);
    if !json::finish(check) {
        var loc: u8[>..] = [];
        format(loc, "\"body\",", check.error_at);
        add_error(e, "json_invalid", loc, "JSON decode error", "");
        return;
    }
    var r = json::reader(c.body);
    read_value(r, dst, e, "\"body\"", BY_TYPE);
}

// The JSON text of the value at the cursor, consumed.
fn skip_input(r: json::Reader&) -> const u8[:] {
    json::peek(r);
    let at = r.pos;
    json::skip(r);
    return trim(r.text[at..r.pos]);
}

fn is_number_start(ch: u8) -> bool { ch == '-' || (ch >= '0' && ch <= '9') }

fn read_value(r: json::Reader&, dst: i64&, e: Errors&, loc: u8[:], k: i64) {
    let ch = json::peek(r);
    guard is_number_start(ch) else {
        add_error(e, "int_type", loc, "Input should be a valid integer", skip_input(r));
        return;
    }
    let at = r.pos;
    let v = json::read_number(r);
    if v != floor(v) {
        add_error(e, "int_from_float", loc, "Input should be a valid integer, got a number with a fractional part",
                  trim(r.text[at..r.pos]));
        return;
    }
    if v < -9.0e18 || v > 9.0e18 {
        add_error(e, "int_too_big", loc, "Input should fit a 64-bit integer", trim(r.text[at..r.pos]));
        return;
    }
    dst = v as i64;
}

fn read_value(r: json::Reader&, dst: i32&, e: Errors&, loc: u8[:], k: i64) {
    var wide: i64 = 0;
    read_value(r, wide, e, loc, k);
    if wide < -2147483648 || wide > 2147483647 {
        add_error(e, "int_too_big", loc, "Input should fit a 32-bit integer", "");
        return;
    }
    dst = wide as i32;
}

fn read_value(r: json::Reader&, dst: f64&, e: Errors&, loc: u8[:], k: i64) {
    guard is_number_start(json::peek(r)) else {
        add_error(e, "float_type", loc, "Input should be a valid number", skip_input(r));
        return;
    }
    dst = json::read_number(r);
}

fn read_value(r: json::Reader&, dst: f32&, e: Errors&, loc: u8[:], k: i64) {
    var wide = 0.0;
    read_value(r, wide, e, loc, k);
    dst = wide as f32;
}

fn read_value(r: json::Reader&, dst: bool&, e: Errors&, loc: u8[:], k: i64) {
    let ch = json::peek(r);
    guard ch == 't' || ch == 'f' else {
        add_error(e, "bool_type", loc, "Input should be a valid boolean", skip_input(r));
        return;
    }
    dst = json::read_bool(r);
}

fn read_value(r: json::Reader&, dst: const u8[:]&, e: Errors&, loc: u8[:], k: i64) {
    guard json::peek(r) == '"' else {
        add_error(e, "string_type", loc, "Input should be a valid string", skip_input(r));
        return;
    }
    // The reader's result is rooted at the reader, a local; a copy in the
    // request's scratch lives as long as the request.
    let s = json::read_string(r, e.scratch);
    let at = e.scratch.len;
    e.scratch.append(s);
    dst = e.scratch[at..];
}

fn read_value(r: json::Reader&, dst: u8[..8]&, e: Errors&, loc: u8[:], k: i64)   { read_limited(r, dst, 8, e, loc); }
fn read_value(r: json::Reader&, dst: u8[..16]&, e: Errors&, loc: u8[:], k: i64)  { read_limited(r, dst, 16, e, loc); }
fn read_value(r: json::Reader&, dst: u8[..32]&, e: Errors&, loc: u8[:], k: i64)  { read_limited(r, dst, 32, e, loc); }
fn read_value(r: json::Reader&, dst: u8[..64]&, e: Errors&, loc: u8[:], k: i64)  { read_limited(r, dst, 64, e, loc); }
fn read_value(r: json::Reader&, dst: u8[..128]&, e: Errors&, loc: u8[:], k: i64) { read_limited(r, dst, 128, e, loc); }
fn read_value(r: json::Reader&, dst: u8[..256]&, e: Errors&, loc: u8[:], k: i64) { read_limited(r, dst, 256, e, loc); }

fn read_limited<S>(r: json::Reader&, dst: S&, max: i64, e: Errors&, loc: u8[:]) {
    guard json::peek(r) == '"' else {
        add_error(e, "string_type", loc, "Input should be a valid string", skip_input(r));
        return;
    }
    let at = r.pos;
    let s = json::read_string(r, e.scratch);
    if s.len > max {
        add_error(e, "string_too_long", loc, str("String should have at most ", max, " characters"),
                  trim(r.text[at..r.pos]));
        return;
    }
    dst.clear();
    dst.append(s);
}

// A nested model: an object whose members are matched to the fields by
// name. Unknown members are ignored and `null` leaves a field as it is.
fn read_value<T>(r: json::Reader&, dst: T&, e: Errors&, loc: u8[:], k: f64) {
    guard json::peek(r) == '{' else {
        add_error(e, "model_attributes_type", loc, "Input should be a valid dictionary or object", skip_input(r));
        return;
    }
    var seen: bool[64] = [false; 64];
    json::each_member(r) { key =>
        var i = 0;
        var matched = false;
        const for <N, A> in fields<T> {
            if !matched && key == N {
                matched = true;
                seen[i] = true;
                if json::peek(r) == 'n' { json::skip(r); }
                else {
                    var at: u8[>..] = [];
                    format(at, loc, ",\"", N, "\"");
                    read_value(r, dst.A, e, at, BY_TYPE);
                }
            }
            i++;
        }
        if !matched { json::skip(r); }
    };
    var d = T { .. };
    var i = 0;
    const for <N, A> in fields<T> {
        if !seen[i] && required_field(d.A, BY_TYPE) {
            var at: u8[>..] = [];
            format(at, loc, ",\"", N, "\"");
            add_error(e, "missing", at, "Field required", "");
        }
        i++;
    }
}
