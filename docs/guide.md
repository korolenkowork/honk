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
- [14. OpenAPI and the docs pages](#14-openapi-and-the-docs-pages)
- [15. Testing](#15-testing)
- [16. Configuration and deployment](#16-configuration-and-deployment)
- [17. How Honk works](#17-how-honk-works)

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
`json_invalid` with the byte offset. Unknown members are ignored, and a
`null` member leaves its field at its default.

Only one field should be a model. Bodies are limited to
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
| `u8[..N]`, N = 8, 16, 32, 64, 128, 256 | string, `maxLength: N` | yes: longer input is a 422 | yes |
| `u8[..N]`, any other N | string | no | yes |
| `u8[]`, `u8[>..]` | string | no | yes |
| `T[k]`, `T[>..]`, `T[:]` | array of T | no | yes |
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
* A nested model is required.

The schema in `/openapi.json` follows the same rules, so the docs always
match what the server enforces. This applies to bodies only. A query field
is always optional and falls back to its default.

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
curl -X POST localhost:8000/items -d '{"name":"Egg","price":"cheap","size":{"width":2}}'
```

```json
{"detail":[
  {"type":"float_type","loc":["body","price"],"msg":"Input should be a valid number","input":"cheap"},
  {"type":"missing","loc":["body","size","height"],"msg":"Field required","input":null}
]}
```

Each error's `type` is a stable, machine-readable name that clients can
branch on: `missing`, `int_type`, `int_parsing`, `int_from_float`,
`float_type`, `float_parsing`, `bool_type`, `bool_parsing`, `string_type`,
`string_too_long`, `model_attributes_type`, `json_invalid`.

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

Handlers run one at a time on the main thread, so globals are a safe,
simple store:

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

## 14. OpenAPI and the docs pages

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

## 15. Testing

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

## 16. Configuration and deployment

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
}, app);
```

For production, build a native binary and put a reverse proxy in front of
it for TLS:

```bash
goose build -O2 main.goose
```

The server handles one connection at a time with `Connection: close`. To use
several cores, run one process per core on different ports behind the
proxy's load balancer.

## 17. How Honk works

The pieces fit in about 1,300 lines:

* **`net.goose` and `src/honk_net.c`**: `listen`, `accept`, `recv`, `send`,
  `close`, as `extern fn`s over BSD sockets.
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
