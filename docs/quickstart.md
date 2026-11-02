# Quickstart

This page takes you from an empty directory to a running API with
interactive docs. It assumes you have the Goose compiler; you do not need
to know Goose well.

## 1. Install

1. Get Goose from its [releases page](https://github.com/aardappel/goose/releases),
   unpack it, and put the directory on `PATH`. Check it with `goose version`.
2. Make sure a C compiler is installed: clang or gcc on macOS and Linux,
   MSVC or clang on Windows. `goose toolchain` shows which one Goose found.
   Honk's socket layer is C, and Goose compiles it the first time you run a
   program that imports Honk.
3. Put Honk next to your project, or anywhere you can point a path at.

```
myapi/
  honk/          <- this repository's honk/ directory
  main.goose
```

## 2. Write an app

`main.goose`:

```goose
import honk from "./honk";

struct Hello { message: const u8[:] }

struct Greet { name: const u8[:], excited: bool = false }   // ?name=...&excited=true
struct Greeting { text: u8[..64] }

fn app(c: honk::Ctx&) {
    honk::get<Hello>(c, "/") {
        Hello { message: "Honk!" }
    };
    honk::get<Greeting, Greet>(c, "/greet") { p =>
        var g = Greeting { text: [] };
        format(g.text, "Hello, ", if p.name.len > 0 { p.name } else { "goose" });
        if p.excited { g.text.push('!'); }
        g
    };
}

fn main() {
    honk::serve(honk::Config { port: 8000, title: "My first Honk API", .. }, app);
}
```

The app above uses these pieces:

* **`app`** is called with a `honk::Ctx&` for every request, and once at
  startup to describe the API. All it does is declare routes.
* **`honk::get<Hello>`** declares a `GET` route that answers with a `Hello`.
  The block's value is the response, and Honk turns it into JSON.
* **`honk::get<Greeting, Greet>`** also takes a params struct. Its fields
  are filled from the query string (`name`, `excited`) and validated
  before the block runs, and the block receives the struct as `p`.

## 3. Run it

```bash
goose main.goose
```

```
INFO:     Honk 0.1.0 running on http://127.0.0.1:8000 (docs at /docs)
```

In another terminal:

```bash
curl http://127.0.0.1:8000/
```

```json
{"message":"Honk!"}
```

```bash
curl "http://127.0.0.1:8000/greet?name=Ada&excited=true"
```

```json
{"text":"Hello, Ada!"}
```

```bash
curl "http://127.0.0.1:8000/greet?excited=maybe"
```

```json
{"detail":[{"type":"bool_parsing","loc":["query","excited"],"msg":"Input should be a valid boolean, unable to interpret input","input":"maybe"}]}
```

The 422 response above comes from validation. You wrote no code for it.

## 4. Open the docs

Visit **http://127.0.0.1:8000/docs** for Swagger UI. You can send any request
from that page with **Try it out**. **/redoc** shows the same API in ReDoc,
and **/openapi.json** is the schema itself.

## 5. Accept a JSON body

A field whose type is a struct is the request body:

```goose
struct Todo { title: u8[..64], done: bool }
struct AddTodo { todo: Todo }

var todos: Todo[>..<] = [];

fn app(c: honk::Ctx&) {
    honk::post<Todo, AddTodo>(c, "/todos", "Add a todo", 201) { p =>
        todos.push(p.todo);
        p.todo
    };
}
```

```bash
curl -X POST http://127.0.0.1:8000/todos -d '{"title": "Feed the geese"}'
```

```json
{"title":"Feed the geese","done":false}
```

A missing `title` gets a 422 naming `["body","title"]`, and so does a
`title` longer than 64 bytes.

## 6. Build a binary

```bash
goose build main.goose && ./main
```

The binary contains the whole server and needs nothing else at run time.

## Next

* The [guide](guide.md) covers path parameters, errors, dependencies,
  routers, response types and testing.
* [`examples/items.goose`](../examples/items.goose) is a complete CRUD API.
* The [reference](reference.md) lists every declaration.
