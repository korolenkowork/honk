// A multi-threaded API: several workers answer requests at once, one store
// thread owns the data, and a background worker writes an audit log.
//
// Goose threads share no memory, so the workers cannot all read and write
// one global array. The store thread holds it instead, and the handlers ask
// it for what they need with honk::ask. Threads need a real build:
//
//     goose build examples/threaded.goose && examples/threaded
//     curl http://127.0.0.1:8000/items
import honk from "../honk";
import std;
import os;

// ---------------------------------------------------------------- models

struct ItemIn { name: u8[..32], price: f64 }
struct Item { id: i64, name: u8[..32], price: f64 }
struct ItemList { total: i64, items: Item[..50] }   // a limited array: flat, so it crosses threads
struct ItemId { item_id: i64 }
struct CreateItem { item: ItemIn }
struct Slow { ms: i64 = 200 }
struct Slept { worker: i64, ms: i64 }

// ---------------------------------------------------------------- the store

// What a handler can ask the store, and what it answers. Both cross
// between threads, so both are flat.
enum Cmd { List, Get { id: i64 }, Create { item: ItemIn }, Delete { id: i64 } }
struct Reply { found: bool, item: Item, list: ItemList }

thread_fn store() {
    var items: Item[>..<] = [];
    var next_id = 1;
    honk::serve_store<Cmd>() { cmd =>
        var r = Reply { found: false, item: Item { id: 0, name: [], price: 0.0 },
                        list: ItemList { total: 0, items: [] } };
        match cmd {
            List => {
                r.list.total = items.len;
                for x in items { if r.list.items.len < 50 { r.list.items.push(x); } }
            },
            Get g => {
                for x in items { if x.id == g.id { r.found = true; r.item = x; } }
            },
            Create n => {
                r.item = Item { id: next_id, name: n.item.name, price: n.item.price };
                next_id++;
                items.push(r.item);
                r.found = true;
            },
            Delete d => {
                let at = position_of(items, d.id);
                if at >= 0 {
                    r.found = true;
                    r.item = items[at];
                    remove_at(items, at);
                }
            },
        }
        r
    };
}

// The handlers' way to the store. Taking a Cmd makes every variant a Cmd,
// the type serve_store reads.
fn db(cmd: Cmd) -> Reply { honk::ask<Cmd, Reply>(cmd) }

fn position_of(items: Item[:], id: i64) -> i64 {
    for x, i in items { if x.id == id { return i; } }
    return -1;
}

// ---------------------------------------------------------------- background jobs

struct Audit { action: u8[..16], id: i64 }

thread_fn auditor() {
    honk::run_jobs<Audit>() { job =>
        print("AUDIT:    ", job.action, " item ", job.id);
    };
}

// ---------------------------------------------------------------- routes

fn app(c: honk::Ctx&) {
    honk::get<ItemList>(c, "/items", "List items") {
        db(Cmd.List).list
    };
    honk::get<Item, ItemId>(c, "/items/{item_id}", "Read an item") { p =>
        let r = db(Cmd.Get { id: p.item_id });
        if !r.found { honk::raise(404, "Item not found"); }
        r.item
    };
    honk::post<Item, CreateItem>(c, "/items", "Create an item", 201) { p =>
        let r = db(Cmd.Create { item: p.item });
        honk::background(Audit { action: "created", id: r.item.id });
        r.item
    };
    honk::delete<Item, ItemId>(c, "/items/{item_id}", "Delete an item") { p =>
        let r = db(Cmd.Delete { id: p.item_id });
        if !r.found { honk::raise(404, "Item not found"); }
        honk::background(Audit { action: "deleted", id: r.item.id });
        r.item
    };
    // Sleeps, to show that other workers keep answering meanwhile.
    honk::get<Slept, Slow>(c, "/slow", "Wait, then answer") { p =>
        sleep_ms(p.ms);
        Slept { worker: honk::worker_id, ms: p.ms }
    };
}

// ---------------------------------------------------------------- startup

let CONFIG = honk::Config { title: "Threaded items API", .. };

thread_fn worker(fd: i64, id: i64) { honk::serve_on(fd, id, CONFIG, app); }

fn main() {
    thread_spawn(store);
    thread_spawn(auditor);
    honk::serve_threads(CONFIG, 4, worker);
}
