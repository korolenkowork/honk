# The Honk guide

This guide covers every Honk feature in the order you are likely to need
it. Each section shows how to do something and why it is done that way in
Goose.
The complete program behind most examples is
[`examples/items.goose`](../examples/items.goose).

<details>
<summary>Contents</summary>

- [1. The app function](#1-the-app-function)
- [2. Routes](#2-routes)
- [3. Path parameters](#3-path-parameters)
- [4. Query parameters](#4-query-parameters)
- [5. Request bodies](#5-request-bodies)
- [6. Models](#6-models)
- [7. Validation errors](#7-validation-errors)
- [8. Responses](#8-responses)
- [9. Errors: `honk::raise`](#9-errors-honkraise)
- [10. Headers](#10-headers)
- [11. Dependencies](#11-dependencies)
- [12. Bigger applications: routers](#12-bigger-applications-routers)
- [13. State and storage](#13-state-and-storage)
- [14. Threads, shared state and background jobs](#14-threads-shared-state-and-background-jobs)
- [15. OpenAPI and the docs pages](#15-openapi-and-the-docs-pages)
- [16. Testing](#16-testing)
- [17. Configuration and deployment](#17-configuration-and-deployment)
- [18. How Honk works](#18-how-honk-works)

</details>

---

## 1. The app function

Goose has no decorators and cannot store functions, so a Honk app is not
an object that routes are registered on. It is a function that declares its
routes:

```goose
fn app(c: honk::Ctx&) {
    honk::get<Hello>(c, "/") { Hello { message: "Honk!" } };
    honk::get<Item, ReadItem>(c, "/items/{item_id}") { p => ... };
}

fn main() {
    honk::serve(honk::Config { port: 8000, .. }, app);
}
```

`serve` calls `app` once per request. Each route declaration checks the
method and path, and the first route that matches runs and marks the
request handled. Routes declared after it return at once. If no route
matches, the answer is 404, or 405 when a route matched the path but not
the method.

`serve` also calls `app` once at startup with `c.describing` set. In that
mode each route records itself for the OpenAPI schema instead of matching.
For this reason `app` should only declare routes: work done outside a route
block runs during the describe pass and again on every request.

Matching is linear in the number of routes. That holds up well past
hundreds of routes, because each check is a byte comparison against a
string literal.

## 2. Routes

Each method has two forms:

```goose
honk::get<R>(c, path) { ... }                // no params
honk::get<R, P>(c, path) { p => ... }        // a params struct
```

`post`, `put`, `patch` and `delete` take the same forms. `HEAD` requests
are answered by `GET` routes. Two optional arguments follow the path:

```goose
honk::post<Item, CreateItem>(c, "/items", "Create an item", 201) { p => ... };
//                                        summary          status
```

* **`R`** is the response type: a model, which is sent as JSON, or one of
  the response types in [section 8](#8-responses). The block must produce
  an `R`, and the compiler checks that it does.
* **`P`** is the params struct ([sections 3 to 5](#3-path-parameters)).
* The **block** is the handler. It sees everything in scope where it is
  written: `c`, your globals, and the locals of `app`. A `return` inside it
  would return from `app`, so the block hands back its response as its
  trailing expression:

```goose
honk::get<Stats>(c, "/stats") {
    var s = Stats { count: items.len, total: 0.0 };
    for x in items { s.total += x.price; }
    s                                   // the response
};
```

Handlers are blocks passed as static function values, so a route compiles
to a direct call with nothing to look up at run time.

Paths are matched after percent-decoding, and a trailing slash is ignored:
`/items/` matches `/items`.

## 3. Path parameters

Write `{name}` in the path and give the params struct a field of that name:

```goose
struct ReadItem { item_id: i64 }

honk::get<Item, ReadItem>(c, "/items/{item_id}") { p =>
    items[find_item(p.item_id)]
};
```

The field's type is the parameter's type. `/items/abc` is answered with 422
before the block runs:

```json
{"detail":[{"type":"int_parsing","loc":["path","item_id"],"msg":"Input should be a valid integer, unable to parse string as an integer","input":"abc"}]}
```

`{name:path}` matches the rest of the path, slashes included:

```goose
struct FilePath { file: const u8[:] }
honk::get<FileOut, FilePath>(c, "/files/{file:path}") { p => FileOut { path: p.file } };
// GET /files/a/b/c.txt  ->  {"path":"a/b/c.txt"}
```

A route can capture up to 8 path parameters. `honk::path_param(c, "name")`
reads one by name without a params struct.

## 4. Query parameters

A field that is neither in the path nor a model comes from the query string.
Its declared default is used when the request leaves it out:

```goose
struct ListItems { skip: i64 = 0, limit: i64 = 10, q: const u8[:] = "" }

honk::get<ItemList, ListItems>(c, "/items") { p => ... };
// GET /items?limit=2&q=goose
```

Query values are percent-decoded, and `+` decodes to a space. Booleans
accept `true/false`, `1/0`, `yes/no` and `on/off`, and a bare `?flag` means
true. A value that does not parse is answered with 422 at
`["query", name]`. A query parameter that is never sent is not an error:
the field keeps its default.

A list field takes every value of a repeated parameter, and an `Opt` field
records whether the parameter was sent at all (see
[Optional values](#optional-values-honkopt)):

```goose
struct Search { size: honk::Opt<honk::Enum<Size>>, tag: const u8[:][>..] }
// GET /search?tag=red&tag=blue&size=Large
```

A list must be the struct's last field, because Goose allows one growable
array per struct, at its end.

`honk::query_param(c, "name")` reads a query parameter directly.

## 5. Request bodies

A field whose type is a struct is the JSON request body. Other fields of
the same params struct can still come from the path and the query:

```goose
struct ItemIn { name: u8[..32], price: f64, tax: f64 = 0.2, size: Dimensions }
struct UpdateItem { item_id: i64, item: ItemIn }        // path + body

honk::put<Item, UpdateItem>(c, "/items/{item_id}") { p =>
    let i = find_item(p.item_id);
    items[i] = store(p.item_id, p.item);
    items[i]
};
```

The body is validated against the model before the block runs, and the
errors' `loc` starts with `"body"`. A request with no body
gets `{"type":"missing","loc":["body"]}`, and malformed JSON gets
`json_invalid` with the byte offset. Unknown members are ignored. A `null`
member unsets an `Opt` field and leaves any other field at its default.

Only one field should be a model. To make the whole body optional, wrap it:
`patch: honk::Opt<ItemPatch>` is unset when the request has no body (or a
body of `null`), and the docs mark the body as not required. Bodies are limited to
`Config.max_body` bytes (1 MiB by default), and a larger request is
answered with 413.

## 6. Models

A model is a plain Goose struct. Honk reads it with `const for ... in
fields<T>`, Goose's compile-time reflection, so a model needs no
registration, base type or generated code.

| Field type | JSON | In a request | In a response |
|---|---|---|---|
| `i64`, `i32` (and narrower integers in responses) | integer | yes | yes |
| `f64`, `f32` | number | yes | yes |
| `bool` | boolean | yes | yes |
| `const u8[:]` | string | yes: a view into the request, nothing copied | yes |
| `u8[..N]`, N = 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096 | string, `maxLength: N` | yes: longer input is a 422 | yes |
| `u8[..N]`, any other N | string | no | yes |
| `u8[>..]` | string | yes, as the last field | yes |
| `u8[]` | string | no | yes |
| `T[>..]` | array of T | yes, as the last field | yes |
| `T[k]`, `T[:]` | array of T | no | yes |
| `honk::Opt<T>` | T or `null` | yes, never required | yes |
| `honk::Enum<E>` | string naming a variant | yes | yes |
| another model | object | yes | yes |

The two string kinds are for different jobs. `u8[..32]` keeps its bytes
inside the struct, so the struct stays fixed-size and you can store it in
an array or a global. `const u8[:]` is a view, which suits params and
responses that only pass through text that already exists.

### Required and optional fields

Ideally a field would be required exactly when it has no default, but Goose
reflection cannot see whether a field declares one. Honk instead compares
each field of `T { .. }` with its type's zero value:

* `price: f64` is required, and so is `price: f64 = 0.0`.
* `tax: f64 = 0.2` is optional, with default 0.2.
* `description: u8[..128] = "No description"` is optional, but
  `= ""` would make it required.
* `bool` fields are never required, because `false` is a reasonable
  default.
* `honk::Opt<T>` and list (`T[>..]`) fields are never required.
* `honk::Enum<E>` fields and nested models are required.

When the zero rule gets a field wrong (it should be optional, but its
default is zero or empty), make it a `honk::Opt`.

The schema in `/openapi.json` follows the same rules, so the docs always
match what the server enforces. This applies to bodies only. A query field
is always optional and falls back to its default.

### Optional values: `honk::Opt`

```goose
struct Opt<T> { set: bool = false, value: T }
```

An `Opt` field may be left out or sent as `null`, and `set` tells the
handler which happened. That is what partial updates need:

```goose
struct ItemPatch { name: honk::Opt<u8[..32]>, price: honk::Opt<f64>, in_stock: honk::Opt<bool> }
struct PatchItem { item_id: i64, patch: ItemPatch }

honk::patch<Item, PatchItem>(c, "/items/{item_id}") { p =>
    let i = find_item(p.item_id);
    if p.patch.name.set { items[i].name = p.patch.name.value; }
    if p.patch.price.set { items[i].price = p.patch.price.value; }
    items[i]
};
```

`honk::opt(v)` gives an `Opt` a default value: `tax: honk::Opt<f64> =
honk::opt(0.2)` is 0.2 until the client sends another number, or `null`
to unset it. In a response, an unset `Opt` is written as `null`, and its
schema is `anyOf` the value's schema and `null`.

### Enums: `honk::Enum`

A Goose enum whose variants have no payloads can be a string field:

```goose
enum Category { Tool, Toy, Food }
struct ItemIn { name: u8[..32], category: honk::Enum<Category> }
```

The field is sent and answered as the variant's name, `"Toy"`, and the
docs list the names as the schema's `enum`. Anything else is a 422 with
type `enum` and the message `Input should be 'Tool', 'Toy' or 'Food'`. The
variant is `p.item.category.value`; `honk::enum_name(v)` gives its name.

### Lists in requests

A `T[>..]` field reads a JSON array, element by element, and an error in
one element names its index: `["body","tags",1]`. Goose allows one
growable array per struct, as its last field:

```goose
struct Order { size: honk::Enum<Size>, toppings: const u8[:][>..] }
```

A struct holding a list is not fixed-size, so it cannot be stored in an
indexable array. Read what you need from it in the handler.

### Lists in responses

A response can contain arrays. Return a model that holds one:

```goose
struct ItemList { total: i64, items: Item[>..] }

honk::get<ItemList, ListItems>(c, "/items") { p =>
    var page = ItemList { total: 0, items: [] };
    for &x in items {
        if page.total >= p.skip && page.items.len < p.limit { page.items.push(x); }
        page.total++;
    }
    page
};
```

Build the value in place, as `page` is built here. `ItemList { items: page_items }`
would have to copy a growable array, which Goose only does when you ask
with `copy(...)`.

## 7. Validation errors

Every validation failure is collected, not just the first, and the request
is answered once with all of them:

```bash
curl -X POST localhost:8000/items -d '{"name":"Egg","price":"cheap","category":"Food","size":{"width":2}}'
```

```json
{"detail":[
  {"type":"float_type","loc":["body","price"],"msg":"Input should be a valid number","input":"cheap"},
  {"type":"missing","loc":["body","size","height"],"msg":"Field required","input":null}
]}
```

Each error's `type` is a stable, machine-readable name that clients can
branch on: `missing`, `int_type`, `int_parsing`, `int_from_float`,
`int_too_big`, `float_type`, `float_parsing`, `bool_type`, `bool_parsing`,
`string_type`, `string_too_long`, `enum`, `list_type`,
`model_attributes_type`, `json_invalid`.

Rules that types cannot express, such as "price must be positive", belong
in the handler:

```goose
if p.item.price <= 0.0 { honk::raise(400, "price must be positive"); }
```

## 8. Responses

| Response type | Content-Type | Example |
|---|---|---|
| any model | `application/json` | `Item { ... }` |
| `honk::Html` | `text/html` | `honk::Html { body: str("<h1>", title, "</h1>") }` |
| `honk::Text` | `text/plain` | `honk::Text { body: "pong" }` |
| `honk::Redirect` | none (307 by default) | `honk::Redirect { location: "/docs" }` |
| `honk::NoContent` | none (204) | `honk::NoContent {}` |

```goose
honk::get<honk::Html>(c, "/") {
    honk::Html { body: str("<h1>Honk!</h1><p>", items.len, " items</p>") }
};
honk::delete<honk::NoContent>(c, "/cache") { clear_cache(); honk::NoContent {} };
```

A handler can also set the status, the content type and response headers
directly through `c`:

```goose
c.status = 202;
honk::set_header(c, "cache-control", "no-store");
```

The status argument on the route (`201` in `post<...>(c, path, summary, 201)`)
is the default, and setting `c.status` in the block overrides it.

## 9. Errors: `honk::raise`

`honk::raise(status, detail)` stops the handler and answers `{"detail": detail}`:

```goose
fn find_item(id: i64) -> i64 {
    for x, i in items { if x.id == id { return i; } }
    honk::raise(404, "Item not found");
}
```

`raise` works from any depth of calls under a route block. It is built on
Goose's `return ... from`, which the compiler checks statically: a
function that may raise must only be called from code running under a
route. `find_item` above declares an `i64` result, yet it can end in
`raise`, because the compiler knows `raise` does not return.

Anything the handler wrote to the response before raising is discarded.

## 10. Headers

```goose
let token, sent = honk::header(c, "x-token");     // case-insensitive
honk::set_header(c, "x-request-id", "42");
```

`header` returns a view into the request and a flag saying whether the
header was present.

## 11. Dependencies

A dependency is a value that several handlers need computed the same way,
such as the current user. In Honk a dependency is an ordinary function that takes the context, and the
handler calls it:

```goose
struct User { username: const u8[:], admin: bool }

fn current_user(c: honk::Ctx&) -> User {
    let token, sent = honk::header(c, "x-token");
    guard sent && token == "secret-goose" else { honk::raise(401, "Invalid X-Token header"); }
    return User { username: "goose", admin: true };
}

honk::delete<Deleted, ItemId>(c, "/items/{item_id}") { p =>
    let user = current_user(c);         // 401 unless the token is right
    ...
};
```

Dependencies compose because they are plain calls: one may call another,
take arguments, or return several values. Call them inside route blocks,
not at the top of `app` or of a router function. Code there also runs
during the startup describe pass ([section 1](#1-the-app-function)), where
a `raise` would stop the remaining routes from being documented.

## 12. Bigger applications: routers

`honk::include` runs a function of routes under a path prefix and a tag.
It lets a large app split its routes into groups:

```goose
fn item_routes(c: honk::Ctx&) {
    honk::get<ItemList, ListItems>(c, "", "List items") { p => ... };     // GET /items
    honk::get<Item, ItemId>(c, "/{item_id}", "Read an item") { p => ... };
}

fn app(c: honk::Ctx&) {
    honk::include(c, "/items", "items", item_routes);
}
```

Routers nest, and their prefixes concatenate (up to 128 bytes). The tag
groups the routes in `/docs`. Router functions can live in their own files.
The root file declares the package with `import honk from "...";` and
imports the others (`import items_routes;`), and each of those files
writes just `import honk;`.

## 13. State and storage

With `honk::serve`, handlers run one at a time on the main thread, so
globals are a safe, simple store. (With threads they are not; see
[section 14](#14-threads-shared-state-and-background-jobs).)

```goose
var items: Item[>..<] = [];     // grow-shrink: rows can be removed
var next_id = 1;
```

Pick the array kind for what the handlers do with it:

* `T[>..]` (grow-only) when rows are only added. References into it stay
  valid forever.
* `T[>..<]` (grow-shrink) when handlers also remove rows (`remove_at`,
  `swap_remove`). Goose will not let a grow-only array shrink while the
  request context could point into it, and grow-shrink arrays are the
  container built for removal.
* A `reusable` pool when rows come and go in no particular order and you
  want stable slots.

For anything durable, Goose's `os` module has `write_file_atomic` and
`read_file`. A Goose array of fixed-size records is already its own file
format (`to_bytes` / `from_bytes`), so saving a table is one write.

Per-request data lives in the Goose data stacks of that request, and is
freed when the request ends with one store.

## 14. Threads, shared state and background jobs

`honk::serve` answers one request at a time. `honk::serve_threads` listens
once and starts N workers that all accept connections on the same socket,
so N requests run at once.

Goose threads share no memory. Each worker is compiled as its own program
with its own copy of every global, and values cross between threads only
through typed queues. That shapes the API in three ways.

**Each app declares its own worker.** A `thread_fn` cannot be generic, so
Honk cannot write one that runs your app. Yours is one line:

```goose
let CONFIG = honk::Config { title: "Items API", .. };   // a let global: workers read it

thread_fn worker(fd: i64, id: i64) { honk::serve_on(fd, id, CONFIG, app); }

fn main() {
    honk::serve_threads(CONFIG, 4, worker);     // 0 workers means hardware_threads()
}
```

**Shared data lives in a store thread.** A global changed on one worker is
not changed on the others, so the data that every request must see belongs
to one store thread, as its locals. Handlers send it a command and wait for
its reply:

```goose
enum Cmd { List, Get { id: i64 }, Create { item: ItemIn } }
struct Reply { found: bool, item: Item, list: ItemList }

thread_fn store() {
    var items: Item[>..<] = [];
    var next_id = 1;
    honk::serve_store<Cmd>() { cmd =>
        var r = Reply { .. };
        match cmd {
            Get g => { for x in items { if x.id == g.id { r.found = true; r.item = x; } } },
            ...
        }
        r                                         // the reply
    };
}

// The handlers' way to the store.
fn db(cmd: Cmd) -> Reply { honk::ask<Cmd, Reply>(cmd) }

honk::get<Item, ItemId>(c, "/items/{item_id}") { p =>
    let r = db(Cmd.Get { id: p.item_id });
    if !r.found { honk::raise(404, "Item not found"); }
    r.item
};

fn main() {
    thread_spawn(store);
    honk::serve_threads(CONFIG, 4, worker);
}
```

The store answers one command at a time, so its state needs no locks, and
each command is atomic. Commands and replies cross between threads, so they
must be **flat**: no references or slices, which means `u8[..N]` for text
and limited arrays (`Item[..50]`) for lists.

Write the `db` wrapper rather than calling `honk::ask` directly with an
inferred type. `Cmd.Get { id: 1 }` on its own has the variant type
`Cmd.Get`, and Goose keeps one queue per type, so `ask` would send it where
the store never looks. A parameter of type `Cmd` makes every variant a
`Cmd`.

Each worker waits for its own reply, in a mailbox keyed by its worker id
(`honk::worker_id`; 0 is the main thread). If the store does not reply
within `honk::ask_timeout_ms` (10 seconds), the request is answered 503,
and the late reply is discarded instead of answering the next question.
The store also works with plain `honk::serve`, as long as the program is
built.

**Background jobs** are queued with `honk::background(job)`, which returns
at once, and run by a worker of their own:

```goose
struct Audit { action: u8[..16], id: i64 }

thread_fn auditor() {
    honk::run_jobs<Audit>() { job => print("AUDIT: ", job.action, " item ", job.id); };
}

// in a handler:
honk::background(Audit { action: "created", id: r.item.id });
```

Start several job workers for parallel jobs: each job goes to whichever
one takes it first.

**Builds and failures.** Programs with threads need `goose build`, because
the in-process runner cannot start threads. An abort in any worker (a
failed bounds check, say) ends the whole process, so run the server under
a supervisor such as systemd or launchd that restarts it. With threads,
an idle keep-alive connection holds its worker for up to
`Config.keep_alive_ms`, so use at least as many workers as clients you
expect to keep connections open.

[`examples/threaded.goose`](../examples/threaded.goose) is the complete
program. On a laptop it serves about 24,000 requests a second, each one a
round trip to the store.

## 15. OpenAPI and the docs pages

At startup Honk describes the app into an OpenAPI 3.1 document:

* `/openapi.json` is the schema.
* `/docs` is Swagger UI and `/redoc` is ReDoc, both loaded from jsDelivr,
  so the server ships no frontend files.

The schema includes:

* every route's method, path, `summary`, `operationId` and tag
* path and query parameters with their types, required flags and defaults
* request body schemas, nested models included, with `required`, `default`,
  `maxLength` and `title`s derived from field names ("unit_price" becomes "Unit Price")
* the success response schema under the route's status code
* a `422` response referencing `HTTPValidationError` on routes with params

Set `Config.docs = false` to serve none of the three.

## 16. Testing

`honk::request` is the test client. It runs a request through the app in the
same process, with no sockets, and returns the status and body:

```goose
let status, body = honk::request("GET", "/items/1", app);
assert(status == 200);

let s2, b2 = honk::request("POST", "/items", "{\"name\":\"Egg\",\"price\":3}", app);
let s3, b3 = honk::request("GET", "/users/me", "", "x-token: secret-goose\r\n", app);
```

The arguments are method, target (path and query), body, and extra header
lines, each ending in `\r\n`. The last two may be left out. See
[`tests/test_honk.goose`](../tests/test_honk.goose) for a full suite:

```bash
goose tests/test_honk.goose
```

## 17. Configuration and deployment

```goose
honk::serve(honk::Config {
    host: "0.0.0.0",        // all interfaces; "127.0.0.1" (the default) for local only
    port: 8080,
    title: "Items API",
    version: "1.2.0",
    description: "What /docs shows under the title",
    docs: true,
    log: true,              // INFO:     "GET /items/1 HTTP/1.1" 200 OK (0.02 ms)
    timeout_ms: 10000,      // a client that sends nothing for this long is dropped
    max_body: 1048576,
    backlog: 1024,          // connections the kernel holds until a worker accepts them
    keep_alive: true,       // serve several requests per connection
    keep_alive_ms: 5000,    // how long an idle connection is kept
    keep_alive_max: 100,    // requests per connection before it is closed
    tls_cert: "",           // set both to serve HTTPS (see below)
    tls_key: "",
}, app);
```

For production, build a native binary:

```bash
goose build -O2 main.goose
```

### HTTPS

Give `Config` a PEM certificate chain and its private key, and every
connection speaks TLS 1.2 or 1.3:

```goose
honk::serve(honk::Config { port: 8443, tls_cert: "cert.pem", tls_key: "key.pem", .. }, app);
```

Honk does not link a TLS library. When a certificate is set, it loads
OpenSSL 3's `libssl` at startup (with `dlopen`, or `LoadLibrary` on
Windows), so an app that serves plain HTTP builds and runs with no TLS
library installed. Honk looks where OpenSSL usually is: the system library
path, then Homebrew and MacPorts on macOS (`brew install openssl@3`), and
`libssl.so.3` on Linux (the `libssl3` package). `Config.tls_lib` names the
file to load instead. A certificate that cannot be read, a key that does
not match it, or a missing OpenSSL stops the server at startup with the
reason:

```
honk: cannot read the private key: error:05800074:x509 certificate routines::key values mismatch
```

TLS works the same with `serve_threads`, and keep-alive carries over. A
client that speaks plain HTTP to the TLS port is dropped during the
handshake, and the server goes on. For local testing, make a certificate
for localhost:

```bash
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj /CN=localhost \
    -addext subjectAltName=DNS:localhost,IP:127.0.0.1 -keyout key.pem -out cert.pem
```

[`examples/https.goose`](../examples/https.goose) is a complete program.
Honk serves HTTP/1.1 only. For HTTP/2, or for certificates that renew
themselves, put a proxy such as Caddy or nginx in front.

`honk::serve` handles one request at a time, and `honk::serve_threads`
handles one per worker ([section 14](#14-threads-shared-state-and-background-jobs)).
Connections are kept alive between requests (HTTP/1.1 by default, HTTP/1.0
when the client asks). With `serve`, an idle connection gives way at once
when another client connects, so a quiet client never holds the server.
Pipelined requests are not supported: when a second request arrives before
the first is answered, Honk answers the first and closes the connection,
and the client sends the rest again.

## 18. How Honk works

The pieces fit in about 2,000 lines:

* **`net.goose` and `src/`**: `listen`, `accept`, `recv`, `send`, `close`
  and `poll` over BSD sockets, TLS on OpenSSL loaded at run time, and the
  per-worker reply mailboxes, as `extern fn`s.
* **`workers.goose`** starts the workers, and runs the store and job loops
  on Goose's typed queues.
* **`http.goose`** reads a request into one growable buffer. The method,
  path, query, headers and body are slices of it, and nothing is copied
  except percent-decoded text.
* **`routing.goose`** matches a route, builds `P { .. }` from the field
  defaults, fills each field through an overload chosen by its type, and
  calls the block.
* **`model.goose`** has three reflective walkers (JSON out, JSON in with
  validation, JSON Schema), each written once against `fields<T>`.
* **`openapi.goose`** runs the describe pass and assembles the document.

One trick holds the model code together. Each walker needs one overload per
field type (`i64`, `f64`, `bool`, strings, arrays) plus a catch-all for
nested models. In Goose a generic `T` parameter ranks the same as `T[:]`,
which would make every array ambiguous. Each overload therefore takes a
dispatch token: `k: i64` on the specific ones and `k: f64` on the model
catch-all, called with an `i64`. A candidate that converts an integer to a
float is the one Goose tries last (spec 7.1), so the model overload applies
only when nothing more specific does.
