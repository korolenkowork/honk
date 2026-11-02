# Honk

[![CI](https://github.com/korolenkowork/honk/actions/workflows/ci.yml/badge.svg)](https://github.com/korolenkowork/honk/actions/workflows/ci.yml)
[![Benchmarks](https://github.com/korolenkowork/honk/actions/workflows/bench.yml/badge.svg)](https://github.com/korolenkowork/honk/actions/workflows/bench.yml)

**Typed, self-documenting web servers for the [Goose](https://github.com/aardappel/goose) programming language.**

Declare routes with typed models. Honk validates the request, fills your
params struct, serializes your response and writes the OpenAPI schema, all
from the struct definitions, with no code per model. `/docs` serves the
interactive Swagger UI.

```goose
import honk from "./honk";

struct Item { name: u8[..32], price: f64, in_stock: bool = true }
struct ReadItem { item_id: i64, q: const u8[:] = "" }        // item_id from the path, q from the query
struct CreateItem { item: Item }                             // a model field is the JSON body

fn app(c: honk::Ctx&) {
    honk::get<Item, ReadItem>(c, "/items/{item_id}") { p =>
        Item { name: "Goose feather", price: p.item_id * 2.5 }
    };
    honk::post<Item, CreateItem>(c, "/items", "Create an item", 201) { p =>
        p.item
    };
}

fn main() { honk::serve(honk::Config { port: 8000, .. }, app); }
```

```bash
goose main.goose
```

```bash
curl http://127.0.0.1:8000/items/4
```

```
{"name":"Goose feather","price":10.0,"in_stock":true}
```

```bash
curl -X POST http://127.0.0.1:8000/items -d '{"name": "Egg", "price": "cheap"}'
```

```json
{"detail":[{"type":"float_type","loc":["body","price"],"msg":"Input should be a valid number","input":"cheap"}]}
```

Then open **http://127.0.0.1:8000/docs**.

## Features

| Feature | How |
|---|---|
| Routes | `honk::get<R, P>(c, "/items/{item_id}") { p => ... }`, and `post`, `put`, `patch`, `delete` |
| Typed params | A params struct `P`: path, query and body fields by name and type |
| Optional values and enums | `honk::Opt<T>` (unset, `null` or a value) and `honk::Enum<E>` (a variant by name) |
| Models | Plain Goose `struct`s, read by compile-time reflection |
| Typed responses | The response type `R`, checked by the compiler and serialized to JSON |
| Validation | A 422 listing every error with `type`, `loc`, `msg` and `input` |
| HTTP errors | `honk::raise(404, "Item not found")` from any depth of calls |
| Dependencies | Plain functions that take `c: honk::Ctx&` and may `raise` |
| Routers | `honk::include(c, "/users", "users", user_routes)`: a prefix and a docs tag |
| Docs | `/docs` (Swagger UI), `/redoc` and `/openapi.json`, generated at startup |
| Testing | `honk::request("GET", "/items/1", app)`, in-process with no sockets |
| Keep-alive | Connections are reused between requests |
| Threads | `honk::serve_threads`: N workers accepting on one socket |
| Shared state | A store thread that owns the data, reached with `honk::ask` |
| Background jobs | `honk::background(job)`, run by a worker with `honk::run_jobs` |
| HTTPS | `Config { tls_cert: "cert.pem", tls_key: "key.pem", .. }`, on OpenSSL 3 loaded at run time |
| Status codes | `honk::post<R, P>(c, path, "summary", 201)` |
| Other responses | `honk::Html`, `honk::Text`, `honk::Redirect`, `honk::NoContent` |

## Why it works in Goose

Goose has no runtime reflection, no closures that outlive their caller, no
function pointers, and no heap. Honk relies on the features it has instead:

* **`const for <N, A> in fields<T>`** expands once per field at compile time.
  JSON output, validation, and JSON Schema are each written once in the
  library and specialized for every model you declare.
* **Static function values.** Route handlers are blocks passed as generic
  parameters, so each route compiles to a direct, inlinable call. The app
  needs no route table: the route declarations run in order on every request.
* **`return ... from`** carries `honk::raise` from any depth of helper calls
  straight to the request handler. The functions in between need no error
  plumbing.
* **Data stacks.** Each request's buffers are locals of one scope, and
  leaving that scope frees all of them with a single store.
* **Sockets come in through `extern fn`**, about 100 lines of C in
  [`honk/src/honk_net.c`](honk/src/honk_net.c). The rest of Honk is Goose.

## Performance

The same JSON API in Honk, C, C++, C#, Java, Go, Python and JavaScript,
each on its own standard library ([bench/](bench/README.md)). On an Apple M5
with 10 connections:

| Server | `GET /hello` | `POST /items` (JSON, validated) | Peak memory |
|---|---:|---:|---:|
| Honk (Goose) | 146,409 req/s | 133,777 req/s | 3.4 MiB |
| C++ (hand-written) | 140,336 req/s | 142,231 req/s | 9.4 MiB |
| C (hand-written) | 115,961 req/s | 116,334 req/s | 9.3 MiB |
| JavaScript (Node) | 113,931 req/s | 109,199 req/s | 686.5 MiB |
| Python | 68,342 req/s | 63,460 req/s | 234.8 MiB |

With 256 connections, Honk keeps its throughput, but tail latency rises
because each worker serves one connection at a time. [bench/README.md](bench/README.md)
has every workload, the method, and the Linux numbers from CI for Go, Java
and C#.

## Install

You need the Goose compiler on `PATH`
([releases](https://github.com/aardappel/goose/releases)) and a C compiler,
which Goose uses to build Honk's socket layer. Honk is a Goose package, so
point your root file at it:

```goose
import honk from "path/to/Honk/honk";            // a local checkout
import honk from "github.com/you/honk@v0.1.0";   // or a git tag, once published
```

Run in-process with the bundled TinyCC (`goose app.goose`), or build a
native binary:

```bash
goose build app.goose && ./app
```

## Layout

```
honk/                the package
  honk.goose         Ctx, Config, serve, request (test client), raise, include, headers
  routing.goose      get/post/put/patch/delete, path matching, params binding
  model.goose        JSON writer, body validation, JSON Schema, by reflection
  openapi.goose      /openapi.json, /docs (Swagger UI), /redoc
  http.goose         request parsing, percent-decoding, responses
  workers.goose      serve_threads, the store (ask, serve_store), background jobs
  net.goose          extern fn bindings to the C layer
  src/honk_net.c     BSD sockets (Winsock on Windows)
  src/honk_tls.c     TLS, on OpenSSL 3 loaded with dlopen when a certificate is set
  src/honk_mail.c    per-worker reply mailboxes for honk::ask
examples/
  hello.goose        two routes
  items.goose        CRUD: models, an enum, PATCH with Opt, errors, a router, a dependency, HTML
  threaded.goose     4 workers, a store thread owning the data, a background audit log
  https.goose        the same app over TLS
bench/
  run.py             builds each server, checks its answers, loads it with wrk
  servers/           the same API in Honk, C, C++, C#, Java, Go, Python, JavaScript
.github/workflows/
  ci.yml             tests on Linux, macOS and Windows
  bench.yml          the benchmarks, with tables in the run summary
tests/
  test_honk.goose    46 checks through honk::request
  test_threads.goose the store, its timeout and background jobs (needs goose build)
docs/
  quickstart.md      from nothing to /docs in five minutes
  guide.md           every feature, by example
  reference.md       the API, one entry per declaration
```

## Docs

* **[Quickstart](docs/quickstart.md)**: install, first app, try it.
* **[Guide](docs/guide.md)**: routes, params, models, validation, responses,
  errors, dependencies, routers, threads and shared state, OpenAPI, testing,
  deployment.
* **[API reference](docs/reference.md)**: every public declaration.
* **[Proposals to Goose](docs/proposals/README.md)**: three language changes
  that would remove Honk's remaining workarounds.

## Running the examples and tests

```bash
goose examples/hello.goose
```

```bash
goose examples/items.goose
```

```bash
goose tests/test_honk.goose
```

Programs with threads must be built first:

```bash
goose build examples/threaded.goose && examples/threaded
```

```bash
goose build tests/test_threads.goose && tests/test_threads
```

## Status and limits

Honk is version 0.1 and these are its limits:

* **Threads need `goose build`.** `honk::serve_threads` runs N workers, but
  the in-process runner (`goose app.goose`) cannot start threads, and there
  `honk::serve` answers one request at a time.
* **Workers share no state.** Each worker has its own copy of the globals,
  so shared data lives in a store thread that handlers reach with
  `honk::ask`, or in an external database. An abort in any worker ends the
  process; run it under a supervisor that restarts it.
* **HTTP/1.1 only.** HTTPS works natively when OpenSSL 3 is installed, but
  there is no HTTP/2. Put a proxy such as nginx or Caddy in front for
  HTTP/2, or to manage certificates for you.
* **What a model field may be** is listed in [the guide](docs/guide.md#6-models).
  Request models take scalars, strings (`const u8[:]`, or `u8[..N]` for N
  from 8 to 4096 in powers of two), `honk::Opt<T>`, `honk::Enum<E>`, one
  list as the last field, and nested models.
* **Required fields** are the fields whose default is their type's zero,
  because Goose reflection cannot see whether a field declares a default.
  Use `honk::Opt<T>` for an optional field whose default is zero (see
  [the guide](docs/guide.md#required-and-optional-fields)).
* **No async.** Handlers run to completion on their worker. Slow work goes
  to a background worker with `honk::background`.

## References

* Goose: [repository](https://github.com/aardappel/goose),
  [tutorial](https://github.com/aardappel/goose/blob/main/docs/tutorial.md),
  [reference](https://github.com/aardappel/goose/blob/main/docs/reference.md),
  [`const for`](https://github.com/aardappel/goose/blob/main/docs/design/const_for.md),
  [packages](https://github.com/aardappel/goose/blob/main/docs/packages.md)
* [OpenAPI 3.1 specification](https://spec.openapis.org/oas/v3.1.0),
  [Swagger UI](https://swagger.io/tools/swagger-ui/),
  [ReDoc](https://github.com/Redocly/redoc)
* [OpenSSL 3](https://www.openssl.org/docs/man3.0/man7/ssl.html), the TLS
  library Honk loads for HTTPS
* [RFC 9110, HTTP semantics](https://www.rfc-editor.org/rfc/rfc9110) and
  [RFC 9112, HTTP/1.1](https://www.rfc-editor.org/rfc/rfc9112)

## License

[MIT](LICENSE).
