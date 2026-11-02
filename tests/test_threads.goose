// Honk's thread tests: the store, background jobs and the ask timeout,
// through honk::request on the main thread (worker 0). Threads need a
// real build:
//
//     goose build tests/test_threads.goose && tests/test_threads
import honk from "../honk";
import std;
import os;

struct Count { n: i64 }
struct Add { by: i64 }
struct AddBody { add: Add }

enum Cmd { Get, Add { by: i64 }, Fail }
struct Reply { n: i64 }

thread_fn store() {
    var n = 0;
    honk::serve_store<Cmd>() { cmd =>
        match cmd {
            Get => {},
            Add a => { n += a.by; },
            Fail => { sleep_ms(400); },          // longer than the test's ask timeout
        }
        Reply { n: n }
    };
}

fn db(cmd: Cmd) -> Reply { honk::ask<Cmd, Reply>(cmd) }

struct Job { id: i64 }
struct Done { id: i64 }

thread_fn jobs() { honk::run_jobs<Job>() { job => qput(Done { id: job.id * 10 }); }; }

fn app(c: honk::Ctx&) {
    honk::get<Count>(c, "/count") { Count { n: db(Cmd.Get).n } };
    honk::post<Count, AddBody>(c, "/count") { p => Count { n: db(Cmd.Add { by: p.add.by }).n } };
    honk::get<Count>(c, "/slow") { Count { n: db(Cmd.Fail).n } };
    honk::post<Count>(c, "/jobs") {
        honk::background(Job { id: 7 });
        Count { n: 1 }
    };
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

fn main() {
    print("honk thread tests");
    thread_spawn(store);
    thread_spawn(jobs);
    {
        let s, b = honk::request("GET", "/count", app);
        expect("ask, no payload", s, b, 200, "{\"n\":0}");
    }
    {
        for i in 3 { honk::request("POST", "/count", "{\"by\":5}", app); }
        let s, b = honk::request("GET", "/count", app);
        expect("ask with payloads, state kept by the store", s, b, 200, "{\"n\":15}");
    }
    {
        honk::ask_timeout_ms = 100;
        let s, b = honk::request("GET", "/slow", app);
        expect("ask timeout is 503", s, b, 503, "{\"detail\":\"The store did not answer\"}");
        sleep_ms(500);                           // the late reply arrives now
        honk::ask_timeout_ms = 10000;
        let s2, b2 = honk::request("GET", "/count", app);
        expect("a late reply is not taken as the next one", s2, b2, 200, "{\"n\":15}");
    }
    {
        let s, b = honk::request("POST", "/jobs", app);
        let done, got = qget<Done>(2000);
        if s == 200 && got && done.id == 70 { print("  ok    background job ran"); }
        else { failures++; print("  FAIL  background job: status ", s, " got ", got, " id ", done.id); }
    }
    if failures > 0 { print(failures, " failed"); exit(1); }
    print("all passed");
}
