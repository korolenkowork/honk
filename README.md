# Honk

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
| Models | Plain Goose `struct`s, read by compile-time reflection |
| Typed responses | The response type `R`, checked by the compiler and serialized to JSON |
| Validation | A 422 listing every error with `type`, `loc`, `msg` and `input` |
| HTTP errors | `honk::raise(404, "Item not found")` from any depth of calls |
| Dependencies | Plain functions that take `c: honk::Ctx&` and may `raise` |
| Routers | `honk::include(c, "/users", "users", user_routes)`: a prefix and a docs tag |
| Docs | `/docs` (Swagger UI), `/redoc` and `/openapi.json`, generated at startup |
| Testing | `honk::request("GET", "/items/1", app)`, in-process with no sockets |
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
  net.goose          extern fn bindings to the socket layer
  src/honk_net.c     BSD sockets (Winsock on Windows)
examples/
  hello.goose        two routes
  items.goose        CRUD: models, validation, errors, a router, a dependency, HTML
tests/
  test_honk.goose    33 checks through honk::request
docs/
  quickstart.md      from nothing to /docs in five minutes
  guide.md           every feature, by example
  reference.md       the API, one entry per declaration
```

## Docs

* **[Quickstart](docs/quickstart.md)**: install, first app, try it.
* **[Guide](docs/guide.md)**: routes, params, models, validation, responses,
  errors, dependencies, routers, OpenAPI, testing, deployment.
* **[API reference](docs/reference.md)**: every public declaration.

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

## Status and limits

Honk is version 0.1 and these are its limits:

* **One request at a time.** The server is a single-threaded accept loop
  with `Connection: close`. Goose threads share no memory and cannot take a
  function value, so a worker pool is future work. Run several processes
  behind a reverse proxy to use more cores.
* **HTTP/1.1 only, without TLS.** Terminate TLS in a proxy such as nginx or
  Caddy.
* **What a model field may be** is listed in [the guide](docs/guide.md#models).
  Request models take scalars, strings (`const u8[:]` or `u8[..N]` for N in
  8, 16, 32, 64, 128, 256) and nested models. Response models also take
  arrays.
* **Required fields** are the fields whose default is their type's zero.
  Goose reflection cannot see whether a field declares a default (see
  [the guide](docs/guide.md#required-and-optional-fields)).
* **No async.** Handlers run to completion, which Goose makes fast.

## References

* Goose: [repository](https://github.com/aardappel/goose),
  [tutorial](https://github.com/aardappel/goose/blob/main/docs/tutorial.md),
  [reference](https://github.com/aardappel/goose/blob/main/docs/reference.md),
  [`const for`](https://github.com/aardappel/goose/blob/main/docs/design/const_for.md),
  [packages](https://github.com/aardappel/goose/blob/main/docs/packages.md)
* [OpenAPI 3.1 specification](https://spec.openapis.org/oas/v3.1.0),
  [Swagger UI](https://swagger.io/tools/swagger-ui/),
  [ReDoc](https://github.com/Redocly/redoc)
* [RFC 9110, HTTP semantics](https://www.rfc-editor.org/rfc/rfc9110) and
  [RFC 9112, HTTP/1.1](https://www.rfc-editor.org/rfc/rfc9112)

## License

[MIT](LICENSE).
