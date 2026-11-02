# Proposal: generic `thread_fn`, and replies to one worker

*A proposal to the Goose language, from the Honk web framework. Draft, not
yet filed.*

## Summary

Two additions to the concurrency surface, in the spirit of open item 9 of
the spec's Appendix B ("queue fairness/capacity, select, worker-local
init"):

1. **Generic `thread_fn`**, instantiated per spawn site like any generic
   function, so a library can start workers that run code its caller names.
2. **Addressed replies**: a way for one worker to send a value that only a
   chosen worker receives, so request and reply between threads needs no
   code outside Goose.

## Motivation

Honk runs a web server on N workers. Each worker accepts connections on a
shared socket and answers them with the app's routes.

**1. The app has to write the worker.** A `thread_fn` cannot be generic,
so Honk cannot provide "a worker that serves app". Every app writes one:

```goose
let CONFIG = honk::Config { port: 8000, .. };
thread_fn worker(fd: i64, id: i64) { honk::serve_on(fd, id, CONFIG, app); }
fn main() { honk::serve_threads(CONFIG, 0, worker); }
```

instead of

```goose
fn main() { honk::serve_threads(honk::Config { port: 8000, .. }, app); }
```

Besides the boilerplate, `Config` must become a `let` global, because the
worker can only read flat or static globals and `Config` holds slices.

**2. Replies need C.** Shared state lives in one store thread. Handlers on
any worker send it a command and wait for the answer. Queues are one per
type for the whole process, so a reply put on `Reply`'s queue goes to
whichever worker takes it first, not the one that asked. Honk solves this
with about 100 lines of C (`honk/src/honk_mail.c`): a mailbox per worker
id, guarded by a mutex and a condition variable, holding the reply as a
`to_bytes` image with a sequence number. It works, but it steps outside
the language's guarantees for something the language is close to
offering.

## Proposed design

### 1. Generic `thread_fn`

```goose
thread_fn serve_worker<App>(fd: i64, id: i64) { accept_loop(fd, id, App); }

fn serve_threads<App>(n: i64) {
    for i in n { thread_spawn(serve_worker<App>, fd, i + 1); }
}
```

* A generic `thread_fn` is instantiated at each `thread_spawn` that names
  it with concrete arguments, and each instantiation is a separate worker
  program, exactly as a non-generic `thread_fn` is now. Spawn sites are
  static (§11.2 already lets `thread_spawn(W, ...)` take a function
  parameter bound to a `thread_fn`), so the set of worker programs remains
  known at compile time.
* Type and function-value parameters are compile-time entities and never
  cross the thread boundary, so the "flat arguments" rule (§11.2) applies
  to value parameters only, unchanged.
* `thread_spawn(serve_worker<App>, ...)` needs the existing explicit form
  `f<...>` to be accepted as a function value in argument position. Today
  `spawn_all<worker<handle>>(3)` reports `unknown type: worker`.

### 2. Addressed replies

The smallest addition that removes the C:

```goose
fn thread_id() -> i64                    // this worker's id; 0 on main
fn qput_to(id: i64, v) -> bool           // a queue of v's type that only worker `id` reads
fn qget_mine<T>() -> T                   // takes the next T addressed to this worker
fn qget_mine<T>(ms: i64) -> T, bool      // with a timeout
```

* Each worker gets one private queue per type, created lazily, and the
  existing shared queues are unchanged.
* Values must be flat, as for every queue.
* With these, Honk's `ask` becomes plain Goose:

```goose
fn ask<Req, Resp>(req: Req) -> Resp {
    qput(Call<Req> { from: thread_id(), req: req });
    let reply, ok = qget_mine<Resp>(ask_timeout_ms);
    ...
}
```

A per-worker queue also gives a natural shape to worker-local init and to
`select`, both already named in item 9.

## Compatibility and cost

* Generic `thread_fn` relaxes an error into a feature: every program that
  compiles today means the same.
* Addressed queues are new builtins. Their cost is a per-worker table of
  queues, paid only by programs that call them.

## Open questions

* Should `thread_id()` be the spawn id `thread_spawn` returns? That is
  simplest for a supervisor, which already holds those ids.
* Ordering between `qput_to` and shared `qput` from the same sender: this
  proposal guarantees order per queue only, as today.
