# Benchmarks

The same small JSON API, written in Honk and in seven other languages, each
loaded with [wrk](https://github.com/wg/wrk) by one runner,
[`run.py`](run.py). The [Benchmarks workflow](../.github/workflows/bench.yml)
runs all eight on every push to `main` that touches Honk or the benchmarks,
and on demand, and posts the tables in the run's summary.

## The API

Every server answers exactly this, on `127.0.0.1:8000`, with HTTP/1.1
keep-alive. Before it is measured, the runner sends each server these
requests and skips any server whose answers differ:

| Request | Answer |
|---|---|
| `GET /hello` | `200 {"message":"Honk!"}` |
| `GET /items/5?q=geese` | `200 {"item_id":5,"q":"geese"}` |
| `GET /items/x` | `422`: the path parameter must be an integer |
| `POST /items` `{"name":"Egg","price":2.5}` | `201 {"name":"Egg","price":2.5,"price_with_tax":3.0}` |
| `POST /items` `{"name":"Egg"}` | `422`: `name` (a string) and `price` (a number) are required |

## The servers

Each uses its language's standard library, so the comparison involves no
third-party framework. C and C++ have no HTTP or JSON in their standard
libraries, so those two are minimal hand-written servers on raw sockets,
which makes them a baseline rather than something you would deploy. Every
server uses all cores.

| Server | Source | How it uses the cores | JSON |
|---|---|---|---|
| Honk (Goose) | [honk/server.goose](servers/honk/server.goose) | `serve_threads`: one worker per core | Honk's models, with validation |
| C | [c/server.c](servers/c/server.c) | a thread per connection | hand-written scan |
| C++ | [cpp/server.cpp](servers/cpp/server.cpp) | a `std::thread` per connection | hand-written scan |
| C# | [csharp/Program.cs](servers/csharp/Program.cs) | ASP.NET Core Kestrel (ships with the .NET SDK) | System.Text.Json |
| Java | [java/Server.java](servers/java/Server.java) | JDK `HttpServer`, a virtual thread per request | hand-written regex (the JDK has no JSON) |
| Go | [go/main.go](servers/go/main.go) | `net/http`, a goroutine per connection | encoding/json |
| Python | [python/server.py](servers/python/server.py) | `http.server`, threads, one forked process per core | json |
| JavaScript | [node/server.js](servers/node/server.js) | `node:http`, one process per core with `node:cluster` | JSON |

## Method

* Three workloads: `GET /hello`, `GET /items/42?q=geese` (path and query
  parsing) and `POST /items` (a JSON body, validated and answered).
* Two concurrency levels: as many connections as cores, and 256.
* For each workload and level, a 2-second warm-up, then 10 seconds measured,
  with wrk running half as many threads as there are cores (at most 8).
* Peak memory is the highest total resident memory of the server's whole
  process group, sampled every 250 ms across all its runs, so Node's and
  Python's worker processes count.
* wrk runs on the same machine as the server, and the two compete for the
  cores. The numbers compare servers with each other on one machine; they
  are not absolute capacity.

## Results

Apple M5 (10 cores), macOS 26, Clang 21, Node 26, Python 3.14. Go, Java and
.NET were not installed on this machine; the Benchmarks workflow measures
all eight on Linux.

Requests per second (p99 latency in ms):

| Server | `/hello`, 10 conn. | `/hello`, 256 conn. | `/items/42`, 10 conn. | `/items/42`, 256 conn. | `POST /items`, 10 conn. | `POST /items`, 256 conn. |
|---|---:|---:|---:|---:|---:|---:|
| Honk (Goose) | **146,409** (0.10) | 148,232 (84.7)\* | 139,509 (0.10) | 134,547 (93.9)\* | 133,777 (0.10) | 133,506 (93.3)\* |
| C++ | 140,336 (0.10) | **150,429** (2.4) | **140,962** (0.11) | **154,298** (2.0) | **142,231** (0.10) | **152,025** (2.4) |
| C | 115,961 (0.12) | 120,760 (2.6) | 115,749 (0.12) | 120,171 (2.6) | 116,334 (0.12) | 121,833 (2.6) |
| JavaScript (Node) | 113,931 (0.21) | 146,496 (8.8) | 115,254 (0.14) | 146,094 (11.8) | 109,199 (0.18) | 143,783 (37.4) |
| Python | 68,342 (0.23) | 85,090 (45.6) | 68,285 (0.22) | 81,788 (56.1) | 63,460 (0.26) | 75,875 (75.2) |

| Server | Peak memory |
|---|---:|
| Honk (Goose) | **3.4 MiB** |
| C | 9.3 MiB |
| C++ | 9.4 MiB |
| Python | 234.8 MiB |
| JavaScript (Node) | 686.5 MiB |

\* About 115 connections per run were reset; see below.

### What the numbers say

* **With as many connections as cores, Honk matches hand-written C++.**
  It runs within 6% of C++ on every workload, ahead of it on `/hello`, 15
  to 29% ahead of the hand-written C and of Node, and about twice as fast as
  Python. On `POST /items`
  that includes parsing the body into a struct, validating it, and writing
  JSON back by reflection.
* **Honk uses the least memory by far**, 3.4 MiB for ten workers: no
  allocator, no garbage collector, and a request's buffers freed with one
  store when it ends.
* **With 256 connections, Honk's fixed worker pool shows.** Throughput
  holds, and the median stays at 0.07 ms, but p99 rises to 85 to 94 ms.
  Honk has one worker per core, and each serves one connection at a time,
  so the other connections wait in the accept queue until a worker finishes
  one (after 100 requests, or when it idles). Thread-per-connection (C, C++)
  and event-loop (Node) servers do not queue this way.
* **The resets are macOS's.** macOS caps every listen backlog at 128
  (`sysctl kern.ipc.somaxconn`) whatever a program asks for, and with 256
  connections and 10 busy workers Honk's queue overflows, so the kernel
  resets the extra connections. Linux allows 4096 by default, and the
  hand-written servers never fill their queue because they accept at once.
  To reproduce without resets on a Mac, raise the cap for the session:
  `sudo sysctl kern.ipc.somaxconn=1024`.

## Running them

Needs wrk, and each language's toolchain. The runner skips, and reports,
any server whose toolchain is missing.

```bash
brew install wrk            # or: sudo apt-get install wrk
```

```bash
python3 bench/run.py
```

```bash
python3 bench/run.py --only honk,c,go --duration 5 --connections 16,64
```

The tables go to `bench/results/results.md` and the raw numbers to
`results.json`, both ignored by git.
