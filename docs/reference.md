# Honk API reference

Everything public in the `honk` namespace. Import the package from your root
file with `import honk from "path/to/honk";`, and from your other files with
`import honk;`. The [guide](guide.md) explains each feature with examples.

<details>
<summary>Contents</summary>

- [Serving](#serving): `serve`, `Config`, `request`
- [Threads](#threads): `serve_threads`, `serve_on`, `ask`, `serve_store`, `background`, `run_jobs`
- [Routes](#routes): `get`, `post`, `put`, `patch`, `delete`, `include`
- [The request context](#the-request-context): `Ctx`, `Param`
- [Request helpers](#request-helpers): `header`, `path_param`, `query_param`
- [Responses](#responses): `Html`, `Text`, `Redirect`, `NoContent`, `set_header`
- [Errors](#errors): `raise`, `HTTPError`
- [Models](#models): `to_json`, `schema_of`
- [Optional values and enums](#optional-values-and-enums): `Opt`, `opt`, `Enum`, `enum_name`
- [Types for params](#types-for-params): `NoParams`
- [Constants](#constants)

</details>

---

## Serving

### `serve`

```goose
fn serve<App>(cfg: Config)
```

Describes `App` into the OpenAPI document, listens on `cfg.host:cfg.port`
and answers requests until the process ends. `App` is a function
`fn app(c: honk::Ctx&)` that declares the routes, passed after the config:

```goose
honk::serve(honk::Config { port: 8000, .. }, app);
```

Aborts with a message if it cannot listen. Requests are answered one at a
time. A connection is kept open for the next request when the client
allows it (HTTP/1.1 unless `Connection: close`, HTTP/1.0 only with
`Connection: keep-alive`), until it has served `keep_alive_max` requests or
idled for `keep_alive_ms`. An idle connection is closed at once when another
client connects, and a connection with pipelined requests is closed after
its first answer. A request whose head exceeds 64 KiB,
or that is malformed, gets 400, and one whose body exceeds `cfg.max_body`
gets 413.

### `Config`

```goose
struct Config {
    host: const u8[:] = "127.0.0.1",
    port: i64 = 8000,
    title: const u8[:] = "Honk API",        // OpenAPI info.title, and the docs pages' title
    version: const u8[:] = "0.1.0",         // OpenAPI info.version
    description: const u8[:] = "",         // OpenAPI info.description
    docs: bool = true,                      // serve /docs, /redoc and /openapi.json
    log: bool = true,                       // one line per request on stdout
    timeout_ms: i64 = 10000,                // receive timeout per connection
    max_body: i64 = 1048576,                // larger requests get 413
    keep_alive: bool = true,                // serve several requests per connection
    keep_alive_ms: i64 = 5000,              // how long an idle connection is kept
    keep_alive_max: i64 = 100,              // requests per connection before it is closed
}
```

`host` is an IPv4 address, `"0.0.0.0"` for every interface, or
`"localhost"`.

### `request`

```goose
fn request<App>(method: const u8[:], target: const u8[:], body: const u8[:] = "",
                headers: const u8[:] = "") -> i64, u8[>..]
```

The test client. Answers one request with `App` in-process, with no
sockets, and returns the status and the response body. `target` is the
path with an optional query string. `headers` holds extra header lines,
each ending in `\r\n`. A non-empty `body` is sent with
`content-type: application/json`.

```goose
let status, body = honk::request("GET", "/items/1?verbose=true", app);
let s, b = honk::request("POST", "/items", "{\"name\":\"Egg\"}", "x-token: abc\r\n", app);
```

The OpenAPI document is described for each call, so `/openapi.json` can be
tested too.

---

## Threads

Programs that use these must be built with `goose build`. The
[guide](guide.md#14-threads-shared-state-and-background-jobs) explains the
design.

### `serve_threads`

```goose
fn serve_threads<W>(cfg: Config, workers: i64)
```

Listens on `cfg.host:cfg.port` and starts `workers` workers on the socket
(`hardware_threads()` of them when `workers` is 0, and at most 255). `W` is
the app's `thread_fn worker(fd: i64, id: i64)`, which calls `serve_on`.
Then it waits on the workers, which run until the process ends. An abort in
any worker ends the process.

```goose
let CONFIG = honk::Config { port: 8000, .. };
thread_fn worker(fd: i64, id: i64) { honk::serve_on(fd, id, CONFIG, app); }
fn main() { honk::serve_threads(CONFIG, 0, worker); }
```

### `serve_on`

```goose
fn serve_on<App>(fd: i64, id: i64, cfg: Config)
```

A worker's whole life: sets `worker_id` to `id`, then accepts connections
on the listening socket `fd` and answers them with `App`, forever. `cfg`
must be a `let` global, since a worker reads only flat or static globals.
An idle keep-alive connection holds its worker for up to
`cfg.keep_alive_ms`.

### `ask`

```goose
fn ask<Req, Resp>(req: Req) -> Resp
```

Sends `req` to the store thread running `serve_store<Req>` and returns its
reply. Both types must be flat. Name `Req` explicitly, or go through a
wrapper that takes it, so that an enum variant is sent as its enum:

```goose
fn db(cmd: Cmd) -> Reply { honk::ask<Cmd, Reply>(cmd) }
```

Must be called under a route block. Answers 503 (`The store did not
answer`) when no reply comes within `ask_timeout_ms`, and 500 if the reply
is not a `Resp`.

### `serve_store`

```goose
fn serve_store<Req, F>()
```

The store thread's loop: takes each `Req` sent with `ask` from any worker,
in order, and replies with `F(req)`. The state is the store `thread_fn`'s
locals, which the block reads and changes.

### `background`

```goose
fn background<Job>(job: Job) -> bool
```

Queues a flat `job` for a worker running `run_jobs<Job>` and returns at
once: `false` if the queue for `Job` is full (`qlimit<Job>(n)` sets a
limit; there is none by default).

### `run_jobs`

```goose
fn run_jobs<Job, F>()
```

A background worker's loop: runs `F(job)` for each queued `Job`, forever.

### Globals

```goose
var worker_id: i64 = 0;          // this thread's worker id: 0 on main, 1.. on workers
var ask_timeout_ms: i64 = 10000; // how long ask waits
```

Each thread has its own copy of every global, these included.

---

## Routes

### `get`, `post`, `put`, `patch`, `delete`

```goose
fn get<R, F>(c: Ctx&, path: const u8[:], summary: const u8[:] = "", status: i64 = 200)
fn get<R, P, F>(c: Ctx&, path: const u8[:], summary: const u8[:] = "", status: i64 = 200)
```

`post`, `put`, `patch` and `delete` have the same two forms.

Each declares a route of that method. `GET` routes also answer `HEAD`.

| Parameter | Meaning |
|---|---|
| `R` | The response type: a [model](#models) (JSON) or a [response type](#responses). Given explicitly: `get<Item>`. |
| `P` | The params struct, given explicitly: `get<Item, ReadItem>`. |
| `F` | The handler: the trailing block. `{ ... }` in the first form, `{ p => ... }` in the second, where `p` is a `P`. Its value must be an `R`. |
| `path` | The path template, relative to any [`include`](#include) prefix. `{name}` captures one segment, `{name:path}` the rest of the path. |
| `summary` | The operation's summary in the docs. |
| `status` | The success status code. The handler may override it through `c.status`. |

**How a request is matched.** If an earlier route already answered, the
declaration returns at once. Otherwise the path is matched against
`prefix + path`, ignoring a trailing slash. When the path matches but the
method does not, the request is remembered as a 405 candidate.

**How `P` is filled.** It starts as `P { .. }`, so every field has its
declared default. Then each field is filled by name and type:

1. A field named by a `{name}` in the path takes that path segment.
2. A field whose type is a struct (a model) takes the JSON body.
3. Any other field takes the query parameter of its name, if sent.

Scalar and string fields are parsed by type: `i64`, `i32`, `f64`, `bool`
(`true/false/1/0/yes/no/on/off`; present with no value means true),
`const u8[:]`, `u8[>..]`, `u8[..N]` for N from 8 to 4096 in powers of two,
and `Enum<E>`. A `T[>..]` field takes every query parameter of its name
(`?tag=a&tag=b`), and an `Opt<T>` field is filled and set only when its
parameter, or for a model its body, was sent. Every failure is collected, and if there are any, the request is answered with
422 and the block does not run. The error format is described under
[Errors](#errors).

**How the result is sent.** The block's value goes to the response writer
for `R`: models as JSON, the response types as described below.

### `include`

```goose
fn include<F>(c: Ctx&, prefix: const u8[:], tag: const u8[:] = "")
```

Runs the routes declared by `F`, a function `fn routes(c: honk::Ctx&)`,
under a path prefix, and tags them for the docs:

```goose
honk::include(c, "/items", "items", item_routes);
```

Includes nest. The combined prefix is at most 128 bytes, and an inner tag
replaces an outer one.

---

## The request context

### `Ctx`

```goose
struct Ctx {
    method: const u8[:],
    path: const u8[:],              // percent-decoded, without a trailing slash
    query: const u8[:],             // raw, without the '?'
    headers: const u8[:],           // the raw header lines
    body: const u8[:],
    params: Param[..8],             // the matched route's path parameters
    status: i64 = 200,
    content_type: const u8[:] = "application/json",
    out: u8[>..]&,                  // the response body, from out[out_at]
    out_at: i64 = 0,
    resp_headers: u8[>..]&,         // extra response header lines
    scratch: u8[>..]&,              // decoded text that lives as long as the request
    handled: bool = false,
    path_seen: bool = false,
    describing: bool = false,       // true during the startup describe pass
    keep_alive: bool = false,       // the connection stays open after this response
    prefix: u8[..128] = [],
    tag: const u8[:] = "",
    api: Api&,
}
```

The request in flight. Handlers mostly read it through the
[helpers](#request-helpers), and may set `status` for a JSON response:

```goose
honk::post<Job, NewJob>(c, "/jobs") { p =>
    c.status = 202;                                  // Accepted, instead of the route's 200
    honk::set_header(c, "location", "/jobs/1");
    Job { id: 1, state: "queued" }
};
```

The response writer runs after the block, so the types that fix their own
status or content type (`NoContent`, `Redirect`, `Html`, `Text`) set them
after any change the block made.

All slices in `Ctx` point into buffers owned by the server for one request.
Copy what you keep (into a `u8[..N]` field, say) before the request ends.

### `Param`

```goose
struct Param { name: u8[..32], value: const u8[:] }
```

One path parameter of the matched route.

---

## Request helpers

### `header`

```goose
fn header(c: Ctx&, name: const u8[:]) -> const u8[:], bool
```

The value of a request header, matched case-insensitively and trimmed, and
whether the header was present.

### `path_param`

```goose
fn path_param(c: Ctx&, name: const u8[:]) -> const u8[:], bool
```

A path parameter captured by the matched route, as text.

### `query_param`

```goose
fn query_param(c: Ctx&, name: const u8[:]) -> const u8[:], bool
```

The first query parameter of that name, percent-decoded with `+` as a
space, and whether it was present.

---

## Responses

Name one of these as `R` to answer with something other than JSON.

### `Html`

```goose
struct Html { body: u8[] }
```

`text/html; charset=utf-8`. `honk::Html { body: str("<h1>", title, "</h1>") }`.

### `Text`

```goose
struct Text { body: u8[] }
```

`text/plain; charset=utf-8`.

### `Redirect`

```goose
struct Redirect { location: u8[], status: i64 = 307 }
```

Sets `location` and the status, with an empty body.

### `NoContent`

```goose
struct NoContent { }
```

Status 204, with no body and no `content-type`.

### `set_header`

```goose
fn set_header(c: Ctx&, name: const u8[:], value: const u8[:])
```

Adds a header line to the response. Every response also carries
`content-type`, `content-length`, `server: honk` and `connection`
(`keep-alive` or `close`).

---

## Errors

### `raise`

```goose
fn raise<T>(status: i64, detail: T[:])
```

Stops the handler and answers `status` with `{"detail": detail}`. `detail`
is any `u8` array or slice, a literal or a `str(...)`, and is copied:
`honk::raise(404, str("Item ", id, " not found"))`. It never returns, so a
value-returning function may end with it. Every call must be under a
route block, which the compiler checks.

### `HTTPError`

```goose
struct HTTPError { status: i64, detail: u8[], is_json: bool = false }
```

What `raise` throws, through Goose's `exception` module. With `is_json`,
`detail` is sent as JSON rather than as a string. Validation uses this for
its error list. Throwing one yourself with `exception::throw(HTTPError {
... })` is the same as `raise`, plus control over `is_json`.

### Validation errors

```json
{"detail":[{"type":"missing","loc":["body","size","height"],"msg":"Field required","input":null}]}
```

| Field | Meaning |
|---|---|
| `type` | A machine-readable error type, listed below |
| `loc` | `"path"`, `"query"` or `"body"`, then the field names down to the value |
| `msg` | A human-readable message |
| `input` | The offending input as JSON, or `null` when it is missing |

Types: `missing`, `int_type`, `int_parsing`, `int_from_float`,
`int_too_big`, `float_type`, `float_parsing`, `bool_type`, `bool_parsing`,
`string_type`, `string_too_long`, `enum`, `list_type`,
`model_attributes_type`, `json_invalid`.

### Built-in statuses

| Status | When |
|---|---|
| 400 | The request line or head is malformed |
| 404 | No route matches the path: `{"detail":"Not Found"}` |
| 405 | A route matches the path but not the method |
| 413 | The body is larger than `Config.max_body` |
| 422 | Params or body failed validation |

---

## Models

A model is any struct. Its fields may be the types listed in the
[guide](guide.md#6-models), and Honk reads them by reflection. A field is
**required** in a request body when its value in `T { .. }` is its type's
zero (`0`, `0.0`, empty). `bool`, `Opt` and list fields are never required;
`Enum` fields and nested models always are.

### `to_json`

```goose
fn to_json(out: u8[>..]&, v)
```

Appends `v` as JSON. Numbers use the shortest form that reads back
exactly, and strings are escaped. A model with fields `a`, `b` becomes
`{"a":...,"b":...}` in declaration order.

### `schema_of`

```goose
fn schema_of(out: u8[>..]&, v)
```

Appends the JSON Schema of `v`'s type, as `/openapi.json` uses it:
`type`, `properties`, `required`, `default`, `maxLength`, `items` and
`title`.

---

## Optional values and enums

### `Opt`

```goose
struct Opt<T> { set: bool = false, value: T }
fn opt<T>(v: T) -> Opt<T>                   // set, holding v
```

A field that may be absent or `null`. In a request it is never required,
and `set` says whether a value arrived: from a parameter of its name, from
the body when `T` is a model, or from the JSON member. An explicit `null`
unsets it. A default value is written `= honk::opt(v)`. In a response an
unset `Opt` is `null`. Its schema is `anyOf` T's schema and `null`.

### `Enum`

```goose
struct Enum<E> { value: E }
fn enum_name<E>(v: E) -> const u8[:]        // the variant's name
fn enum_parse<E>(s: u8[:], dst: E&) -> bool // the variant named s, if any
```

A field holding a variant of `E`, whose variants must have no payloads.
It is read and written as the variant's name, and described as a string
schema with `enum` listing the names. An unknown name is a 422 of type
`enum`. In a request body an `Enum` field is required.

---

## Types for params

### `NoParams`

```goose
struct NoParams { }
```

The params type of the one-type route form. The two-type form never needs
it.

The block receives `P` by reference, since a `P` holding a list is not
fixed-size and Goose copies such values only when asked. `p.field` reads
the same either way.

---

## Constants

```goose
let VERSION = "0.1.0";      // Honk's version, printed at startup
```
