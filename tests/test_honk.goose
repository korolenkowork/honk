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
        expect_has("openapi status", s, b, 200, "\"201\":{\"description\":\"Successful Response\"");
    }
    if failures > 0 { print(failures, " failed"); exit(1); }
    print("all passed");
}
