// Honk's tests, through honk::request: in-process, no sockets.
//
//     goose tests/test_honk.goose
import honk from "../honk";
import std;

struct Point { x: i64, y: i64 }
struct Shape { name: u8[..16], origin: Point, scale: f64 = 1.0, visible: bool }
struct Echo { shape: Shape }
struct Pid { id: i64, verbose: bool = false, label: const u8[:] = "none" }
struct PidOut { id: i64, verbose: bool, label: const u8[:] }
struct FileOut { path: const u8[:] }
struct FilePath { file: const u8[:] }
struct Ok { ok: bool }
struct Who { name: const u8[:] }
struct Note { text: const u8[:], stars: i32 = 3 }
struct AddNote { note: Note }
struct ById { id: i64 }

enum Size { Small, Medium, Large }
struct Order {
    size: honk::Enum<Size>,
    note: honk::Opt<u8[..512]>,
    tip: honk::Opt<f64> = honk::opt(1.5),
    toppings: const u8[:][>..],
}
struct PlaceOrder { order: Order }
struct Search { size: honk::Opt<honk::Enum<Size>>, tag: const u8[:][>..] }
struct Found { tags: i64, first: const u8[:], size: const u8[:] }
struct Patch { name: honk::Opt<u8[..16]>, stars: honk::Opt<i64> }
struct PatchNote { id: i64, patch: honk::Opt<Patch> }
struct Patched { id: i64, had_body: bool, name: honk::Opt<u8[..16]>, stars: honk::Opt<i64> }

fn caller(c: honk::Ctx&) -> Who {
    let token, sent = honk::header(c, "X-Token");
    guard sent && token == "s3cret" else { honk::raise(401, "Invalid X-Token header"); }
    return Who { name: "goose" };
}

fn admin(c: honk::Ctx&) {
    honk::get<Ok>(c, "/ping") { Ok { ok: true } };
}

fn app(c: honk::Ctx&) {
    honk::get<Ok>(c, "/") { Ok { ok: true } };
    honk::get<PidOut, Pid>(c, "/things/{id}") { p => PidOut { id: p.id, verbose: p.verbose, label: p.label } };
    honk::post<Shape, Echo>(c, "/shapes", "", 201) { p => p.shape };
    honk::get<FileOut, FilePath>(c, "/files/{file:path}") { p => FileOut { path: p.file } };
    honk::get<Ok>(c, "/teapot") { honk::raise(418, "I'm a teapot"); };
    honk::get<honk::Text>(c, "/text") { honk::Text { body: "plain" } };
    honk::delete<honk::NoContent>(c, "/gone") { honk::NoContent {} };
    honk::get<honk::Redirect>(c, "/old") { honk::Redirect { location: "/" } };
    honk::get<Who>(c, "/me") { caller(c) };
    honk::post<Note, AddNote>(c, "/notes") { p => p.note };
    honk::post<Found, PlaceOrder>(c, "/orders") { p =>
        Found { tags: p.order.toppings.len, first: if p.order.toppings.len > 0 { p.order.toppings[0] } else { "" },
                size: honk::enum_name(p.order.size.value) }
    };
    honk::get<Found, Search>(c, "/search") { p =>
        Found { tags: p.tag.len, first: if p.tag.len > 0 { p.tag[0] } else { "" },
                size: if p.size.set { honk::enum_name(p.size.value.value) } else { "any" } }
    };
    honk::patch<Patched, PatchNote>(c, "/notes/{id}") { p =>
        Patched { id: p.id, had_body: p.patch.set, name: p.patch.value.name, stars: p.patch.value.stars }
    };
    honk::get<Ok, ById>(c, "/notes/{id}") { p => honk::raise(404, str("Note ", p.id, " not found")); };
    honk::include(c, "/admin", "admin", admin);
}

var failures = 0;

fn expect(name: const u8[:], status: i64, body: u8[:], want_status: i64, want_body: const u8[:]) {
    if status == want_status && body == want_body {
        print("  ok    ", name);
    } else {
        failures++;
        print("  FAIL  ", name, "\n        got  ", status, " ", body, "\n        want ", want_status, " ", want_body);
    }
}

fn expect_has(name: const u8[:], status: i64, body: u8[:], want_status: i64, part: const u8[:]) {
    if status == want_status && find(body, part) >= 0 {
        print("  ok    ", name);
    } else {
        failures++;
        print("  FAIL  ", name, "\n        got  ", status, " ", body, "\n        want ", want_status, " containing ", part);
    }
}

fn main() {
    print("honk tests");
    {
        let s, b = honk::request("GET", "/", app);
        expect("root", s, b, 200, "{\"ok\":true}");
    }
    {
        let s, b = honk::request("GET", "/things/7?verbose=true&label=hello%20world", app);
        expect("path and query params", s, b, 200, "{\"id\":7,\"verbose\":true,\"label\":\"hello world\"}");
    }
    {
        let s, b = honk::request("GET", "/things/7/", app);
        expect("trailing slash", s, b, 200, "{\"id\":7,\"verbose\":false,\"label\":\"none\"}");
    }
    {
        let s, b = honk::request("GET", "/things/x", app);
        expect_has("bad path param", s, b, 422, "\"loc\":[\"path\",\"id\"]");
    }
    {
        let s, b = honk::request("GET", "/things/1?verbose=maybe", app);
        expect_has("bad query param", s, b, 422, "\"type\":\"bool_parsing\"");
    }
    {
        let s, b = honk::request("POST", "/shapes", "{\"name\":\"sq\",\"origin\":{\"x\":1,\"y\":2},\"visible\":true}", app);
        expect("body model", s, b, 201, "{\"name\":\"sq\",\"origin\":{\"x\":1,\"y\":2},\"scale\":1.0,\"visible\":true}");
    }
    {
        let s, b = honk::request("POST", "/shapes", "{\"name\":\"sq\",\"origin\":{\"x\":1.5}}", app);
        expect_has("nested validation: float for int", s, b, 422, "\"type\":\"int_from_float\",\"loc\":[\"body\",\"origin\",\"x\"]");
        expect_has("nested validation: missing", s, b, 422, "\"type\":\"missing\",\"loc\":[\"body\",\"origin\",\"y\"]");
    }
    {
        let s, b = honk::request("POST", "/shapes", "", app);
        expect_has("missing body", s, b, 422, "\"type\":\"missing\",\"loc\":[\"body\"]");
    }
    {
        let s, b = honk::request("POST", "/shapes", "[1,2", app);
        expect_has("broken json", s, b, 422, "json_invalid");
    }
    {
        let s, b = honk::request("POST", "/shapes", "{\"name\":\"a\\\"b\",\"origin\":{\"x\":0,\"y\":0}}", app);
        expect_has("escaped strings", s, b, 201, "\"name\":\"a\\\"b\"");
    }
    {
        let s, b = honk::request("GET", "/files/a/b/c.txt", app);
        expect("path converter", s, b, 200, "{\"path\":\"a/b/c.txt\"}");
    }
    {
        let s, b = honk::request("GET", "/teapot", app);
        expect("raise", s, b, 418, "{\"detail\":\"I'm a teapot\"}");
    }
    {
        let s, b = honk::request("GET", "/text", app);
        expect("text response", s, b, 200, "plain");
    }
    {
        let s, b = honk::request("DELETE", "/gone", app);
        expect("204", s, b, 204, "");
    }
    {
        let s, b = honk::request("GET", "/old", app);
        expect("redirect", s, b, 307, "");
    }
    {
        let s, b = honk::request("GET", "/admin/ping", app);
        expect("router prefix", s, b, 200, "{\"ok\":true}");
    }
    {
        let s, b = honk::request("GET", "/me", "", "x-token: s3cret\r\n", app);
        expect("header dependency", s, b, 200, "{\"name\":\"goose\"}");
        let s2, b2 = honk::request("GET", "/me", app);
        expect("header dependency refuses", s2, b2, 401, "{\"detail\":\"Invalid X-Token header\"}");
    }
    {
        let s, b = honk::request("POST", "/notes", "{\"text\":\"line\\none \\u00e9\",\"stars\":5}", app);
        expect("body string views, escapes decoded", s, b, 200, "{\"text\":\"line\\none é\",\"stars\":5}");
        let s2, b2 = honk::request("POST", "/notes", "{\"text\":1,\"stars\":9999999999}", app);
        expect_has("string_type", s2, b2, 422, "\"type\":\"string_type\"");
        expect_has("i32 range", s2, b2, 422, "\"type\":\"int_too_big\"");
    }
    {
        let s, b = honk::request("GET", "/notes/12", app);
        expect("raise with a built message", s, b, 404, "{\"detail\":\"Note 12 not found\"}");
    }
    {
        let s, b = honk::request("POST", "/orders", "{\"size\":\"Large\",\"toppings\":[\"ham\",\"egg\"]}", app);
        expect("enum and list in body", s, b, 200, "{\"tags\":2,\"first\":\"ham\",\"size\":\"Large\"}");
        let s2, b2 = honk::request("POST", "/orders", "{\"size\":\"Huge\",\"toppings\":[\"ham\",3]}", app);
        expect_has("bad enum", s2, b2, 422, "\"type\":\"enum\",\"loc\":[\"body\",\"size\"],\"msg\":\"Input should be 'Small', 'Medium' or 'Large'\"");
        expect_has("bad list element", s2, b2, 422, "\"loc\":[\"body\",\"toppings\",1]");
        let s3, b3 = honk::request("POST", "/orders", "{\"toppings\":[]}", app);
        expect_has("enum is required", s3, b3, 422, "\"type\":\"missing\",\"loc\":[\"body\",\"size\"]");
        var long: u8[>..] = [];
        long.append("{\"size\":\"Small\",\"note\":\"");
        for i in 600 { long.push('x'); }
        long.append("\"}");
        let s4, b4 = honk::request("POST", "/orders", long, app);
        expect_has("u8[..512] limit", s4, b4, 422, "at most 512 characters");
    }
    {
        let s, b = honk::request("GET", "/search?tag=a%20b&tag=c&size=Medium", app);
        expect("query list and optional enum", s, b, 200, "{\"tags\":2,\"first\":\"a b\",\"size\":\"Medium\"}");
        let s2, b2 = honk::request("GET", "/search", app);
        expect("empty query list, unset Opt", s2, b2, 200, "{\"tags\":0,\"first\":\"\",\"size\":\"any\"}");
    }
    {
        let s, b = honk::request("PATCH", "/notes/4", "{\"stars\":5,\"name\":null}", app);
        expect("Opt fields: sent, null", s, b, 200, "{\"id\":4,\"had_body\":true,\"name\":null,\"stars\":5}");
        let s2, b2 = honk::request("PATCH", "/notes/4", app);
        expect("optional body", s2, b2, 200, "{\"id\":4,\"had_body\":false,\"name\":null,\"stars\":null}");
    }
    {
        let s, b = honk::request("HEAD", "/", app);
        expect("HEAD uses GET routes", s, b, 200, "{\"ok\":true}");
    }
    {
        let s, b = honk::request("GET", "/nowhere", app);
        expect("404", s, b, 404, "{\"detail\":\"Not Found\"}");
    }
    {
        let s, b = honk::request("PUT", "/", app);
        expect("405", s, b, 405, "{\"detail\":\"Method Not Allowed\"}");
    }
    {
        let s, b = honk::request("GET", "/openapi.json", app);
        expect_has("openapi path param", s, b, 200, "{\"name\":\"id\",\"in\":\"path\",\"required\":true");
        expect_has("openapi query default", s, b, 200, "\"default\":\"none\",\"title\":\"Label\"");
        expect_has("openapi body", s, b, 200, "\"requestBody\":{\"required\":true");
        expect_has("openapi required", s, b, 200, "\"required\":[\"name\",\"origin\"]");
        expect_has("openapi maxLength", s, b, 200, "\"maxLength\":16");
        expect_has("openapi tags", s, b, 200, "\"tags\":[\"admin\"]");
        expect_has("openapi enum", s, b, 200, "\"enum\":[\"Small\",\"Medium\",\"Large\"]");
        expect_has("openapi Opt", s, b, 200, "\"anyOf\":[{\"type\":\"number\"},{\"type\":\"null\"}],\"default\":1.5");
        expect_has("openapi optional body", s, b, 200, "\"requestBody\":{\"required\":false");
        expect_has("openapi query list", s, b, 200, "{\"name\":\"tag\",\"in\":\"query\",\"required\":false,\"schema\":{\"type\":\"array\"");
        expect_has("openapi status", s, b, 200, "\"201\":{\"description\":\"Successful Response\"");
    }
    if failures > 0 { print(failures, " failed"); exit(1); }
    print("all passed");
}
