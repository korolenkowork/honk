// Threads. Goose workers share no memory: each `thread_fn` runs as its own
// program with its own copy of every global, and values cross between
// workers only through typed queues. This module builds a server on that:
//
//   serve_threads   listens once and starts N workers that each accept()
//                   on the same socket and answer requests with the app
//   ask / serve_store
//                   one store thread owns the app's state; handlers on any
//                   worker send it a command and wait for its reply
//   background / run_jobs
//                   handlers queue work for a worker and answer at once
//
// A thread_fn cannot be generic, so the app declares its own one-line
// worker, naming its app, and hands it to serve_threads:
//
//     let CONFIG = honk::Config { port: 8000, .. };
//     thread_fn worker(fd: i64, id: i64) { honk::serve_on(fd, id, CONFIG, app); }
//     fn main() { honk::serve_threads(CONFIG, 0, worker); }
//
// Programs with threads must be built (`goose build`): the in-process
// runner cannot start threads.
namespace honk;

import std;

// This program's worker id: 0 on the main thread, 1 and up on the workers
// serve_threads starts. Each worker has its own copy of the global.
var worker_id: i64 = 0;

// The last call number this program used for ask.
var ask_seq: i64 = 0;

// How long ask waits for the store before answering 503.
var ask_timeout_ms: i64 = 10000;

// A command on its way to the store, with where the reply goes.
struct Call<Req> { from: i64, seq: i64, req: Req }

// Listens on cfg.host:cfg.port and starts `workers` workers on the socket,
// hardware_threads() of them when it is 0. W is the app's
// `thread_fn worker(fd: i64, id: i64)`, which calls serve_on. Waits for the
// workers, which run until the process ends; an abort in any of them ends
// the process, so run it under a supervisor that restarts it.
fn serve_threads<W>(cfg: Config, workers: i64) {
    let n = min(if workers > 0 { workers } else { max(1, hardware_threads()) }, mail_slots() - 1);
    let fd = listen_or_abort(cfg);
    print("INFO:     Honk ", VERSION, " running on ", scheme(cfg), "://", cfg.host, ":", cfg.port, " with ", n,
          " workers", if cfg.docs { " (docs at /docs)" } else { "" });
    var ids: i64[>..] = [];
    for i in n { ids.push(thread_spawn(W, fd, i + 1)); }
    for id in ids { thread_wait(id); }
}

// A worker's whole life: answers requests on the listening socket fd with
// App, as worker `id`, forever. Call it from the app's thread_fn.
fn serve_on<App>(fd: i64, id: i64, cfg: Config) {
    worker_id = id;
    accept_loop(cfg, fd, false, App);
}

// Sends req to the store thread and returns its reply, a Resp. Each call
// waits for its own reply, whichever worker it runs on. Answers 503 if the
// store does not reply within ask_timeout_ms.
//
// Name Req, the command enum, explicitly: inferred from `Cmd.Get { ... }`
// it would be the variant type Cmd.Get, a queue the store never reads. A
// one-line typed wrapper keeps the calls short:
//
//     fn db(cmd: Cmd) -> Reply { honk::ask<Cmd, Reply>(cmd) }
//     let r = db(Cmd.Get { id: p.item_id });
fn ask<Req, Resp>(req: Req) -> Resp {
    ask_seq++;
    let seq = ask_seq;
    qput(Call<Req> { from: worker_id, seq: seq, req: req });
    var reply: u8[>..] = [];
    if !mail_take(worker_id, seq, reply, ask_timeout_ms) { raise(503, "The store did not answer"); }
    var got, ok = from_bytes<Resp[>..]>(reply);
    if !ok || got.len != 1 { raise(500, "The store sent a reply of the wrong type"); }
    return got[0];
}

// The store's loop: takes each Req any worker sent with ask, answers it with
// F(req), and replies to that worker. Call it from the app's store
// thread_fn, which owns the state as its locals:
//
//     thread_fn store() {
//         var items: Item[>..<] = [];
//         honk::serve_store<Cmd>() { cmd => match cmd { ... } };
//     }
fn serve_store<Req, F>() {
    loop {
        let call = qget<Call<Req>>();
        var answer = F(call.req);
        mail_put(call.from, call.seq, pack_one(answer));
    }
}

// v as a one-element image, the form ask reads replies in.
fn pack_one<T>(v: T&) -> u8[>..] {
    var one: T[>..] = [];
    one.push(v);
    return one.to_bytes();
}

// Queues job for a background worker, which takes it with run_jobs, and
// returns at once. Job must be flat: no references or slices, so text goes
// in a u8[..N] field. Returns false if the queue is full (see qlimit).
fn background<Job>(job: Job) -> bool { qput(job) }

// A background worker's loop: runs F(job) for each Job queued with
// background, one at a time, forever.
//
//     thread_fn mailer() { honk::run_jobs<Email>() { job => send(job) }; }
fn run_jobs<Job, F>() {
    loop { F(qget<Job>()); }
}
